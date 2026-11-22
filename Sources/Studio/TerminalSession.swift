import AppKit
import Combine
import SwiftTerm
import WebKit

/// One embedded terminal running a `claude` process. Kept alive while the app runs,
/// so switching between sessions in the sidebar doesn't restart anything.
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    /// The hidden tmux session this tab's process lives in (sessions survive Studio restarts), if hosted.
    private(set) var hostName: String?
    /// The process inside the host session (claude or the shell); `pid` is only the tmux client then.
    private(set) var hostedPid: Int32?
    /// The pid Claude Code records in ~/.claude/sessions/<pid>.json for this tab.
    var sessionPid: Int32 { hostedPid ?? pid }
    private(set) var cwd: String
    /// Set while the tab waits for its worktree (the worktree's name); the process starts once it's ready.
    @Published private(set) var preparing: String?
    let createdAt = Date()
    @Published var sessionId: String?
    @Published private(set) var running = false
    @Published private(set) var exitCode: Int32?
    @Published var terminalTitle: String = ""

    let view: LocalProcessTerminalView
    private(set) var pid: Int32 = 0
    private let claudeArgs: [String]
    /// .claude runs a Claude Code session; .codex runs OpenAI's Codex CLI; .shell is a plain terminal (⌃`),
    /// like VS Code's integrated terminal.
    enum Kind { case claude, codex, agy, worker, shell, web, file }
    let kind: Kind
    var isShell: Bool { kind == .shell }
    var isClaude: Bool { kind == .claude }
    var isCodex: Bool { kind == .codex }
    var isAgy: Bool { kind == .agy }
    /// A session on a worker (a machine running studio-worker); this tab is only its terminal.
    var isWorker: Bool { kind == .worker }
    /// For .worker: which worker and which of its sessions.
    let remote: (worker: String, session: String)?
    /// A coding agent's session (Claude Code or Codex), as opposed to a plain terminal or web panel.
    var isAgent: Bool { agent != nil }
    var agent: Agent? {
        switch kind { case .claude: return .claude; case .codex: return .codex; case .agy: return .agy; default: return nil }
    }

    var isWeb: Bool { kind == .web }
    /// A file open in the editor (from ⌘K); no process.
    var isFile: Bool { kind == .file }
    var filePath: String?
    @MainActor lazy var fileDoc: FileDoc? = filePath.map { FileDoc(path: $0) }
    /// The editor's text view once it's on screen (for focus).
    weak var fileTextView: NSTextView?

    // MARK: Web panel (kind .web): a browser tab, like a terminal tab
    @Published var url: URL?
    @Published var webTitle = ""
    /// Kept for the tab's lifetime so switching tabs doesn't reload the page.
    lazy var webView: WKWebView = {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.allowsBackForwardNavigationGestures = true
        w.navigationDelegate = webDelegate
        webDelegate.tab = self
        if let url { w.load(URLRequest(url: url)) }
        return w
    }()
    private let webDelegate = WebDelegate()

    func navigate(_ u: URL) {
        url = u
        webView.load(URLRequest(url: u))
    }

    init(cwd: String, claudeArgs: [String], sessionId: String?, fontSize: CGFloat = 12, kind: Kind = .claude,
         native: Bool = false, id: UUID = UUID(), host: String? = nil, remote: (worker: String, session: String)? = nil,
         preparing: String? = nil) {
        self.id = id
        self.remote = remote
        self.hostName = host
        self.kind = kind
        self.cwd = cwd
        self.claudeArgs = claudeArgs
        self.sessionId = sessionId
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init()
        Theme.apply(to: view, fontSize: fontSize)
        view.processDelegate = self
        if let preparing { self.preparing = preparing; running = true }   // shows as starting, not exited
        else if native, agent != nil, let sid = sessionId { startNative(sid) } else { start() }
    }

    /// The worktree is ready (or wasn't made: `cwd` is then the original folder): start the process there.
    func finishPreparing(in cwd: String) {
        guard preparing != nil else { return }
        self.cwd = cwd
        preparing = nil
        running = false
        start()
    }

    // MARK: Native (non-TUI) mode

    /// When set, this tab shows Studio's own rendering of the conversation (`claude -p`) instead of the TUI.
    @Published private(set) var native: NativeChat?
    private var switchingToNative = false
    var isNative: Bool { native != nil }

    /// Sessions the user switched to native mode, remembered across launches.
    static var nativeSessions: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "nativeSessions") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "nativeSessions") }
    }

    /// ⌘\: swap between Claude's terminal UI and the native view. Only one claude process ever runs
    /// for the conversation: the old one is stopped and the new one resumes it.
    func toggleNative() {
        guard isAgent else { return }
        if let n = native {
            n.stop()
            native = nil
            if let sid = n.sessionId ?? sessionId { sessionId = sid; Self.nativeSessions.remove(sid) }
            running = false
            restart()
        } else {
            guard let sid = sessionId else { return }
            Self.nativeSessions.insert(sid)
            if running {
                switchingToNative = true
                if let h = hostName { SessionHost.kill(h); hostName = nil } else { kill(pid, SIGHUP) }
            } else { startNative(sid) }
        }
    }

    private func startNative(_ sid: String) {
        let chat = NativeChat(cwd: cwd, tab: id, resume: sid, agent: agent ?? .claude)
        chat.onSessionId = { [weak self] s in self?.sessionId = s }
        native = chat
        nativeObserver = chat.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    private var nativeObserver: Any?

    /// Process ids this tab owns right now (for quitting cleanly).
    /// Hosted tabs keep running after Studio quits, so there's nothing of theirs to wait for.
    var livePids: [Int32] {
        if let n = native { return n.exited || n.pid <= 0 ? [] : [n.pid] }
        if hostName != nil { return [] }
        return running && pid > 0 ? [pid] : []
    }

    func setFontSize(_ size: CGFloat) {
        view.font = Theme.font(size)
    }

    private func start() {
        switch kind {
        case .shell: launchShell()
        case .claude: launch(claudeArgs)
        case .codex: launchCodex(claudeArgs)
        case .agy: launchCLI(["agy"] + claudeArgs)
        case .worker: launchWorker()
        case .web, .file: running = true    // no process; the page lives in webView, the file in fileDoc
        }
    }

    /// The user's login shell, interactive (it's on a pty), in the project folder.
    private func launchShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        if SessionHost.enabled { startHosted(command: [shell, "-l"], dir: dir); return }
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
        switch kind {
        case .shell: launchShell()
        // the same conversation, else the folder's latest
        case .codex: launchCodex(["resume"] + (sessionId.map { [$0] } ?? ["--last"]))
        case .agy: launchCLI(["agy"] + (sessionId.map { ["--conversation", $0] } ?? ["--continue"]))
        case .worker: launchWorker()
        default: launch(sessionId.map { ["--resume", $0] } ?? claudeArgs)
        }
    }

    /// The session lives on the worker (in its tmux); this runs studio-attach, which bridges the tab to it and
    /// reconnects by itself after sleep or a network drop.
    private func launchWorker() {
        guard let r = remote else { return }
        let found: (url: String, token: String)? = MainActor.assumeIsolated {
            WorkerRegistry.shared.worker(r.worker).map { ($0.url, WorkerRegistry.shared.token($0.id)) }
        }
        guard let w = found else {
            view.feed(text: "\r\nThis worker isn't paired anymore (Settings → Workers).\r\n")
            return
        }
        let exe = ((Bundle.main.executablePath ?? "") as NSString).deletingLastPathComponent + "/studio-attach"
        let env = Self.childEnvironment(tab: id) + ["STUDIO_WORKER_TOKEN=\(w.token)"]
        view.startProcess(executable: exe, args: [w.url, r.session], environment: env, execName: nil,
                          currentDirectory: NSHomeDirectory())
        pid = view.process.shellPid
        running = true
        exitCode = nil
    }

    /// A Codex CLI session, with the Studio MCP so it can drive the editor too.
    private func launchCodex(_ args: [String]) {
        var opts: [String] = []
        if let exe = StudioControl.mcpExecutable {
            // Codex starts MCP servers with a minimal environment, so hand studio-mcp its tab and app explicitly.
            opts += ["-c", "mcp_servers.studio.command=\"\(exe)\"",
                     "-c", "mcp_servers.studio.env={STUDIO_TAB=\"\(id.uuidString)\", STUDIO_CONTROL_FILE=\"\(StudioControl.controlFilePath)\"}"]
        }
        // the Studio skill, as instructions (Codex doesn't load Claude plugins)
        if let skill = MainActor.assumeIsolated({ StudioControl.skillTOML }) { opts += ["-c", "developer_instructions=" + skill] }
        // options go before a subcommand's own arguments: `codex resume -c … --last`, `codex -c … "prompt"`
        let full = ["resume", "fork"].contains(args.first) ? [args[0]] + opts + args.dropFirst() : opts + args
        launchCLI(["codex"] + full)
    }

    /// Run an agent CLI (`words`: the command and its arguments) through the login shell, so it resolves on
    /// the user's PATH like in Terminal; hosted in tmux when sessions are kept alive.
    private func launchCLI(_ words: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        LaunchEnv.refreshIfStale()
        // Fast path: the CLI's path and the shell's environment are already known, so exec it directly.
        if let argv = LaunchEnv.direct(words), let env = LaunchEnv.environment(tab: id) {
            if SessionHost.enabled {
                // the session takes the server's environment: make sure it's the shell's (a server started
                // by this client takes the client's, so pass it there too)
                SessionHost.setGlobalEnvironment(env.filter { !$0.key.hasPrefix("STUDIO_") })
                startHosted(command: argv, dir: dir, clientEnv: env.map { "\($0.key)=\($0.value)" })
                return
            }
            view.startProcess(executable: argv[0], args: Array(argv.dropFirst()),
                              environment: env.map { "\($0.key)=\($0.value)" }, execName: nil, currentDirectory: dir)
        } else {
            // Not captured yet (right after launch): through the login shell, so it resolves like in Terminal.
            // `exec` keeps the pid, so ~/.claude/sessions/<pid>.json maps back to this terminal.
            let cmd = (["exec"] + words).map(shellQuote).joined(separator: " ")
            if SessionHost.enabled { startHosted(command: [shell, "-l", "-i", "-c", cmd], dir: dir); return }
            view.startProcess(executable: shell, args: ["-l", "-i", "-c", cmd],
                              environment: Self.childEnvironment(tab: id), execName: nil, currentDirectory: dir)
        }
        pid = view.process.shellPid
        running = true
        exitCode = nil
    }

    private func launch(_ args: [String]) {
        // Every session gets the Studio MCP so its AI can drive the editor. --mcp-config is variadic,
        // so it goes last (after any prompt or --resume).
        var args = args
        if let plugin = StudioControl.pluginDir { args += ["--plugin-dir", plugin] }   // Studio + Sandbox skills
        if let cfg = StudioControl.mcpConfigPath { args += ["--mcp-config", cfg] }
        launchCLI(["claude"] + args)
    }

    /// Attach to this tab's host session, creating it (running `command`) if it doesn't exist yet.
    private func startHosted(command: [String], dir: String, clientEnv: [String]? = nil) {
        guard let tmux = SessionHost.tmux else { return }
        let name = hostName ?? SessionHost.newName()
        hostName = name
        let env = ["STUDIO_TAB": id.uuidString, "STUDIO_CONTROL_FILE": StudioControl.controlFilePath,
                   "TERM_PROGRAM": "Studio", "COLORTERM": "truecolor"]
        view.startProcess(executable: tmux, args: SessionHost.clientArgs(name: name, cwd: dir, env: env, command: command),
                          environment: clientEnv ?? Self.childEnvironment(tab: id), execName: nil, currentDirectory: dir)
        pid = view.process.shellPid
        running = true
        exitCode = nil
        // The process inside the session, for ~/.claude/sessions/<pid>.json lookups. The session may take
        // a moment to come up, so keep asking for a few seconds.
        DispatchQueue.global().async { [weak self] in
            for _ in 0..<40 {
                if let p = SessionHost.panePid(name) { DispatchQueue.main.async { self?.hostedPid = p }; return }
                usleep(250_000)
            }
        }
    }

    /// Type text into the terminal as if the user had (used by the Studio MCP's run_in_terminal).
    func type(_ text: String) { view.send(txt: text) }

    /// Type a message into Claude's prompt and press Return. The Return goes a beat later so Claude
    /// doesn't treat it as part of a paste (which would add a newline instead of sending).
    func submit(_ text: String) {
        if let n = native { n.send(text); return }
        guard running else { return }
        // Bracketed paste: Claude takes the whole text as one input, and characters like ! # ? / at the
        // start aren't read as its shortcuts.
        view.pasteText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.view.send(txt: "\r") }
    }

    /// End this tab's process for good: its host session too, if it has one.
    func terminate() {
        if isWeb { webView.stopLoading(); running = false; return }
        if isFile { running = false; return }
        native?.stop()
        if let h = hostName { SessionHost.kill(h) }
        else if running, pid > 0 { kill(pid, SIGHUP) }
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
            if self.switchingToNative, let sid = self.sessionId {
                self.switchingToNative = false
                self.startNative(sid)
            }
        }
    }
}

/// Keeps a web tab's URL and title in sync with its page.
final class WebDelegate: NSObject, WKNavigationDelegate {
    weak var tab: TerminalSession?
    func webView(_ w: WKWebView, didCommit _: WKNavigation!) { tab?.url = w.url }
    func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
        tab?.url = w.url
        tab?.webTitle = w.title ?? ""
    }
}

func shellQuote(_ s: String) -> String {
    if s.range(of: "^[A-Za-z0-9_./=:-]+$", options: .regularExpression) != nil { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

