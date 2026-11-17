import Foundation

struct PRInfo: Equatable, Identifiable {
    enum State: String { case open, draft, merged, closed }
    enum Checks { case none, pending, passing, failing }

    let number: Int
    let title: String
    let url: String
    let state: State
    let checks: Checks
    let review: String?        // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED
    var id: String { url }
}

/// Looks up PRs for sessions with the GitHub CLI.
/// PRs a session created (found in its transcript) win; otherwise its branch is looked up,
/// skipping long-lived branches that would match unrelated release PRs.
final class PRMonitor {
    private let queue = DispatchQueue(label: "studio.pr", qos: .utility)
    private var lastFetch: [String: Date] = [:]          // request key → time
    private var cache: [String: [PRInfo]] = [:]          // request key → result
    private let refreshInterval: TimeInterval = 60

    static let longLivedBranches: Set<String> = ["main", "master", "staging", "develop", "development", "dev",
                                                 "production", "prod", "release", "trunk", "HEAD"]

    static let ghPath: String? = {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    struct Request {
        let sessionId: String
        let cwd: String
        let prURLs: [String]
        let branch: String?
        var key: String { prURLs.isEmpty ? "branch:\(cwd):\(branch ?? "")" : "urls:" + prURLs.joined(separator: ",") }
    }

    private var inFlight = false   // touched only on `queue`

    /// Fetch (at most once a minute per request). Each session's result is reported on the main queue as soon as
    /// it's ready, so one slow `gh` call never holds back the others. Overlapping passes are skipped.
    func refresh(_ requests: [Request], force: Bool = false, onResult: @escaping (String, [PRInfo]) -> Void) {
        guard Self.ghPath != nil else { return }
        queue.async {
            guard !self.inFlight else { return }
            self.inFlight = true
            defer { self.inFlight = false }
            for r in requests {
                let key = r.key
                let stale = force || (self.lastFetch[key].map { -$0.timeIntervalSinceNow > self.refreshInterval } ?? true)
                if stale {
                    self.cache[key] = self.fetch(r)
                    self.lastFetch[key] = Date()
                }
                let result = self.cache[key] ?? []
                DispatchQueue.main.async { onResult(r.sessionId, result) }
            }
        }
    }

    private static let fields = "number,title,url,state,isDraft,statusCheckRollup,reviewDecision"

    private func fetch(_ r: Request) -> [PRInfo] {
        let result = fetchUnlogged(r)
        debugLog("PR fetch \(r.sessionId.prefix(8)) urls=\(r.prURLs) branch=\(r.branch ?? "-") → \(result.map(\.number))")
        return result
    }

    private func fetchUnlogged(_ r: Request) -> [PRInfo] {
        if !r.prURLs.isEmpty {
            return r.prURLs.compactMap { url in
                gh(["pr", "view", url, "--json", Self.fields], cwd: r.cwd).flatMap { parse($0 as? [String: Any]) }
            }
        }
        guard let b = r.branch, !Self.longLivedBranches.contains(b) else { return [] }
        let list = gh(["pr", "list", "--head", b, "--state", "all", "--limit", "1", "--json", Self.fields], cwd: r.cwd)
        return (list as? [[String: Any]] ?? []).compactMap(parse)
    }

    private func parse(_ o: [String: Any]?) -> PRInfo? {
        guard let o, let n = o["number"] as? Int, let url = o["url"] as? String else { return nil }
        let raw = (o["state"] as? String ?? "").uppercased()
        let state: PRInfo.State = raw == "MERGED" ? .merged : raw == "CLOSED" ? .closed
            : (o["isDraft"] as? Bool == true ? .draft : .open)
        return PRInfo(number: n, title: o["title"] as? String ?? "", url: url, state: state,
                      checks: Self.checks(o["statusCheckRollup"] as? [[String: Any]] ?? []),
                      review: (o["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func checks(_ rollup: [[String: Any]]) -> PRInfo.Checks {
        guard !rollup.isEmpty else { return .none }
        var pending = false
        for c in rollup {
            let conclusion = (c["conclusion"] as? String ?? "").uppercased()
            let status = (c["status"] as? String ?? "").uppercased()
            let state = (c["state"] as? String ?? "").uppercased()   // legacy commit statuses
            if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion)
                || ["FAILURE", "ERROR"].contains(state) { return .failing }
            if (!status.isEmpty && status != "COMPLETED") || ["PENDING", "EXPECTED"].contains(state) { pending = true }
        }
        return pending ? .pending : .passing
    }

    /// Runs `gh` and parses its JSON output; nil on any failure. Times out after 8s.
    private func gh(_ args: [String], cwd: String) -> Any? {
        guard let path = Self.ghPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if FileManager.default.fileExists(atPath: cwd) { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // kill a hung gh (network, auth prompt) so the queue never stalls
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // returns when gh exits
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// Set STUDIO_DEBUG_LOG=/path/to/file to trace background lookups.
func debugLog(_ msg: String) {
    guard let path = ProcessInfo.processInfo.environment["STUDIO_DEBUG_LOG"] else { return }
    let line = "\(Date()) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}
