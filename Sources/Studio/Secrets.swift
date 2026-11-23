import AppKit
import Security
import SwiftUI

// Secrets: values (API keys, tokens, passwords) that agents can use without ever reading them.
//
// The rule everything here follows: a secret's value never goes anywhere an agent's conversation is recorded.
//   - An agent never passes a value in: it asks for one by name (`secret_request`, the user types it into a
//     Studio dialog) or captures a command's output (`secret_capture`, Studio stores what the command printed).
//   - An agent never gets a value out: `secret_run` puts secrets in a command's environment and Studio scrubs
//     every known secret (and its common encodings) from the output before replying.
//   - Values are not in the control channel, tool arguments, process arguments, logs or Studio's own files
//     other than the store below.
// This stops secrets from landing in transcripts by accident. It is not a sandbox: a command an agent writes
// can still do anything with the secret it was given (send it somewhere, write it to a file).

/// What Studio knows about a secret besides its value.
struct SecretInfo: Codable, Identifiable, Equatable {
    var name: String
    var note: String
    var created: Date
    var expires: Date?
    var lastUsed: Date?
    /// Who added it: "you" (Settings) or the session that asked.
    var source: String
    var id: String { name }
    var expired: Bool { expires.map { $0 <= Date() } ?? false }
}

/// Where the values live. Release builds use the login keychain; a build from source (ad hoc signature, which
/// changes with every build, so the keychain would ask for the password each time) uses a 0600 file.
private protocol SecretBackend {
    func write(_ name: String, _ value: String) throws
    func read(_ name: String) -> String?
    func remove(_ name: String)
}

private struct KeychainBackend: SecretBackend {
    let service: String
    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }
    func write(_ name: String, _ value: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(name)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Studio secret: \(name)"
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SecretError((SecCopyErrorMessageString(status, nil) as String?) ?? "keychain error \(status)")
        }
    }
    func read(_ name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func remove(_ name: String) { SecItemDelete(query(name) as CFDictionary) }
}

private final class FileBackend: SecretBackend {
    let path: String
    init(path: String) { self.path = path }
    private func load() -> [String: String] {
        guard let d = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }
    private func save(_ all: [String: String]) throws {
        let data = try JSONEncoder().encode(all)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    func write(_ name: String, _ value: String) throws { var a = load(); a[name] = value; try save(a) }
    func read(_ name: String) -> String? { load()[name] }
    func remove(_ name: String) { var a = load(); a[name] = nil; try? save(a) }
}

struct SecretError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

@MainActor
final class SecretStore: ObservableObject {
    static let shared = SecretStore()

    /// Every stored secret that hasn't expired, by name. No values.
    @Published private(set) var secrets: [SecretInfo] = []
    private let backend: SecretBackend
    /// True when values are in the login keychain (release builds); false for the 0600 file.
    let usesKeychain: Bool
    private let indexPath: String
    private var timer: Timer?

    /// Shortest value Studio accepts: anything shorter can't be scrubbed from output without mangling it.
    static let minLength = 6

    private init() {
        let key = StudioControl.bundleKey
        indexPath = StudioControl.supportDirPath + "/secrets-\(key).json"
        usesKeychain = Self.signedByTeam
        backend = usesKeychain ? KeychainBackend(service: key + ".secrets")
                               : FileBackend(path: StudioControl.supportDirPath + "/secret-values-\(key).json")
        if let d = FileManager.default.contents(atPath: indexPath) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            secrets = (try? dec.decode([SecretInfo].self, from: d)) ?? []
        }
        purgeExpired()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.purgeExpired() }
        }
    }

    /// Whether this app is signed by a developer team (a stable identity the keychain can trust across updates).
    private static var signedByTeam: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
    }

    /// Names are environment variable names, since that is how commands receive them.
    static func validName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil
    }

    func info(_ name: String) -> SecretInfo? { secrets.first { $0.name == name && !$0.expired } }

    func set(_ name: String, value: String, note: String, expires: Date?, source: String) throws {
        guard Self.validName(name) else {
            throw SecretError("A secret's name must look like an environment variable (letters, digits, _; e.g. GITHUB_TOKEN).")
        }
        guard value.count >= Self.minLength else {
            throw SecretError("That value is too short to protect (under \(Self.minLength) characters).")
        }
        try backend.write(name, value)
        let old = secrets.first { $0.name == name }
        secrets.removeAll { $0.name == name }
        secrets.append(SecretInfo(name: name, note: note.isEmpty ? (old?.note ?? "") : note, created: Date(), expires: expires,
                                  lastUsed: nil, source: source))
        secrets.sort { $0.name.lowercased() < $1.name.lowercased() }
        saveIndex()
    }

    func setExpiry(_ name: String, _ date: Date?) {
        guard let i = secrets.firstIndex(where: { $0.name == name }) else { return }
        secrets[i].expires = date
        saveIndex()
    }

    func delete(_ name: String) {
        backend.remove(name)
        secrets.removeAll { $0.name == name }
        saveIndex()
    }

    /// Values for `names`, marking them used. Throws naming the first one that is missing or expired.
    func take(_ names: [String]) throws -> [String: String] {
        purgeExpired()
        var out: [String: String] = [:]
        for n in names {
            guard let i = secrets.firstIndex(where: { $0.name == n }), let v = backend.read(n) else {
                throw SecretError("No secret named \(n) (secret_list shows what exists; secret_request asks the user for one).")
            }
            secrets[i].lastUsed = Date()
            out[n] = v
        }
        if !names.isEmpty { saveIndex() }
        return out
    }

    /// Every stored value, for scrubbing output.
    func allValues() -> [(name: String, value: String)] {
        secrets.compactMap { s in backend.read(s.name).map { (s.name, $0) } }
    }

    private func purgeExpired() {
        let dead = secrets.filter(\.expired)
        guard !dead.isEmpty else { return }
        dead.forEach { backend.remove($0.name) }
        secrets.removeAll(where: \.expired)
        saveIndex()
    }

    private func saveIndex() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(secrets) else { return }
        if !FileManager.default.fileExists(atPath: indexPath) {
            FileManager.default.createFile(atPath: indexPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: URL(fileURLWithPath: indexPath), options: .atomic)
    }

    // MARK: Expiry

    static let expiryChoices: [(label: String, seconds: TimeInterval?)] = [
        ("Never", nil), ("1 hour", 3600), ("1 day", 86400), ("7 days", 7 * 86400), ("30 days", 30 * 86400), ("90 days", 90 * 86400),
    ]

    /// "30m", "12h", "7d", "2w", a number of seconds, or "never". nil for no expiry; throws when unreadable.
    static func parseLifetime(_ raw: Any?) throws -> TimeInterval? {
        if let n = raw as? NSNumber { return n.doubleValue > 0 ? n.doubleValue : nil }
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty, s != "never" else { return nil }
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400, "w": 7 * 86400]
        if let u = s.last, let mult = units[u], let n = Double(s.dropLast()), n > 0 { return n * mult }
        if let n = Double(s), n > 0 { return n }
        throw SecretError("expires_in must look like 30m, 12h, 7d, 2w or a number of seconds")
    }

    static func describe(expiry: Date?) -> String {
        guard let expiry else { return "never" }
        let s = expiry.timeIntervalSinceNow
        if s <= 0 { return "expired" }
        if s < 3600 { return "in \(max(1, Int(s / 60))) min" }
        if s < 2 * 86400 { return "in \(Int((s / 3600).rounded())) h" }
        return "in \(Int((s / 86400).rounded())) days"
    }
}

// MARK: - Scrubbing

/// Replaces every known secret in text with "[secret NAME]": the value itself, each long line of a multi-line
/// value (a PEM key), and the forms it commonly shows up in (base64, hex, URL-encoded, JSON-escaped).
struct SecretScrubber {
    private let needles: [(text: String, name: String)]

    init(_ secrets: [(name: String, value: String)]) {
        var list: [(String, String)] = []
        for (name, value) in secrets where value.count >= 4 {
            var forms: Set<String> = [value]
            let lines = value.split(whereSeparator: \.isNewline).map(String.init)
            if lines.count > 1 { lines.filter { $0.count >= 12 }.forEach { forms.insert($0) } }
            let data = Data(value.utf8)
            let b64 = data.base64EncodedString()
            forms.insert(b64)
            forms.insert(b64.replacingOccurrences(of: "=", with: ""))
            forms.insert(b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
            let hex = data.map { String(format: "%02x", $0) }.joined()
            forms.insert(hex); forms.insert(hex.uppercased())
            if let p = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { forms.insert(p) }
            if let p = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { forms.insert(p) }
            if let j = try? JSONEncoder().encode(value), let s = String(data: j, encoding: .utf8) { forms.insert(String(s.dropFirst().dropLast())) }
            for f in forms where f.count >= 4 { list.append((f, name)) }
        }
        needles = list.sorted { $0.0.count > $1.0.count }   // longest first, so a value isn't half-replaced
    }

    func scrub(_ text: String) -> String {
        var out = text
        for (needle, name) in needles where out.contains(needle) {
            out = out.replacingOccurrences(of: needle, with: "[secret \(name)]")
        }
        return out
    }
}

// MARK: - Running commands with secrets

enum SecretRunner {
    struct Result { let exit: Int32; let stdout: String; let stderr: String; let timedOut: Bool }

    /// Run `command` in the user's shell with `extra` added to the environment, and return what it printed.
    /// The caller scrubs it. stdin is empty; the command is stopped after `timeout` seconds.
    static func run(_ command: String, cwd: String, env base: [String: String], extra: [String: String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                let shell = base["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
                p.executableURL = URL(fileURLWithPath: shell)
                p.arguments = ["-c", command]
                p.environment = base.merging(extra) { _, new in new }
                p.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: Result(exit: 127, stdout: "", stderr: "couldn't start \(shell): \(error.localizedDescription)", timedOut: false))
                    return
                }
                // read both pipes while it runs (a full pipe would block the command)
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                let cap = 4 << 20
                for (pipe, isOut) in [(out, true), (err, false)] {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        var data = Data()
                        while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
                            if data.count < cap { data.append(chunk) }
                        }
                        if isOut { outData = data } else { errData = data }
                        group.leave()
                    }
                }
                var timedOut = false
                let killer = DispatchWorkItem {
                    guard p.isRunning else { return }
                    timedOut = true
                    p.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                // a background child may hold the pipes open: don't wait for it forever
                _ = group.wait(timeout: .now() + 2)
                cont.resume(returning: Result(exit: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                                              stderr: String(decoding: errData, as: UTF8.self), timedOut: timedOut))
            }
        }
    }

    /// Keep tool results a readable size (after scrubbing).
    static func clip(_ s: String, limit: Int = 30_000) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit / 2)) + "\n… [\(s.count - limit) characters left out] …\n" + String(s.suffix(limit / 2))
    }
}

// MARK: - Asking the user

/// One pending `secret_request`, shown as a panel over the project window it came from.
struct SecretAsk: Identifiable {
    let id = UUID()
    let name: String
    let reason: String
    let session: String
    /// The lifetime the agent suggested (the user decides).
    let suggested: TimeInterval?
    let replacing: Bool
    /// Called once with what the user typed and the expiry they chose, or nil when they decline.
    let done: ((value: String, lifetime: TimeInterval?)?) -> Void
}

enum SecretPrompt {
    /// Ask the user for the value of `name` in `model`'s window. Returns nil when they decline.
    /// The value goes straight to the store: it is never shown to the agent.
    @MainActor
    static func ask(name: String, reason: String, session: String, suggested: TimeInterval?, replacing: Bool,
                    in model: ProjectModel) async -> (value: String, lifetime: TimeInterval?)? {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        return await withCheckedContinuation { cont in
            model.secretAsks.append(SecretAsk(name: name, reason: reason, session: session, suggested: suggested,
                                              replacing: replacing, done: { cont.resume(returning: $0) }))
        }
    }
}

/// The panel for a secret request, in the active theme like the command palette: what is asked and by whom,
/// a field for the value, an expiry, Save and Decline. ↵ saves, esc declines.
struct SecretAskPanel: View {
    let ask: SecretAsk
    @EnvironmentObject var model: ProjectModel
    @ObservedObject private var theme = ThemeChanges.shared
    @State private var value = ""
    @State private var choice = 0
    @FocusState private var focused: Bool
    @StateObject private var keys = KeyMonitor()

    private var accent: SwiftUI.Color { SwiftUI.Color(nsColor: Theme.accent) }
    private var tooShort: Bool { value.count < SecretStore.minLength }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "key.fill").font(.system(size: 11)).foregroundStyle(accent)
                Text(ask.replacing ? "REPLACE SECRET" : "SECRET REQUESTED").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(ask.session).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 14).frame(height: 30)
            Hairline()
            VStack(alignment: .leading, spacing: 10) {
                Text(ask.name).font(.system(size: 15, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                if !ask.reason.isEmpty {
                    Text(ask.reason).font(.system(size: 13)).foregroundStyle(SwiftUI.Color(nsColor: Theme.foreground).opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                SecureField("Paste or type the value", text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(SwiftUI.Color(nsColor: Theme.background))
                    .overlay(Rectangle().stroke(accent, lineWidth: 1))
                    .focused($focused)
                    .onSubmit(save)
                    .padding(.top, 2)
                HStack(spacing: 6) {
                    Text("Expires").font(.system(size: 12)).foregroundStyle(.secondary).padding(.trailing, 2)
                    ForEach(Array(SecretStore.expiryChoices.enumerated()), id: \.offset) { i, c in
                        Button { choice = i } label: {
                            Text(c.label).font(.system(size: 11.5))
                                .padding(.horizontal, 8).frame(height: 22)
                                .foregroundStyle(i == choice ? SwiftUI.Color.white : SwiftUI.Color(nsColor: Theme.foreground).opacity(0.8))
                                .background(i == choice ? accent : SwiftUI.Color(nsColor: Theme.background))
                                .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.border), lineWidth: i == choice ? 0 : 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Stored by Studio. Agents use it in commands as $\(ask.name) and never see it; it is scrubbed from command output.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            Hairline()
            HStack(spacing: 8) {
                Text("↵ save   esc decline").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button { finish(nil) } label: {
                    Text("Decline").font(.system(size: 12)).padding(.horizontal, 12).frame(height: 24)
                        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.border), lineWidth: 1)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(action: save) {
                    Text("Save").font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).frame(height: 24)
                        .foregroundStyle(.white).background(accent.opacity(tooShort ? 0.4 : 1)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(tooShort)
                .help(tooShort ? "At least \(SecretStore.minLength) characters" : "Save \(ask.name)")
            }
            .padding(.horizontal, 14).frame(height: 40)
        }
        .frame(width: 520)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.border), lineWidth: 1))
        .compositingGroup()     // one shadow for the panel, none under its fields and buttons
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .onAppear {
            focused = true
            if let s = ask.suggested {
                // the shortest choice that covers what the agent asked for
                choice = SecretStore.expiryChoices.firstIndex { ($0.seconds ?? 0) >= s } ?? 0
            }
            keys.start { e in
                if e.keyCode == 53 { finish(nil); return true }     // esc
                return false
            }
        }
        .onDisappear { keys.stop() }
    }

    private func save() {
        guard !tooShort else { return }
        finish((value, SecretStore.expiryChoices[choice].seconds))
    }

    private func finish(_ result: (value: String, lifetime: TimeInterval?)?) {
        guard let i = model.secretAsks.firstIndex(where: { $0.id == ask.id }) else { return }
        model.secretAsks.remove(at: i)
        value = ""
        ask.done(result)
        model.focusTerminal()
    }
}

// MARK: - Settings → Secrets

struct SecretSettings: View {
    @ObservedObject private var store = SecretStore.shared
    @State private var name = ""
    @State private var value = ""
    @State private var note = ""
    @State private var lifetime = 0          // index into expiryChoices
    @State private var error: String?
    @State private var confirmDelete: String?
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Secrets are values agents can use without seeing them. A session asks for one by name and you type it into a Studio dialog, or you add it here. Sessions run commands with a secret in the environment (as $NAME); Studio scrubs the value from what the command prints, so it stays out of conversations and transcripts. Values are kept \(store.usesKeychain ? "in your login keychain" : "in a private file in Studio's Application Support folder (this build is unsigned; release builds use the keychain)").")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Group {
                HStack(spacing: 8) {
                    TextField("NAME (e.g. GITHUB_TOKEN)", text: $name)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 210)
                    SecureField("Value", text: $value).textFieldStyle(.roundedBorder).font(.system(size: 12)).onSubmit(add)
                }
                HStack(spacing: 8) {
                    TextField("What it's for (optional)", text: $note).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    Picker("Expires", selection: $lifetime) {
                        ForEach(Array(SecretStore.expiryChoices.enumerated()), id: \.offset) { i, c in Text(c.label).tag(i) }
                    }
                    .frame(width: 170)
                    Button("Add Secret", action: add).disabled(name.isEmpty || value.isEmpty)
                }
                .padding(.top, 6)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 4) }
            }
            HStack(spacing: 0) {
                Text("NAME").frame(width: 190, alignment: .leading)
                Text("FOR").frame(maxWidth: .infinity, alignment: .leading)
                Text("EXPIRES").frame(width: 100, alignment: .leading)
                Text("LAST USED").frame(width: 80, alignment: .leading)
                Text("ADDED BY").frame(width: 110, alignment: .leading)
                Text("").frame(width: 60)
            }
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, 22).padding(.bottom, 6)
            Hairline()
            if store.secrets.isEmpty {
                Text("No secrets yet.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(store.secrets) { s in
                HStack(spacing: 0) {
                    Text(s.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .frame(width: 190, alignment: .leading).textSelection(.enabled)
                    Text(s.note.isEmpty ? "—" : s.note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).help(s.note)
                    Menu(SecretStore.describe(expiry: s.expires)) {
                        ForEach(Array(SecretStore.expiryChoices.enumerated()), id: \.offset) { _, c in
                            Button(c.seconds == nil ? "Never expires" : "Expires in \(c.label)") {
                                store.setExpiry(s.name, c.seconds.map { Date().addingTimeInterval($0) })
                            }
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().font(.system(size: 12))
                    .frame(width: 100, alignment: .leading)
                    Text(s.lastUsed.map { relativeTime($0) } ?? "never").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(s.source).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: 110, alignment: .leading).help(s.source)
                    Button("Delete") { confirmDelete = s.name }.buttonStyle(.borderless).font(.system(size: 12))
                        .frame(width: 60, alignment: .trailing)
                }
                .frame(height: 30)
                .overlay(alignment: .bottom) { Hairline() }
            }
            .id(now)   // the relative times
        }
        .onReceive(tick) { now = $0 }
        .alert("Delete the secret \(confirmDelete ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let n = confirmDelete { store.delete(n) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Sessions that use it will fail until it is added again.") }
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces)
        do {
            try store.set(n, value: value, note: note.trimmingCharacters(in: .whitespaces),
                          expires: SecretStore.expiryChoices[lifetime].seconds.map { Date().addingTimeInterval($0) }, source: "you")
            name = ""; value = ""; note = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
