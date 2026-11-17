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

    init(cwd: String, claudeArgs: [String], sessionId: String?, fontSize: CGFloat = 12) {
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

    private func start() { launch(claudeArgs) }

    /// Restart after the process exited (e.g. user quit claude). Resumes the same conversation.
    func restart() {
        guard !running else { return }
        view.resetToInitialState()
        launch(sessionId.map { ["--resume", $0] } ?? claudeArgs)
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
        env["TERM_PROGRAM"] = "AICode"
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

/// Matches Terminal.app's "Clear Dark" profile: SF Mono, slate background, soft ANSI palette.
enum Theme {
    static let background = NSColor(srgbRed: 0.130, green: 0.153, blue: 0.203, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.902, green: 0.902, blue: 0.902, alpha: 1)
    static let selection = NSColor(srgbRed: 0.201, green: 0.305, blue: 0.370, alpha: 1)
    /// Sidebar / tab bar: a step darker than the terminal, like VS Code's chrome.
    static let chrome = NSColor(srgbRed: 0.098, green: 0.114, blue: 0.153, alpha: 1)
    static let border = NSColor(white: 1, alpha: 0.08)

    // black, red, green, yellow, blue, magenta, cyan, white, then bright variants
    static let ansi: [(Double, Double, Double)] = [
        (0.208, 0.259, 0.296), (0.705, 0.336, 0.281), (0.424, 0.667, 0.442), (0.769, 0.675, 0.384),
        (0.427, 0.588, 0.706), (0.741, 0.482, 0.804), (0.485, 0.795, 0.806), (0.869, 0.900, 0.922),
        (0.276, 0.363, 0.426), (0.876, 0.424, 0.353), (0.474, 0.743, 0.492), (0.898, 0.784, 0.447),
        (0.404, 0.710, 0.929), (0.827, 0.537, 0.898), (0.518, 0.868, 0.880), (0.900, 0.935, 0.962),
    ]

    static func font(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func apply(to view: LocalProcessTerminalView, fontSize: CGFloat) {
        view.font = font(fontSize)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.selectedTextBackgroundColor = selection
        view.caretColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        view.optionAsMetaKey = true
        view.installColors(ansi.map {
            SwiftTerm.Color(red: UInt16($0.0 * 65535), green: UInt16($0.1 * 65535), blue: UInt16($0.2 * 65535))
        })
    }
}
