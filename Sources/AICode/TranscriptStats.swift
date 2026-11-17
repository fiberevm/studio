import Foundation

/// Running totals for a transcript: tokens, latest model and git branch.
struct TranscriptStats: Equatable {
    var tokensIn = 0       // input + cache creation + cache read (everything sent to the model)
    var tokensOut = 0
    var model: String?
    var gitBranch: String?
}

/// Reads transcripts incrementally: remembers how far it got in each file and only parses new lines.
/// Assistant messages are written once per content block with the same id, so usage is counted once per id.
final class StatsReader {
    private struct State { var offset: UInt64 = 0; var stats = TranscriptStats(); var seen = Set<String>() }
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
