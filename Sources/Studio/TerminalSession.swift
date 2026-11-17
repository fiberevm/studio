import AppKit
import SwiftTerm

/// One embedded terminal running a `claude` process. Kept alive while the app runs,
/// so switching between sessions in the sidebar doesn't restart anything.
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let cwd: String
    let createdAt = Date()
    @Published var sessionId: String?
    @Published private(set) var running = false
    @Published private(set) var exitCode: Int32?
    @Published var terminalTitle: String = ""

    let view: LocalProcessTerminalView
    private(set) var pid: Int32 = 0
    private let claudeArgs: [String]
    /// .claude runs a Claude Code session; .shell is a plain terminal (⌃`), like VS Code's integrated terminal.
    enum Kind { case claude, shell }
    let kind: Kind
    var isShell: Bool { kind == .shell }

    init(cwd: String, claudeArgs: [String], sessionId: String?, fontSize: CGFloat = 12, kind: Kind = .claude) {
        self.kind = kind
        self.cwd = cwd
        self.claudeArgs = claudeArgs
        self.sessionId = sessionId
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init()
        Theme.apply(to: view, fontSize: fontSize)
        view.processDelegate = self
        start()
    }

    func setFontSize(_ size: CGFloat) {
        view.font = Theme.font(size)
    }

    private func start() { if isShell { launchShell() } else { launch(claudeArgs) } }

    /// The user's login shell, interactive (it's on a pty), in the project folder.
    private func launchShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        view.startProcess(executable: shell, args: ["-l"], environment: Self.childEnvironment(),
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: dir)
        pid = view.process.shellPid
        running = true
        exitCode = nil
    }

    /// Restart after the process exited (e.g. user quit claude). Resumes the same conversation.
    func restart() {
        guard !running else { return }
        view.resetToInitialState()
        if isShell { launchShell() } else { launch(sessionId.map { ["--resume", $0] } ?? claudeArgs) }
    }

    private func launch(_ args: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        let cmd = (["exec", "claude"] + args).map(shellQuote).joined(separator: " ")
        // Login + interactive shell so the user's PATH (and therefore `claude`) resolves like in Terminal.
        // `exec` keeps the pid, so ~/.claude/sessions/<pid>.json maps back to this terminal.
        view.startProcess(executable: shell, args: ["-l", "-i", "-c", cmd],
                          environment: Self.childEnvironment(), execName: nil, currentDirectory: dir)
        pid = view.process.shellPid
        running = true
        exitCode = nil
    }

    func terminate() {
        if running, pid > 0 { kill(pid, SIGHUP) }
    }

    static func childEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        // If the app was launched from inside a Claude Code session, don't leak its markers.
        for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: k) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Studio"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.terminalTitle = title }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.running = false
            self.exitCode = exitCode
        }
    }
}

func shellQuote(_ s: String) -> String {
    if s.range(of: "^[A-Za-z0-9_./=:-]+$", options: .regularExpression) != nil { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

