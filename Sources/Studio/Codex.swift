import Foundation

/// Codex CLI's equivalents of Claude Code's transcripts: one rollout per conversation at
/// ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl, plus thread names in session_index.jsonl.
/// Resuming a conversation appends to its rollout, so a session id maps to one file for good.
enum CodexPaths {
    static let home: URL = {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }()
    static var sessions: URL { home.appendingPathComponent("sessions") }
    static var index: URL { home.appendingPathComponent("session_index.jsonl") }
}

/// What a Codex rollout says about its session right now.
struct CodexSession: Equatable {
    var record: SessionRecord
    var stats = TranscriptStats()
    var busy = false          // a turn started and hasn't completed
    var startedAt: Date
}

/// Reads Codex rollouts incrementally (only new lines each time), like StatsReader does for Claude.
/// Not thread-safe: use it from one queue.
final class CodexScanner {
    private struct Meta { let id: String; let cwd: String; let startedAt: Date }
    private struct FileState { var offset: UInt64 = 0; var session: CodexSession }

    private var metas: [String: Meta] = [:]          // by rollout path
    private var pathById: [String: String] = [:]
    private var files: [String: FileState] = [:]      // by rollout path
    private var names: [String: String] = [:]         // thread names, by id
    private var indexSize: UInt64 = 0
    private var lastFullWalk = Date.distantPast

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: Discovery

    /// Find rollouts: today's and yesterday's folders every call, the whole tree every 30s.
    private func refreshPaths() {
        let fm = FileManager.default
        var dirs: [URL] = []
        if Date().timeIntervalSince(lastFullWalk) > 30 {
            lastFullWalk = Date()
            dirs = [CodexPaths.sessions]
        } else {
            let cal = Calendar.current
            for back in 0...1 {
                guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
                let c = cal.dateComponents([.year, .month, .day], from: d)
                dirs.append(CodexPaths.sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!)))
            }
        }
        for dir in dirs {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                let p = url.path
                guard metas[p] == nil, let m = Self.readMeta(p) else { continue }
                metas[p] = m
                pathById[m.id] = p
            }
        }
    }

    /// The rollout's first line (session_meta): id, folder and start time.
    private static func readMeta(_ path: String) -> Meta? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var data = Data()
        while data.count < 4_000_000, let chunk = try? fh.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if let nl = data.firstIndex(of: 0x0A) { data = data[data.startIndex..<nl]; break }
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["type"] as? String == "session_meta", let p = o["payload"] as? [String: Any],
              let id = p["id"] as? String, let cwd = p["cwd"] as? String else { return nil }
        return Meta(id: id, cwd: cwd, startedAt: date(p["timestamp"]) ?? date(o["timestamp"]) ?? Date())
    }

    private func refreshNames() {
        let path = CodexPaths.index.path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size != indexSize, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        indexSize = size
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = o["id"] as? String, let n = o["thread_name"] as? String, !n.isEmpty else { continue }
            names[id] = n   // later lines are renames
        }
    }

    // MARK: Queries

    func exists(_ id: String) -> Bool {
        if pathById[id] == nil { refreshPaths() }
        return pathById[id] != nil
    }

    /// The conversation a tab started in `cwd` at `since` is running, if Codex has written it yet:
    /// the earliest rollout begun there since then that no other tab has claimed.
    func started(in cwd: String, since: Date, excluding: Set<String>) -> String? {
        refreshPaths()
        let want = Self.canonical(cwd)
        return metas.values
            .filter { $0.startedAt >= since.addingTimeInterval(-3) && !excluding.contains($0.id) && Self.canonical($0.cwd) == want }
            .min { $0.startedAt < $1.startedAt }?.id
    }

    /// Current state of these sessions.
    func scan(ids: Set<String>) -> [String: CodexSession] {
        refreshPaths()
        refreshNames()
        var out: [String: CodexSession] = [:]
        for id in ids {
            guard let p = pathById[id], let m = metas[p] else { continue }
            var s = read(p, meta: m)
            if let n = names[id] { s.record.title = n }
            out[id] = s
        }
        return out
    }

    /// Every Codex conversation on disk, for ⌘P history. Reads each file once, then only what's new.
    func all() -> [SessionRecord] {
        lastFullWalk = .distantPast
        refreshPaths()
        refreshNames()
        return metas.map { p, m in
            var r = read(p, meta: m).record
            if let n = names[m.id] { r.title = n }
            return r
        }
    }

    private static func canonical(_ p: String) -> String {
        let r = (p as NSString).resolvingSymlinksInPath
        return r.hasPrefix("/private/") ? String(r.dropFirst(8)) : r
    }

    // MARK: Parsing

    private func read(_ path: String, meta m: Meta) -> CodexSession {
        var st = files[path] ?? FileState(session: CodexSession(
            record: SessionRecord(id: m.id, cwd: m.cwd, lastActivity: m.startedAt, transcriptPath: path, agent: .codex),
            startedAt: m.startedAt))
        guard let fh = FileHandle(forReadingAtPath: path) else { return st.session }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > st.offset else { return st.session }
        st.offset = forEachLine(fh, from: st.offset) { line in
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            Self.apply(o, to: &st.session)
        }
        files[path] = st
        return st.session
    }

    private static func apply(_ o: [String: Any], to s: inout CodexSession) {
        let p = o["payload"] as? [String: Any] ?? [:]
        if let d = date(o["timestamp"]) { s.record.lastActivity = max(s.record.lastActivity, d) }
        switch (o["type"] as? String, p["type"] as? String) {
        case ("session_meta", _):
            if let b = (p["git"] as? [String: Any])?["branch"] as? String, !b.isEmpty { s.stats.gitBranch = b }
        case ("turn_context", _):
            if let m = p["model"] as? String { s.stats.model = m }
        case ("event_msg", "thread_settings_applied"):
            if let m = (p["thread_settings"] as? [String: Any])?["model"] as? String { s.stats.model = m }
        case ("event_msg", "task_started"):
            s.busy = true
            s.record.activity = .thinking
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            s.busy = false
            s.record.activity = nil
            if let r = p["last_agent_message"] as? String, !r.isEmpty { s.record.lastReply = r }
        case ("event_msg", "item_completed"):
            guard let item = p["item"] as? [String: Any], item["type"] as? String == "UserMessage" else { break }
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { break }
            if s.record.firstPrompt == nil { s.record.firstPrompt = String(text.prefix(200)) }
            s.record.lastPrompt = String(text.prefix(200))
        case ("event_msg", "token_count"):
            guard let u = (p["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] else { break }
            s.stats.tokensIn = (u["input_tokens"] as? NSNumber)?.intValue ?? s.stats.tokensIn
            s.stats.tokensOut = ((u["output_tokens"] as? NSNumber)?.intValue ?? 0) + ((u["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0)
        case ("response_item", "reasoning"):
            if s.busy { s.record.activity = .thinking }
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
            if s.busy { s.record.activity = .tool(p["name"] as? String ?? "shell") }
        case ("response_item", "message"):
            if s.busy, p["role"] as? String == "assistant" { s.record.activity = .writing }
        default: break
        }
    }

    // MARK: Approvals

    /// Codex doesn't record pending approvals in its rollout, so read them off the screen: its approval
    /// prompts always ask "Would you like to …?" above "Yes, …" / "No, …" choices.
    static func isAskingApproval(_ screen: String) -> Bool {
        guard let r = screen.range(of: "Would you like to ", options: .backwards) else { return false }
        let tail = screen[r.lowerBound...]
        return tail.contains("Yes, ") && (tail.contains("No, ") || tail.contains("esc"))
    }
}
