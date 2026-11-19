import AppKit

/// Whether each agent CLI is installed and logged in, checked through the user's login shell (so PATH and
/// credentials resolve as in Terminal). Runs off the main thread, only when Settings asks.
@MainActor
final class AgentChecker: ObservableObject {
    static let shared = AgentChecker()

    struct Status: Equatable {
        var checking = true
        var path: String?          // nil once checked: not on PATH
        var version: String?
        var loggedIn: Bool?        // nil: couldn't tell
        var account: String?       // how it's signed in, e.g. "claude.ai", "ChatGPT"
        var studioTools: Bool?     // agy: whether Studio's plugin (tools + skills) is installed
    }

    @Published private(set) var status: [Agent: Status] = [:]

    func refresh() {
        for a in Agent.allCases {
            status[a] = Status()
            Task.detached(priority: .utility) {
                let s = Self.check(a)
                await MainActor.run { self.status[a] = s }
            }
        }
    }

    /// What signs you in, run in a terminal tab (all three are interactive).
    static func loginCommand(_ a: Agent) -> String {
        switch a {
        case .claude: return "claude auth login"
        case .codex: return "codex login"
        case .agy: return "agy"   // asks you to sign in on first start
        }
    }

    static func installHint(_ a: Agent) -> String {
        switch a {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: return "npm install -g @openai/codex"
        case .agy: return "Install the Antigravity CLI from antigravity.google"
        }
    }

    nonisolated static func check(_ a: Agent) -> Status {
        var s = Status(checking: false)
        let cmd = a.command
        let which = run("command -v \(cmd)")
        guard which.code == 0, let path = which.out.split(separator: "\n").first.map(String.init), !path.isEmpty else { return s }
        s.path = path
        s.version = run("\(cmd) --version").out.split(separator: "\n").first
            .map { String($0).replacingOccurrences(of: " (Claude Code)", with: "") }
        switch a {
        case .claude:
            let r = run("claude auth status --json")
            if let d = r.out.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                s.loggedIn = o["loggedIn"] as? Bool
                s.account = o["authMethod"] as? String
            }
        case .codex:
            let r = run("codex login status 2>&1")   // it reports on stderr
            let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            s.loggedIn = r.code == 0 && out.localizedCaseInsensitiveContains("logged in") && !out.localizedCaseInsensitiveContains("not logged in")
            if s.loggedIn == true, let r = out.range(of: "using ", options: .caseInsensitive) { s.account = String(out[r.upperBound...]) }
        case .agy:
            // no status command: listing models needs a signed-in account (it asks Google's servers)
            let r = run("agy models", timeout: 20)
            s.loggedIn = r.code == 0 && r.out.contains("\t")
            s.studioTools = AgyPlugin.isInstalled()
        }
        return s
    }

    /// Run a command through the login shell; gives up after `timeout` seconds.
    nonisolated static func run(_ script: String, timeout: Double = 10) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-c", script]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: k) }
        p.environment = env
        guard (try? p.run()) != nil else { return (-1, "") }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
