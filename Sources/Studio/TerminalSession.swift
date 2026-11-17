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
        view.startProcess(executable: shell, args: ["-l"], environment: Self.childEnvironment(tab: id),
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
        // Every session gets the Studio MCP so its AI can drive the editor. --mcp-config is variadic,
        // so it goes last (after any prompt or --resume).
        var args = args
        if let cfg = StudioControl.mcpConfigPath { args += ["--mcp-config", cfg] }
        let cmd = (["exec", "claude"] + args).map(shellQuote).joined(separator: " ")
        // Login + interactive shell so the user's PATH (and therefore `claude`) resolves like in Terminal.
        // `exec` keeps the pid, so ~/.claude/sessions/<pid>.json maps back to this terminal.
        view.startProcess(executable: shell, args: ["-l", "-i", "-c", cmd],
                          environment: Self.childEnvironment(tab: id), execName: nil, currentDirectory: dir)
        pid = view.process.shellPid
        running = true
        exitCode = nil
    }

    /// Type text into the terminal as if the user had (used by the Studio MCP's run_in_terminal).
    func type(_ text: String) { view.send(txt: text) }

    /// Type a message into Claude's prompt and press Return. The Return goes a beat later so Claude
    /// doesn't treat it as part of a paste (which would add a newline instead of sending).
    func submit(_ text: String) {
        guard running else { return }
        // Bracketed paste: Claude takes the whole text as one input, and characters like ! # ? / at the
        // start aren't read as its shortcuts.
        view.pasteText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.view.send(txt: "\r") }
    }

    func terminate() {
        if running, pid > 0 { kill(pid, SIGHUP) }
    }

    static func childEnvironment(tab: UUID? = nil) -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Lets the Studio MCP (and scripts) know which tab they run in and how to reach the app.
        if let tab { env["STUDIO_TAB"] = tab.uuidString }
        env["STUDIO_CONTROL_FILE"] = StudioControl.controlFilePath
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

