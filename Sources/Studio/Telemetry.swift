import Foundation

/// Anonymous usage telemetry (PostHog), on unless you turn it off in Settings → Telemetry or on the welcome
/// window's last page. It counts how Studio is used, never what you do with it: a random install id, the app
/// and macOS versions, and a few events (Studio opened, a session opened and with which agent, and how many
/// tokens its sessions sent and received). No names, paths, prompts, code, output, IP-based location or
/// anything else that could identify you or your work.
enum Telemetry {
    static let pref = "telemetryEnabled"
    private static let token = "phc_q7FYZeELCWZVJo9u5m98p7dqdWnsSHru3i3ZqdSDxVzw"
    private static let endpoint = URL(string: "https://us.i.posthog.com/i/v0/e/")!
    private static let idKey = "telemetryId"

    static var enabled: Bool { UserDefaults.standard.object(forKey: pref) as? Bool ?? true }

    /// Only the real app sends: never a preview copy or a throwaway side-by-side instance.
    private static var sending: Bool {
        enabled && Bundle.main.bundleIdentifier == "dev.local.studio" && !CommandLine.arguments.contains("--no-restore")
    }

    /// A random id for this install, not derived from anything about you or this Mac.
    static var installId: String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    private static var base: [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "build": Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil ? "source" : "release",
            "os_version": "\(os.majorVersion).\(os.minorVersion)",
            "arch": arch,
            "$lib": "studio",
            // anonymous: no person profile, no location from the IP address
            "$process_person_profile": false,
            "$geoip_disable": true,
            "$ip": "",
        ]
    }

    /// Send one event (off the main thread, fire and forget). `props` must never hold names, paths or content.
    /// `wait` blocks up to 3 s for the send to finish (for the last events as Studio quits).
    static func capture(_ event: String, _ props: [String: Any] = [:], wait: Bool = false) {
        guard sending else { return }
        let body: [String: Any] = [
            "api_key": token, "event": event, "distinct_id": installId,
            "properties": base.merging(props) { _, new in new },
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        if wait { _ = done.wait(timeout: .now() + 3) }
    }

    /// A session tab opened: which agent, and how it came to be open. `agent` is "claude", "codex" or "agy".
    static func sessionOpened(agent: String, origin: SessionOrigin, worker: Bool = false, native: Bool = false) {
        capture("session_opened", ["agent": agent, "origin": origin.rawValue, "worker": worker, "native": native])
    }
}

/// How an agent tab came to be open: a new conversation, an old one picked from ⌘P or the sidebar, a copy of
/// one (⌘E), or one Studio reopened at launch.
enum SessionOrigin: String { case new, resume, fork, restore }

/// Studio's north star: the tokens its agent sessions process. Every minute it reads each open agent tab's
/// running totals (the counts its status bar shows: everything sent to the model, cache included, and
/// everything it wrote), adds what is new since the last look, and every 5 minutes sends one
/// `tokens_processed` event per agent with those sums (and once more as Studio quits).
///
/// A conversation's totals are remembered by session id across launches, so nothing is counted twice, and
/// tokens a session processed in tmux while Studio was closed are counted when it reopens. A conversation
/// that was not new when Studio opened it (resumed, forked, or from before this was added) counts from the
/// moment Studio first sees its totals. Sessions on workers keep their counts on the worker and aren't
/// counted; an Antigravity tab is counted only in the native view, the only place agy reports tokens.
@MainActor
final class TokenMeter {
    static let shared = TokenMeter()
    private let key = "telemetryTokenTotals"
    /// session id → [tokens in, tokens out, last seen (seconds since 1970)]
    private var last: [String: [Double]]
    /// Native views count from 0 each time they start, so they are tracked per view, not per conversation.
    private var nativeLast: [ObjectIdentifier: (Int, Int)] = [:]
    private var pending: [String: (inp: Int, out: Int, sessions: Set<String>)] = [:]
    private var timer: Timer?
    private var ticks = 0

    private init() {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        let cutoff = Date().timeIntervalSince1970 - 90 * 86_400   // forget conversations untouched for 90 days
        last = all.filter { $0.value.count == 3 && $0.value[2] > cutoff }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { TokenMeter.shared.tick() }
        }
    }

    /// Add up what every open agent tab processed since the last look; send every fifth time.
    func tick() {
        guard let store = SessionStore.current else { return }
        let now = Date().timeIntervalSince1970
        for t in store.terminals {
            guard let agent = t.agent else { continue }
            if let sid = t.sessionId, let st = store.stats[sid], st.tokensIn + st.tokensOut > 0 {
                let total = (st.tokensIn, st.tokensOut)
                let prev = last[sid].map { (Int($0[0]), Int($0[1])) } ?? (t.countsTokensFromZero ? (0, 0) : total)
                add(agent, sid, total.0 - prev.0, total.1 - prev.1)
                // never step back: a transcript that is re-read from the start must not count again
                last[sid] = [Double(max(prev.0, total.0)), Double(max(prev.1, total.1)), now]
            } else if let n = t.native, n.tokensIn + n.tokensOut > 0 {
                let id = ObjectIdentifier(n), prev = nativeLast[id] ?? (0, 0)
                add(agent, t.id.uuidString, n.tokensIn - prev.0, n.tokensOut - prev.1)
                nativeLast[id] = (max(prev.0, n.tokensIn), max(prev.1, n.tokensOut))
            }
        }
        UserDefaults.standard.set(last, forKey: key)
        ticks += 1
        if ticks % 5 == 0 { flush() }
    }

    /// Send what has added up: one `tokens_processed` event per agent.
    func flush(wait: Bool = false) {
        let batch = pending
        pending = [:]
        for (agent, p) in batch where p.inp + p.out > 0 {
            Telemetry.capture("tokens_processed", ["agent": agent, "tokens_in": p.inp, "tokens_out": p.out,
                                                   "tokens": p.inp + p.out, "sessions": p.sessions.count], wait: wait)
        }
    }

    private func add(_ agent: Agent, _ session: String, _ i: Int, _ o: Int) {
        let i = max(0, i), o = max(0, o)
        guard i + o > 0 else { return }
        var p = pending[agent.rawValue] ?? (0, 0, [])
        p.inp += i; p.out += o; p.sessions.insert(session)
        pending[agent.rawValue] = p
    }
}
