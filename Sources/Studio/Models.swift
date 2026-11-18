import Foundation

/// A Claude Code session discovered from a transcript in ~/.claude/projects.
struct SessionRecord: Identifiable, Hashable, Equatable {
    let id: String              // sessionId
    var cwd: String
    var title: String?          // custom-title > agent-name > ai-title
    var firstPrompt: String?
    var lastPrompt: String?
    var lastReply: String?      // Claude's last text message, for the tab peek
    var activity: Activity?     // what the transcript's last entry says Claude is doing
    var lastActivity: Date
    var transcriptPath: String
    var agent: Agent = .claude

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let p = firstPrompt, !p.isEmpty { return p }
        return "Untitled session"
    }
}

/// Live state of a running `claude` process, from ~/.claude/sessions/<pid>.json.
struct LiveInfo: Hashable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String          // busy | idle | shell | waiting
    let waitingFor: String?     // when waiting: what for, e.g. "permission" or "input needed"
    let entrypoint: String?     // cli | claude-desktop | ...
    let startedAt: Date
    let updatedAt: Date
}

/// What a working session is doing right now, shown as its tab icon.
enum Activity: Hashable {
    case thinking
    case writing
    case tool(String)

    /// SF Symbol for the activity.
    var symbol: String {
        switch self {
        case .thinking: return "sparkles"
        case .writing: return "text.cursor"
        case .tool(let name):
            if name.hasPrefix("mcp__") { return "powerplug" }
            switch name {
            case "Bash", "BashOutput", "KillShell", "Monitor",
                 "shell", "exec", "exec_command", "write_stdin", "local_shell": return "terminal"   // Codex's too
            case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch": return "pencil"
            case "Read", "NotebookRead": return "doc.text"
            case "Grep", "Glob", "LSP": return "magnifyingglass"
            case "WebFetch", "WebSearch", "web_search": return "globe"
            case "Task", "Agent": return "person.2"
            case "TodoWrite": return "checklist"
            default: return "wrench.and.screwdriver"
            }
        }
    }

    var label: String {
        switch self {
        case .thinking: return "Thinking"
        case .writing: return "Writing"
        case .tool(let n): return n.hasPrefix("mcp__") ? "Using " + (n.split(separator: "_").last.map(String.init) ?? n) : "Running \(n)"
        }
    }
}

enum SessionStatus: Hashable {
    case working, idle, shell, waiting, starting, exited, inactive, other(String)

    init(raw: String) {
        switch raw {
        case "busy": self = .working
        case "idle": self = .idle
        case "shell": self = .shell
        case "waiting", "needs_input", "permission", "requires_action": self = .waiting
        default: self = .other(raw)
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .idle: return "Idle"
        case .shell: return "Shell"
        case .waiting: return "Needs input"
        case .starting: return "Starting"
        case .exited: return "Exited"
        case .inactive: return "Inactive"
        case .other(let s): return s.capitalized
        }
    }
}

enum Paths {
    static let claudeHome: URL = {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }()
    static var projects: URL { claudeHome.appendingPathComponent("projects") }
    static var liveSessions: URL { claudeHome.appendingPathComponent("sessions") }
}

/// Friendly name for a working directory, e.g. "omni" or "fiber-infrastructure ⎇ audit".
func projectName(for cwd: String) -> String {
    if let r = cwd.range(of: "/.claude/worktrees/") {
        let repo = (String(cwd[..<r.lowerBound]) as NSString).lastPathComponent
        let wt = String(cwd[r.upperBound...]).split(separator: "/").first.map(String.init) ?? ""
        return "\(repo) ⎇ \(wt)"
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if cwd == home { return "~" }
    return (cwd as NSString).lastPathComponent
}

func abbreviatePath(_ p: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

func relativeTime(_ d: Date) -> String {
    let s = -d.timeIntervalSinceNow
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    if s < 86400 * 30 { return "\(Int(s / 86400))d" }
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f.string(from: d)
}

/// True when `path` is `folder` or somewhere beneath it.
func isInside(_ path: String, _ folder: String) -> Bool {
    let f = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
    return path == f || path.hasPrefix(f + "/")
}

/// The repo a session belongs to: worktrees under <repo>/.claude/worktrees/ fold into <repo>.
func projectRoot(_ cwd: String) -> String {
    if let r = cwd.range(of: "/.claude/worktrees/") { return String(cwd[..<r.lowerBound]) }
    return cwd
}

enum RecentProjects {
    static func list() -> [String] { UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [] }
    static func add(_ folder: String) {
        var l = list().filter { $0 != folder }
        l.insert(folder, at: 0)
        UserDefaults.standard.set(Array(l.prefix(12)), forKey: "recentProjects")
    }
}
