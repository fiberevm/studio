import Foundation

/// Reads Claude Code transcripts (~/.claude/projects/<dir>/<sessionId>.jsonl) cheaply:
/// only the head and tail of each file are parsed, and results are cached by mtime.
final class TranscriptScanner {
    private var cache: [String: (mtime: Date, record: SessionRecord?)] = [:]
    private let chunk = 256 * 1024

    /// Parses only the transcripts for the given session ids (the ones shown in the sidebar).
    func scan(ids: Set<String>) -> [SessionRecord] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil) else { return [] }
        var out: [SessionRecord] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "jsonl" && ids.contains(f.deletingPathExtension().lastPathComponent) {
                let path = f.path
                seen.insert(path)
                let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard vals?.isRegularFile == true, let mtime = vals?.contentModificationDate else { continue }
                if let c = cache[path], c.mtime == mtime {
                    if let r = c.record { out.append(r) }
                    continue
                }
                let rec = parse(path: path, mtime: mtime)
                cache[path] = (mtime, rec)
                if let r = rec { out.append(r) }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return out
    }

    private func parse(path: String, mtime: Date) -> SessionRecord? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: 0)
        let head = (try? fh.read(upToCount: chunk)) ?? Data()
        var tail = Data()
        if size > UInt64(chunk) {
            let start = max(UInt64(chunk), size - UInt64(chunk))
            try? fh.seek(toOffset: start)
            tail = (try? fh.readToEnd()) ?? Data()
            // drop the (probably partial) first line
            if let nl = tail.firstIndex(of: 0x0A) { tail = tail.subdata(in: tail.index(after: nl)..<tail.endIndex) }
        }

        let sessionId = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var cwd: String?
        var aiTitle: String?, customTitle: String?, agentName: String?
        var firstPrompt: String?, lastPrompt: String?
        var lastTimestamp: Date?

        func visit(_ data: Data, isHead: Bool) {
            for line in data.split(separator: 0x0A) {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let type = obj["type"] as? String
                if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
                switch type {
                case "ai-title": if let t = obj["aiTitle"] as? String, !t.isEmpty { aiTitle = t }
                case "custom-title": if let t = obj["customTitle"] as? String ?? obj["title"] as? String, !t.isEmpty { customTitle = t }
                case "agent-name": if let t = obj["agentName"] as? String, !t.isEmpty { agentName = t }
                case "user":
                    if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true { break }
                    if let text = promptText(obj) {
                        if isHead && firstPrompt == nil { firstPrompt = text }
                        lastPrompt = text
                    }
                default: break
                }
                if let ts = obj["timestamp"] as? String, let d = Self.iso.date(from: ts) { lastTimestamp = d }
            }
        }
        visit(head, isHead: true)
        if !tail.isEmpty { visit(tail, isHead: false) }

        guard let cwd else { return nil }
        // Skip sessions that never had a real prompt (e.g. aborted startups)
        guard firstPrompt != nil || lastPrompt != nil || customTitle != nil || aiTitle != nil else { return nil }
        return SessionRecord(
            id: sessionId, cwd: cwd,
            title: customTitle ?? agentName ?? aiTitle,
            firstPrompt: firstPrompt, lastPrompt: lastPrompt,
            lastActivity: lastTimestamp ?? mtime,
            transcriptPath: path)
    }

    private func promptText(_ obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = msg["content"] as? String { text = s }
        else if let arr = msg["content"] as? [[String: Any]] {
            // tool_result-only messages are not prompts
            text = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
        }
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.hasPrefix("<command-name>") {
            // slash command: show it as "/name args"
            let name = t.between("<command-name>", "</command-name>") ?? ""
            let args = t.between("<command-args>", "</command-args>") ?? ""
            t = (name + " " + args).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        if t.hasPrefix("<") || t.hasPrefix("Caveat:") || t.hasPrefix("[Request interrupted") { return nil }
        let oneLine = t.replacingOccurrences(of: "\n", with: " ")
        return String(oneLine.prefix(200))
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension String {
    func between(_ a: String, _ b: String) -> String? {
        guard let r1 = range(of: a), let r2 = range(of: b, range: r1.upperBound..<endIndex) else { return nil }
        return String(self[r1.upperBound..<r2.lowerBound])
    }
}

/// Reads ~/.claude/sessions/<pid>.json and keeps only processes that are still alive.
enum LiveScanner {
    static func scan() -> [LiveInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.liveSessions, includingPropertiesForKeys: nil) else { return [] }
        var out: [LiveInfo] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value,
                  let sid = o["sessionId"] as? String else { continue }
            guard isAlive(pid) else { continue }
            func date(_ k: String) -> Date {
                Date(timeIntervalSince1970: ((o[k] as? NSNumber)?.doubleValue ?? 0) / 1000)
            }
            out.append(LiveInfo(
                pid: pid, sessionId: sid,
                cwd: o["cwd"] as? String ?? "",
                name: o["name"] as? String,
                status: o["status"] as? String ?? "idle",
                entrypoint: o["entrypoint"] as? String,
                startedAt: date("startedAt"),
                updatedAt: date("statusUpdatedAt")))
        }
        return out
    }

    static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
