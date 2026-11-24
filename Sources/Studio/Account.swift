import AppKit
import CryptoKit
import Network
import SwiftUI

// The Studio account: signing in through the browser (WorkOS AuthKit, behind studio-server), the tokens, and
// Settings → Account.
//
// Sign-in, as studio-server's internal/auth describes it from the other side:
//   1. Studio listens on a loopback port and opens the browser at <server>/auth/login with that port, a random
//      state and a PKCE challenge.
//   2. The user signs in on WorkOS's page; the server sends the browser to http://127.0.0.1:<port>/callback
//      with a one-time code.
//   3. Studio posts the code and the PKCE verifier to <server>/auth/token and gets an access token (a JWT that
//      lasts minutes), a refresh token and the user.
// The tokens are kept like secrets are: the login keychain in a release build, a 0600 file in a build from source.

struct AccountUser: Codable, Equatable {
    var id: String
    var email: String
    var firstName: String
    var lastName: String
    var profilePictureURL: String

    enum CodingKeys: String, CodingKey {
        case id, email
        case firstName = "first_name", lastName = "last_name", profilePictureURL = "profile_picture_url"
    }

    /// "Ada Lovelace", or nothing when the account has no name.
    var name: String { [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// What the server returns from /auth/token and /auth/refresh, and what Studio stores.
private struct AccountSession: Codable {
    var accessToken: String
    var refreshToken: String
    var user: AccountUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", user
    }

    /// When the access token runs out (its `exp` claim). Only for deciding when to refresh: the server is what
    /// checks the token.
    var accessExpires: Date {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3 else { return .distantPast }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return .distantPast }
        return Date(timeIntervalSince1970: exp)
    }
}

struct AccountError: LocalizedError {
    let message: String
    /// The server said the session is over (as opposed to being unreachable).
    var sessionEnded = false
    var errorDescription: String? { message }
}

@MainActor
final class Account: ObservableObject {
    static let shared = Account()

    /// The signed-in user, or nil.
    @Published private(set) var user: AccountUser?
    /// The browser is open and Studio is waiting for it.
    @Published private(set) var signingIn = false
    /// Why the last sign-in (or the session) failed, for Settings → Account.
    @Published var error: String?

    /// studio-server. `defaults write dev.local.studio account.serverURL <url>` or STUDIO_SERVER_URL points
    /// Studio at another one.
    nonisolated static var serverURL: URL {
        let override = Pref.string("account.serverURL") ?? ProcessInfo.processInfo.environment["STUDIO_SERVER_URL"]
        return override.flatMap { URL(string: $0) } ?? URL(string: "http://localhost:8787")!
    }

    private let backend: SecretBackend
    private static let item = "session"
    private var session: AccountSession? { didSet { user = session?.user } }
    private var attempt: Task<Void, Never>?
    private var signInURL: URL?
    private var refreshing: Task<AccountSession, Error>?

    private init() {
        let key = StudioControl.bundleKey
        backend = SecretStore.signedByTeam
            ? KeychainBackend(service: key + ".account", label: "Studio account")
            : FileBackend(path: StudioControl.supportDirPath + "/account-\(key).json")
        if let raw = backend.read(Self.item), let s = try? JSONDecoder().decode(AccountSession.self, from: Data(raw.utf8)) {
            session = s
            user = s.user
        }
    }

    // MARK: Signing in and out

    /// Opens the browser to sign in. While a sign-in is already waiting, opens its page again.
    func signIn() {
        if signingIn {
            if let signInURL { NSWorkspace.shared.open(signInURL) }
            return
        }
        error = nil
        signingIn = true
        attempt = Task {
            defer { signingIn = false; signInURL = nil; attempt = nil }
            do {
                let verifier = Self.randomToken(32), state = Self.randomToken(16)
                let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
                let callback = try LoopbackCallback(state: state)
                defer { callback.stop() }
                let port = try await callback.start()

                var login = URLComponents(url: Self.serverURL.appendingPathComponent("auth/login"), resolvingAgainstBaseURL: false)!
                login.queryItems = [
                    URLQueryItem(name: "port", value: String(port)),
                    URLQueryItem(name: "state", value: state),
                    URLQueryItem(name: "code_challenge", value: challenge),
                ]
                signInURL = login.url
                NSWorkspace.shared.open(login.url!)

                let timeout = Task { try await Task.sleep(for: .seconds(600)); callback.stop() }
                defer { timeout.cancel() }
                guard let reply = await callback.reply() else {
                    if !Task.isCancelled { error = "Sign-in timed out. Try again." }
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                if let failure = reply["error"] {
                    // the user closing WorkOS's page or going back is not worth a message
                    if failure != "access_denied" { error = reply["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? "Sign-in didn't finish." }
                    return
                }
                guard let code = reply["code"] else { error = "Sign-in didn't finish."; return }
                store(try await Self.post("auth/token", ["code": code, "code_verifier": verifier]))
            } catch is CancellationError {
            } catch {
                self.error = Self.describe(error)
            }
        }
    }

    func cancelSignIn() { attempt?.cancel() }

    /// Forgets the account on this Mac and ends its session on the server (best effort: without a connection
    /// the session runs out by itself).
    func signOut() {
        attempt?.cancel()
        refreshing?.cancel()
        refreshing = nil
        let old = session
        session = nil
        error = nil
        backend.remove(Self.item)
        guard let old else { return }
        Task.detached {
            var token = old.accessToken
            if old.accessExpires < Date().addingTimeInterval(30) {
                guard let fresh: AccountSession = try? await Self.post("auth/refresh", ["refresh_token": old.refreshToken]) else { return }
                token = fresh.accessToken
            }
            let _: Empty? = try? await Self.post("auth/logout", [:], bearer: token)
        }
    }

    // MARK: Using the account

    /// An access token for a request to studio-server, refreshed when it's about to run out. Throws when no one
    /// is signed in or the session has ended.
    func accessToken() async throws -> String {
        guard let session else { throw AccountError(message: "Not signed in.", sessionEnded: true) }
        if session.accessExpires > Date().addingTimeInterval(60) { return session.accessToken }
        // One refresh at a time: a refresh token works once, so two at once would end the session.
        if let refreshing { return try await refreshing.value.accessToken }
        let refreshToken = session.refreshToken
        let task = Task { () throws -> AccountSession in
            try await Self.post("auth/refresh", ["refresh_token": refreshToken])
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            // signed out (or in as someone else) while this was in flight
            guard self.session?.refreshToken == refreshToken else { throw CancellationError() }
            store(fresh)
            return fresh.accessToken
        } catch let e as AccountError where e.sessionEnded {
            if self.session?.refreshToken == refreshToken {
                self.session = nil
                backend.remove(Self.item)
                error = "Your session has ended. Sign in again."
            }
            throw e
        }
    }

    /// Checks the session with the server and picks up a changed name, email or picture. Quiet when offline.
    func refreshProfile() async {
        guard session != nil, let token = try? await accessToken() else { return }
        guard let fresh: AccountUser = try? await Self.get("v1/me", bearer: token), var s = session, s.user != fresh else { return }
        s.user = fresh
        store(s)
    }

    private func store(_ s: AccountSession) {
        session = s
        if let data = try? JSONEncoder().encode(s), let raw = String(data: data, encoding: .utf8) {
            do { try backend.write(Self.item, raw) } catch { self.error = "Signed in, but couldn't save the session: \(error.localizedDescription)" }
        }
    }

    // MARK: The server

    private struct Empty: Decodable {}
    private struct ServerError: Decodable { let error: String; let message: String }

    private nonisolated static func post<T: Decodable>(_ path: String, _ body: [String: String], bearer: String? = nil) async throws -> T {
        var req = URLRequest(url: serverURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req, bearer: bearer)
    }

    private nonisolated static func get<T: Decodable>(_ path: String, bearer: String) async throws -> T {
        try await send(URLRequest(url: serverURL.appendingPathComponent(path)), bearer: bearer)
    }

    private nonisolated static func send<T: Decodable>(_ request: URLRequest, bearer: String?) async throws -> T {
        var req = request
        req.timeoutInterval = 20
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let e = try? JSONDecoder().decode(ServerError.self, from: data)
            throw AccountError(message: e?.message ?? "The Studio server answered with an error (\(status)).", sessionEnded: status == 401)
        }
        if data.isEmpty, let empty = Empty() as? T { return empty }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return "Couldn't reach the Studio server (\(serverURL.host ?? serverURL.absoluteString)). Check your connection and try again."
            default: break
            }
        }
        return error.localizedDescription
    }

    private static func randomToken(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The loopback end of a sign-in: a one-request HTTP server on 127.0.0.1 that the browser is redirected to
/// (GET /callback?code=…&state=…). It answers with a page that says to go back to Studio.
private final class LoopbackCallback: @unchecked Sendable {
    private let listener: NWListener
    private let state: String
    private let queue = DispatchQueue(label: "studio.account.callback")
    private let replies: AsyncStream<[String: String]>
    private let deliver: AsyncStream<[String: String]>.Continuation
    private var started = false   // only touched on `queue`

    init(state: String) throws {
        self.state = state
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        (replies, deliver) = AsyncStream.makeStream(of: [String: String].self)
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [self] s in
                guard !started else { return }
                switch s {
                case .ready:
                    started = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e):
                    started = true
                    cont.resume(throwing: e)
                case .cancelled:
                    started = true
                    cont.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
            listener.start(queue: queue)
        }
    }

    /// The callback's query (`code`, or `error` and `error_description`); nil once stopped or when the task is
    /// cancelled.
    func reply() async -> [String: String]? {
        for await r in replies { return r }
        return nil
    }

    func stop() {
        listener.cancel()
        deliver.finish()
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return c.cancel() }
            // "GET /callback?code=…&state=… HTTP/1.1"
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first.map(String.init) ?? ""
            let words = line.split(separator: " ")
            guard words.count >= 2, words[0] == "GET", let url = URLComponents(string: "http://127.0.0.1" + words[1]),
                  url.path == "/callback" else {
                return self.respond(c, status: "404 Not Found", title: "Not found", detail: "")
            }
            var query: [String: String] = [:]
            for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
            // Only the sign-in this app started: anything else on this port is ignored.
            guard query["state"] == self.state else {
                return self.respond(c, status: "400 Bad Request", title: "This sign-in link isn't valid",
                                    detail: "Start again from Studio: Settings → Account → Sign In.")
            }
            if query["error"] != nil {
                self.respond(c, status: "200 OK", title: "Sign-in didn't finish", detail: "Go back to Studio to try again. You can close this tab.")
            } else {
                self.respond(c, status: "200 OK", title: "Go back to Studio", detail: "Sign-in finishes there. You can close this tab.")
            }
            self.deliver.yield(query)
        }
    }

    private func respond(_ c: NWConnection, status: String, title: String, detail: String) {
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Studio</title><style>
        body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0; min-height: 100vh; display: grid; place-items: center; background: #111; color: #eee; }
        main { max-width: 26rem; padding: 2rem; text-align: center; } h1 { font-size: 1.25rem; margin: 0 0 .5rem; } p { margin: 0; color: #999; }
        @media (prefers-color-scheme: light) { body { background: #fafafa; color: #111; } p { color: #666; } }
        </style></head><body><main><h1>\(title)</h1><p>\(detail)</p></main></body></html>
        """
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - Settings → Account

struct AccountSettings: View {
    @ObservedObject private var account = Account.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let user = account.user {
                HStack(alignment: .center, spacing: 12) {
                    Avatar(user: user)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.name.isEmpty ? user.email : user.name).font(.system(size: 13, weight: .semibold))
                        if !user.name.isEmpty {
                            Text(user.email).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    Spacer()
                    Button("Sign Out") { account.signOut() }
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Hairline() }
            } else if account.signingIn {
                Row(title: "Waiting for your browser",
                    detail: "Finish signing in on the page that opened. Studio picks it up from there.") {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Button("Open Page Again") { account.signIn() }
                        Button("Cancel") { account.cancelSignIn() }
                    }
                }
            } else {
                Row(title: "Studio account", detail: "Not signed in. Signing in opens your browser.") {
                    Button("Sign In…") { account.signIn() }
                }
            }
            if let error = account.error {
                Text(error).font(.system(size: 12)).foregroundStyle(TUIColor.error)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 10)
            }
        }
        .task { await account.refreshProfile() }
    }
}

/// The user's picture, or their initial on the accent color until it loads (or when there is none).
private struct Avatar: View {
    let user: AccountUser
    var body: some View {
        AsyncImage(url: URL(string: user.profilePictureURL)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    SwiftUI.Color(nsColor: Theme.accent)
                    Text(String((user.name.isEmpty ? user.email : user.name).prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }
}
