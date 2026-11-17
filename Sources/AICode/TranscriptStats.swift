import Foundation

/// Running totals for a transcript: tokens, latest model and git branch.
struct TranscriptStats: Equatable {
    var tokensIn = 0       // input + cache creation + cache read (everything sent to the model)
    var tokensOut = 0
    var model: String?
    var gitBranch: String?
    /// PRs this session created (from `gh pr create` output), oldest first.
    var prURLs: [String] = []
}

/// Reads transcripts incrementally: remembers how far it got in each file and only parses new lines.
/// Assistant messages are written once per content block with the same id, so usage is counted once per id.
final class StatsReader {
    fileprivate struct State {
        var offset: UInt64 = 0
        var stats = TranscriptStats()
        var seen = Set<String>()
        var prCreateCalls = Set<String>()   // tool_use ids of `gh pr create` commands
    }
    fileprivate static let prURL = try! NSRegularExpression(pattern: #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#)
    private var states: [String: State] = [:]

    func stats(for path: String) -> TranscriptStats {
        var st = states[path] ?? State()
        guard let fh = FileHandle(forReadingAtPath: path) else { return st.stats }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < st.offset { st = State() }            // file was rewritten
        guard size > st.offset else { return st.stats }
        try? fh.seek(toOffset: st.offset)
        let data = (try? fh.readToEnd()) ?? Data()
        // only consume complete lines; a partial last line is re-read next time
        guard let lastNL = data.lastIndex(of: 0x0A) else { return st.stats }
        let complete = data[data.startIndex...lastNL]
        st.offset += UInt64(complete.count)
        for line in complete.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let b = o["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { st.stats.gitBranch = b }
            Self.scanPRs(o, &st)
            guard o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
                  let msg = o["message"] as? [String: Any] else { continue }
            if let m = msg["model"] as? String, m != "<synthetic>" { st.stats.model = m }
            let id = msg["id"] as? String ?? UUID().uuidString
            guard !st.seen.contains(id), let u = msg["usage"] as? [String: Any] else { continue }
            st.seen.insert(id)
            func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
            st.stats.tokensIn += n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
            st.stats.tokensOut += n("output_tokens")
        }
        states[path] = st
        return st.stats
    }
}

extension StatsReader {
    /// Remember `gh pr create` tool calls; pull the PR link out of their results.
    fileprivate static func scanPRs(_ o: [String: Any], _ st: inout State) {
        guard let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
        for b in blocks {
            switch b["type"] as? String {
            case "tool_use":
                if let id = b["id"] as? String, let cmd = (b["input"] as? [String: Any])?["command"] as? String,
                   cmd.contains("gh pr create") {
                    st.prCreateCalls.insert(id)
                }
            case "tool_result":
                guard let id = b["tool_use_id"] as? String, st.prCreateCalls.contains(id) else { continue }
                var text = b["content"] as? String ?? ""
                if let arr = b["content"] as? [[String: Any]] {
                    text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                let ns = text as NSString
                for m in prURL.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let url = ns.substring(with: m.range)
                    if !st.stats.prURLs.contains(url) { st.stats.prURLs.append(url) }
                }
            default: break
            }
        }
    }
}

func formatTokens(_ n: Int) -> String {
    switch n {
    case ..<1000: return "\(n)"
    case ..<1_000_000: return String(format: n < 10_000 ? "%.1fk" : "%.0fk", Double(n) / 1000)
    default: return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}

/// "claude-opus-5-5" → "Opus 5.5"
func prettyModel(_ id: String) -> String {
    let parts = id.split(separator: "-").map(String.init)
    guard parts.first == "claude", parts.count >= 2 else { return id }
    let name = parts[1].capitalized
    let nums = parts.dropFirst(2).filter { Int($0) != nil && $0.count <= 2 }
    return nums.isEmpty ? name : "\(name) \(nums.joined(separator: "."))"
}

func formatDuration(_ s: TimeInterval) -> String {
    let m = Int(s / 60)
    if m < 1 { return "<1m" }
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 24 { return "\(h)h \(m % 60)m" }
    return "\(h / 24)d \(h % 24)h"
}
