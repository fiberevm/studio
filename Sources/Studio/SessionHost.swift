import Foundation

/// Keeps sessions alive across Studio restarts by running each tab's process inside its own hidden tmux
/// session on a private socket. A Studio tab is only a tmux client: quitting Studio leaves Claude (and
/// anything it started) running, and the next launch reattaches. Without tmux, Studio falls back to
/// owning the processes directly (they end on quit and conversations are resumed).
enum SessionHost {
    static let tmux: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static var enabled: Bool { tmux != nil && Pref.bool(Pref.keepSessionsAlive, default: true) }

    /// One socket per app copy, so a preview build can never see or touch the real app's sessions.
    static let socket: String = {
        let id = Bundle.main.bundleIdentifier ?? "studio"
        return id == "dev.local.studio" ? "studio" : "studio-" + (id.split(separator: ".").last.map(String.init) ?? "dev")
    }()

    /// Invisible tmux: no status bar, no prefix key (every key goes to the app), true color, titles passed
    /// through, and no alternate screen so output lands in Studio's own scrollback.
    static let config: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Studio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("tmux-\(socket).conf").path
        let conf = """
        set -g status off
        set -g prefix None
        unbind-key -a
        set -g escape-time 0
        set -g history-limit 50000
        set -g mouse off
        set -g focus-events on
        set -g default-terminal "tmux-256color"
        set -as terminal-features ",xterm-256color:RGB"
        set -ga terminal-overrides ",xterm-256color:smcup@:rmcup@"
        set -g set-titles off
        set -g allow-passthrough on
        set -g window-size latest
        set -g remain-on-exit off
        set -g exit-empty on
        """
        try? conf.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }()

    static func newName() -> String { "s-" + UUID().uuidString.prefix(8).lowercased() }

    /// Arguments for the tab's client: attach to `name`, creating it with `command` if it doesn't exist yet.
    static func clientArgs(name: String, cwd: String, env: [String: String], command: [String]) -> [String] {
        var args = ["-L", socket, "-f", config, "new-session", "-A", "-s", name, "-c", cwd]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { args += ["-e", "\(k)=\(v)"] }
        return args + command
    }

    @discardableResult
    private static func run(_ args: [String]) -> (ok: Bool, out: String) {
        guard let tmux else { return (false, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["-L", socket] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        // Not waitUntilExit(): it spins the run loop, and running SwiftUI updates re-entrantly while a window
        // is being built crashes AttributeGraph. A semaphore blocks without pumping events.
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (false, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus == 0, s)
    }

    static func exists(_ name: String) -> Bool { tmux != nil && run(["has-session", "-t", "=" + name]).ok }

    /// End the session for good (closing a tab, ending a session).
    static func kill(_ name: String) { run(["kill-session", "-t", "=" + name]) }

    /// The pid of the process running inside the session (claude or the shell), for status lookups.
    /// The text on the session's screen right now.
    static func screen(_ name: String) -> String? {
        let r = run(["capture-pane", "-p", "-t", "=" + name + ":"])
        return r.ok ? r.out : nil
    }

    static func panePid(_ name: String) -> Int32? {
        // "=name:" — exact session name, its current pane ("=name" alone doesn't resolve to a pane)
        Int32(run(["display-message", "-p", "-t", "=" + name + ":", "#{pane_pid}"]).out)
    }
}
