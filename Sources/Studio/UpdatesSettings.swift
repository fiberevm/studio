import SwiftUI
import Security

/// One published release of Studio, from GitHub.
struct StudioRelease: Identifiable, Equatable {
    let version: String
    let date: Date?
    /// What changed: the release's notes, without the install instructions under them.
    let notes: String
    let zip: URL?
    let page: URL
    var id: String { version }
}

enum StudioReleases {
    static let api = URL(string: "https://api.github.com/repos/fiberevm/studio/releases?per_page=50")!

    /// Every published release, newest first.
    static func fetch() async throws -> [StudioRelease] {
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw SecretError(h.statusCode == 403 ? "GitHub is limiting requests right now; try again in a few minutes." : "GitHub answered \(h.statusCode).")
        }
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return list.compactMap { r in
            guard let tag = r["tag_name"] as? String, (r["draft"] as? Bool) != true, (r["prerelease"] as? Bool) != true,
                  let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let body = (r["body"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            let notes = body.components(separatedBy: "<!-- install -->").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // this Mac's build (Studio-arm64.zip / Studio-x86_64.zip); releases up to 0.0.14 have one universal Studio.zip
            let assets = r["assets"] as? [[String: Any]] ?? []
            let zip = ["Studio-\(archName).zip", "Studio.zip"].lazy
                .compactMap { name in assets.first { $0["name"] as? String == name } }.first
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            return StudioRelease(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                                 date: (r["published_at"] as? String).flatMap(iso.date(from:)),
                                 notes: notes, zip: zip, page: page)
        }
        .sorted { compare($0.version, $1.version) == .orderedDescending }
    }

    /// The architecture this copy was built for, as release assets name it.
    static var archName: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// 0.0.10 after 0.0.9.
    static func compare(_ a: String, _ b: String) -> ComparisonResult { a.compare(b, options: .numeric) }
}

/// Installs a chosen release in place of this copy: downloads its Studio.zip, checks it is Studio signed by the
/// same developer, then quits, swaps the app and opens the new one (sessions in tmux keep running).
@MainActor
final class VersionInstaller: ObservableObject {
    static let shared = VersionInstaller()
    enum State: Equatable { case idle, downloading(version: String, received: Int64, expected: Int64?), verifying(String), restarting(String), failed(String) }
    @Published private(set) var state: State = .idle
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    /// Whether this copy can swap itself: a release build in a folder it can write to.
    static var canInstall: Bool {
        guard Updater.shared.enabled, teamID(ofCodeAt: nil) != nil else { return false }
        let app = Bundle.main.bundlePath
        return FileManager.default.isWritableFile(atPath: (app as NSString).deletingLastPathComponent)
            && FileManager.default.isWritableFile(atPath: app)
    }

    func install(_ r: StudioRelease) {
        guard let zip = r.zip else { state = .failed("Studio \(r.version) has no download for this Mac to install."); return }
        install(zip: zip, version: r.version)
    }

    func install(zip: URL, version: String) {
        guard case .idle = state, Self.canInstall || ProcessInfo.processInfo.environment["STUDIO_TEST_INSTALL"] != nil else {
            if case .failed = state {} else { return }
            return
        }
        state = .downloading(version: version, received: 0, expected: nil)
        let t = URLSession.shared.downloadTask(with: zip) { [weak self] file, resp, error in
            // the file is deleted when this returns: move it somewhere of our own first
            var kept: URL?
            if let file {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("studio-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: file, to: dest)) != nil { kept = dest }
            }
            let failure = error?.localizedDescription ?? ((resp as? HTTPURLResponse).map { $0.statusCode == 200 ? nil : "The download failed (\($0.statusCode))." } ?? nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.observation = nil
                    if let kept, failure == nil { self.verifyAndSwap(kept, version: version) }
                    else { self.state = .failed(failure ?? "The download failed.") }
                }
            }
        }
        observation = t.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let got = p.completedUnitCount, total = p.totalUnitCount
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .downloading = self?.state { self?.state = .downloading(version: version, received: got, expected: total > 0 ? total : nil) }
                }
            }
        }
        task = t
        t.resume()
    }

    func cancel() { task?.cancel(); task = nil; observation = nil; state = .idle }
    func reset() { if case .failed = state { state = .idle } }

    private func verifyAndSwap(_ zip: URL, version: String) {
        state = .verifying(version)
        let target = Bundle.main.bundlePath
        let myID = Bundle.main.bundleIdentifier, myTeam = Self.teamID(ofCodeAt: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-install-\(UUID().uuidString)")
            var problem: String?
            var app: URL?
            if Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) != 0 { problem = "Couldn't unpack the download." }
            else if let found = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }) {
                app = found
                let id = Bundle(url: found)?.bundleIdentifier
                if id != myID { problem = "The download isn't this app (\(id ?? "unknown"))." }
                else if Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", found.path]) != 0 { problem = "The download's signature doesn't check out." }
                else if Self.teamID(ofCodeAt: found) != myTeam { problem = "The download is signed by a different developer." }
            } else { problem = "The download holds no app." }
            try? FileManager.default.removeItem(at: zip)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let problem { self.state = .failed(problem); try? FileManager.default.removeItem(at: dir); return }
                    guard let app else { return }
                    // an older version: keep it, instead of updating straight back to the newest
                    if StudioReleases.compare(version, Updater.currentVersion) == .orderedAscending { Updater.shared.automatic = false }
                    self.state = .restarting(version)
                    Self.swap(in: app, for: target, cleanup: dir)
                }
            }
        }
    }

    /// Quit, then (in a small script that outlives Studio) put `app` in place of `target` and open it.
    private static func swap(in app: URL, for target: String, cleanup: URL) {
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        old="\(target).previous-$$"
        mv "\(target)" "$old" && ditto "\(app.path)" "\(target)" && rm -rf "$old" || { rm -rf "\(target)"; mv "$old" "\(target)"; }
        rm -rf "\(cleanup.path)"
        open "\(target)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    @discardableResult
    private nonisolated static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// The developer team that signed this app (nil: `at` the running app) or another bundle; nil when ad hoc.
    nonisolated static func teamID(ofCodeAt url: URL?) -> String? {
        var code: SecStaticCode?
        if let url {
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        } else {
            var running: SecCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
                  SecCodeCopyStaticCode(running, [], &code) == errSecSuccess else { return nil }
        }
        guard let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any], let t = d[kSecCodeInfoTeamIdentifier as String] as? String, !t.isEmpty else { return nil }
        return t
    }
}

/// Settings → Updates: automatic updates, Check for Updates, and every release with its notes. Any other
/// version can be installed from here, including an older one to go back to.
struct UpdatesSettings: View {
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var installer = VersionInstaller.shared
    @State private var releases: [StudioRelease] = []
    @State private var loading = true
    @State private var error: String?
    @State private var confirm: StudioRelease?

    var body: some View {
        let current = Updater.currentVersion
        VStack(alignment: .leading, spacing: 0) {
            if updater.enabled {
                ToggleRow(title: "Update automatically",
                          detail: "Studio checks for a new version about once a day, downloads it in the background and installs it when you quit.",
                          isOn: $updater.automatic)
            }
            Row(title: "You have Studio \(current)",
                detail: updater.enabled ? "Check now to see if there's a newer version, and install it right away."
                                        : "This copy is built from source, so it doesn't update itself. Releases from GitHub do.") {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
            HStack {
                Group_(title: "Releases")
                Spacer()
                if loading { ProgressView().controlSize(.small).padding(.top, 20) }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.vertical, 8) }
            if case .failed(let m) = installer.state {
                HStack {
                    Text(m).font(.system(size: 12)).foregroundStyle(.red)
                    Spacer()
                    Button("OK") { installer.reset() }.buttonStyle(.borderless).font(.system(size: 12))
                }
                .padding(.vertical, 8)
            }
            Hairline()
            ForEach(releases) { r in row(r, current: current) }
        }
        .task { await load() }
        .alert(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirmButton) { if let r = confirm { installer.install(r) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirmMessage) }
    }

    private func row(_ r: StudioRelease, current: String) -> some View {
        let order = StudioReleases.compare(r.version, current)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("Studio \(r.version)").font(.system(size: 14, weight: .semibold))
                if order == .orderedSame { tag("Installed") }
                if r.id == releases.first?.id && order != .orderedSame { tag("Latest") }
                if let d = r.date { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer(minLength: 12)
                action(r, order: order)
            }
            if !r.notes.isEmpty {
                Text(markdown(r.notes)).font(.system(size: 12.5)).foregroundStyle(SwiftUI.Color(nsColor: Theme.foreground).opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Hairline() }
    }

    @ViewBuilder private func action(_ r: StudioRelease, order: ComparisonResult) -> some View {
        switch installer.state {
        case .downloading(let v, let got, let total) where v == r.version:
            HStack(spacing: 8) {
                Text(total.map { "\(bytes(got)) of \(bytes($0))" } ?? bytes(got)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                ProgressView(value: total.map { Double(got) / Double(max($0, 1)) } ?? 0).frame(width: 90)
                Button("Cancel") { installer.cancel() }.buttonStyle(.borderless).font(.system(size: 12))
            }
        case .verifying(let v) where v == r.version:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking the signature…").font(.system(size: 12)).foregroundStyle(.secondary) }
        case .restarting(let v) where v == r.version:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Restarting…").font(.system(size: 12)).foregroundStyle(.secondary) }
        default:
            if order != .orderedSame {
                Button(order == .orderedAscending ? "Go Back to This Version…" : "Install…") { confirm = r }
                    .disabled(!VersionInstaller.canInstall || installer.state != .idle || r.zip == nil)
                    .help(VersionInstaller.canInstall ? "Install Studio \(r.version) in place of \(Updater.currentVersion)"
                                                      : "Only a release build of Studio can install another version")
            }
        }
    }

    private var confirmTitle: String {
        guard let r = confirm else { return "" }
        return StudioReleases.compare(r.version, Updater.currentVersion) == .orderedAscending ? "Go back to Studio \(r.version)?" : "Install Studio \(r.version)?"
    }
    private var confirmButton: String {
        guard let r = confirm else { return "" }
        return StudioReleases.compare(r.version, Updater.currentVersion) == .orderedAscending ? "Go Back and Restart" : "Install and Restart"
    }
    private var confirmMessage: String {
        guard let r = confirm else { return "" }
        let older = StudioReleases.compare(r.version, Updater.currentVersion) == .orderedAscending
        return "Studio downloads \(r.version), checks its signature and restarts into it. Your sessions keep running."
            + (older ? " Automatic updates are turned off, so it stays on \(r.version); turn them back on here when you're ready." : "")
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(SwiftUI.Color(nsColor: Theme.accent))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.accent).opacity(0.6), lineWidth: 1))
    }

    private func markdown(_ s: String) -> AttributedString {
        let s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("- ") ? "•  " + $0.dropFirst(2) : String($0) }.joined(separator: "\n")
        return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func load() async {
        loading = true
        do { releases = try await StudioReleases.fetch(); error = nil }
        catch { self.error = "Couldn't load the releases: \(error.localizedDescription)" }
        loading = false
    }
}
