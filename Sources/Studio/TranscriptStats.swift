import Foundation

/// Reads a file's complete lines from `offset` on, 256 KB at a time into buffers that are reused, so a
/// transcript of hundreds of MB never sits in memory whole and leaves no trail of big freed blocks behind
/// (the allocator keeps those for reuse rather than returning them). Each chunk's parsed objects are freed
/// before the next read. Returns the offset just past the last complete line; a partial last line is left
/// for next time.
func forEachLine(_ fh: FileHandle, from offset: UInt64, _ body: (Data) -> Void) -> UInt64 {
    let fd = fh.fileDescriptor
    var pos = offset
    var fileOffset = off_t(offset)
    var chunk = [UInt8](repeating: 0, count: 256 << 10)
    var pending = Data(capacity: 512 << 10)   // unfinished line + new bytes; grows only to the longest line
    while true {
        let n = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, fileOffset) }
        guard n > 0 else { break }
        fileOffset += off_t(n)
        chunk.withUnsafeBytes { pending.append($0.bindMemory(to: UInt8.self).baseAddress!, count: n) }
        // find line ends with memchr; Data's generic collection methods go byte by byte
        var ends: [Int] = []
        pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var at = 0
            while at < raw.count, let hit = memchr(base + at, 0x0A, raw.count - at) {
                let i = base.distance(to: UnsafeRawPointer(hit))
                ends.append(i)
                at = i + 1
            }
        }
        guard let last = ends.last else { continue }
        autoreleasepool {
            var start = 0
            for e in ends {
                if e > start { body(pending.subdata(in: start..<e)) }
                start = e + 1
            }
        }
        pos += UInt64(last + 1)
        pending.removeSubrange(0..<(last + 1))
    }
    return pos
}

/// Whether `line` contains `tag` (memmem: far faster than Data.range(of:) on every line of a transcript).
func contains(_ line: Data, _ tag: Data) -> Bool {
    line.withUnsafeBytes { l in tag.withUnsafeBytes { t in
        memmem(l.baseAddress, l.count, t.baseAddress, t.count) != nil
    } }
}


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
    private static let assistantTag = Data(#""type":"assistant""#.utf8)
    private static let toolResultTag = Data(#""tool_result""#.utf8)
    fileprivate static let prURL = try! NSRegularExpression(pattern: #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#)
    private var states: [String: State] = [:]

    func stats(for path: String) -> TranscriptStats {
        var st = states[path] ?? State()
        guard let fh = FileHandle(forReadingAtPath: path) else { return st.stats }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < st.offset { st = State() }            // file was rewritten
        guard size > st.offset else { return st.stats }
        st.offset = forEachLine(fh, from: st.offset) { line in
            // Only assistant messages (usage, model, branch, `gh pr create` calls) and the results of
            // those calls matter; skip parsing everything else, which is most of a transcript.
            let assistant = contains(line, Self.assistantTag)
            guard assistant || (!st.prCreateCalls.isEmpty && contains(line, Self.toolResultTag)),
                  let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if let b = o["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { st.stats.gitBranch = b }
            Self.scanPRs(o, &st)
            guard o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
                  let msg = o["message"] as? [String: Any] else { return }
            if let m = msg["model"] as? String, m != "<synthetic>" { st.stats.model = m }
            let id = msg["id"] as? String ?? UUID().uuidString
            guard !st.seen.contains(id), let u = msg["usage"] as? [String: Any] else { return }
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
