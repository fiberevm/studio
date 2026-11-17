import Foundation

/// A Claude Code session discovered from a transcript in ~/.claude/projects.
struct SessionRecord: Identifiable, Hashable {
    let id: String              // sessionId
    var cwd: String
    var title: String?          // custom-title > agent-name > ai-title
    var firstPrompt: String?
    var lastPrompt: String?
    var lastActivity: Date
    var transcriptPath: String

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
    let status: String          // busy | idle | shell | ...
    let entrypoint: String?     // cli | claude-desktop | ...
    let startedAt: Date
    let updatedAt: Date
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
