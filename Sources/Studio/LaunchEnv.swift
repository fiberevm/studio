import Foundation

/// The user's login-shell environment and where each agent CLI lives, captured once in the background
/// (and refreshed now and then), so new tabs exec the CLI directly instead of starting a login shell
/// to find it on every launch. Kept in memory only: the environment can hold secrets from shell rc files.
enum LaunchEnv {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var env: [String: String]?
    nonisolated(unsafe) private static var paths: [String: String] = [:]
    nonisolated(unsafe) private static var capturedAt = Date.distantPast
    nonisolated(unsafe) private static var capturing = false

    /// Start (or refresh, when older than 10 minutes) the capture.
    static func refreshIfStale() {
        lock.lock()
        let go = !capturing && Date().timeIntervalSince(capturedAt) > 600
        if go { capturing = true }
        lock.unlock()
        guard go else { return }
        DispatchQueue.global(qos: .utility).async { capture() }
    }

    /// argv to run `words` directly (absolute binary path), or nil when it isn't known yet / anymore.
    static func direct(_ words: [String]) -> [String]? {
        guard let cmd = words.first else { return nil }
        lock.lock(); let p = paths[cmd]; let ready = env != nil; lock.unlock()
        guard ready, let p, FileManager.default.isExecutableFile(atPath: p) else {
            if ready { invalidate() }   // moved or uninstalled: find it again
            return nil
        }
        return [p] + words.dropFirst()
    }

    /// Whether the capture found `cmd` on PATH (nil until it has run).
    static func has(_ cmd: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return env == nil ? nil : paths[cmd] != nil
    }

    /// The captured environment, with Studio's own variables on top; nil until captured.
    static func environment(tab: UUID?) -> [String: String]? {
        lock.lock(); guard var e = env else { lock.unlock(); return nil }; lock.unlock()
        if let tab { e["STUDIO_TAB"] = tab.uuidString }
        e["STUDIO_CONTROL_FILE"] = StudioControl.controlFilePath
        e["TERM"] = "xterm-256color"
        e["COLORTERM"] = "truecolor"
        e["TERM_PROGRAM"] = "Studio"
        if e["LANG"] == nil { e["LANG"] = "en_US.UTF-8" }
        return e
    }

    private static func invalidate() {
        lock.lock(); capturedAt = .distantPast; lock.unlock()
        refreshIfStale()
    }

    private static let skip: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
                                            "TERM_SESSION_ID", "COLORTERM", "TMUX", "TMUX_PANE", "STUDIO_TAB", "LINES",
                                            "COLUMNS", "PS1", "PS2", "CLAUDECODE"]

    private static func capture() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let cmds = Agent.allCases.map(\.command)
        // markers around the output: interactive rc files may print their own things
        let script = "printf '\\0STUDIO-ENV\\0'; env -0; printf '\\0STUDIO-PATHS\\0'; "
            + cmds.map { "printf '%s=%s\\n' \($0) \"$(command -v \($0))\"" }.joined(separator: "; ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", script]
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var penv = ProcessInfo.processInfo.environment
        for k in penv.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") { penv.removeValue(forKey: k) }
        p.environment = penv
        let out = Pipe()
        p.standardOutput = out
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { finish(nil, [:]); return }
        let reader = DispatchQueue.global()
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + 20) == .timedOut { p.terminate(); finish(nil, [:]); return }
        _ = done.wait(timeout: .now() + 2)

        let s = String(decoding: data, as: UTF8.self)
        guard let a = s.range(of: "\0STUDIO-ENV\0"), let b = s.range(of: "\0STUDIO-PATHS\0", range: a.upperBound..<s.endIndex) else {
            finish(nil, [:]); return
        }
        var e: [String: String] = [:]
        for entry in s[a.upperBound..<b.lowerBound].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let k = String(entry[..<eq])
            guard !skip.contains(k), !k.hasPrefix("CLAUDE_CODE_"), !k.hasPrefix("BASH_FUNC_"),
                  k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            e[k] = String(entry[entry.index(after: eq)...])
        }
        var found: [String: String] = [:]
        for line in s[b.upperBound...].split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[1].hasPrefix("/") { found[parts[0]] = parts[1] }
        }
        finish(e.isEmpty ? nil : e, found)
    }

    private static func finish(_ e: [String: String]?, _ found: [String: String]) {
        lock.lock()
        capturing = false
        if let e { env = e; paths = found; capturedAt = Date() }
        else { capturedAt = Date().addingTimeInterval(-540) }   // failed: try again in a minute
        lock.unlock()
        DispatchQueue.main.async { MainActor.assumeIsolated { AgentChecker.shared.launchEnvUpdated() } }
    }
}
