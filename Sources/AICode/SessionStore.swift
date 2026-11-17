import AppKit
import Combine
import UserNotifications

/// One row in the "Active" section: an in-app terminal and/or a live claude process.
struct ActiveItem: Identifiable, Hashable {
    let key: String
    let sessionId: String?
    let title: String
    let cwd: String
    let status: SessionStatus
    let inApp: Bool
    let entrypoint: String?
    let pid: Int32?
    let startedAt: Date
    let updatedAt: Date
    var id: String { key }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var records: [String: SessionRecord] = [:]
    @Published private(set) var live: [String: LiveInfo] = [:]       // by sessionId
    @Published private(set) var terminals: [TerminalSession] = []
    @Published var selection: String? { didSet { selectionChanged() } }
    @Published private(set) var attention: Set<String> = []          // session ids that finished while unviewed
    @Published var fontSize: CGFloat = UserDefaults.standard.object(forKey: "fontSize") as? CGFloat ?? 12 {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            terminals.forEach { $0.setFontSize(fontSize) }
        }
    }

    private let scanner = TranscriptScanner()
    private let scanQueue = DispatchQueue(label: "aicode.scan", qos: .utility)
    private var liveTimer: Timer?
    private var scanTimer: Timer?
    private var lastStatus: [String: String] = [:]
    private var bag: Set<AnyCancellable> = []

    init() {
        refreshLive()
        rescanTranscripts()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescanTranscripts() }
        }
        if Self.canNotify {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    // MARK: Scanning

    func rescanTranscripts() {
        let ids = Set(live.keys).union(terminals.compactMap(\.sessionId))
        scanQueue.async { [scanner] in
            let recs = scanner.scan(ids: ids)
            let dict = Dictionary(recs.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.lastActivity > b.lastActivity ? a : b })
            DispatchQueue.main.async {
                if self.records != dict { self.records = dict }
            }
        }
    }

    func refreshLive() {
        let infos = LiveScanner.scan()
        var byPid: [Int32: LiveInfo] = [:]
        var bySid: [String: LiveInfo] = [:]
        for i in infos {
            byPid[i.pid] = i
            if let existing = bySid[i.sessionId], existing.updatedAt > i.updatedAt { continue }
            bySid[i.sessionId] = i
        }

        // Map in-app terminals to their claude session via pid. Handles /clear and /resume inside the session too.
        for t in terminals where t.running {
            if let info = byPid[t.pid], t.sessionId != info.sessionId {
                let old = t.sessionId
                t.sessionId = info.sessionId
                persistTerminals()
                if selection == "t:\(t.id)" || (old != nil && selection == "s:\(old!)") {
                    selection = "s:\(info.sessionId)"
                }
            }
        }

        // Detect "finished working" transitions for the attention badge.
        let selectedSid = selectedSessionId
        for (sid, info) in bySid {
            let prev = lastStatus[sid]
            if prev == "busy" && info.status != "busy" && sid != selectedSid {
                attention.insert(sid)
                notifyFinished(sid: sid, info: info)
            }
            lastStatus[sid] = info.status
        }
        if live != bySid { live = bySid }
        updateDockBadge()
    }

    // MARK: Derived lists

    var activeItems: [ActiveItem] {
        var items: [ActiveItem] = []
        var covered = Set<String>()
        for t in terminals {
            let sid = t.sessionId
            if let sid { covered.insert(sid) }
            let info = sid.flatMap { live[$0] }
            let rec = sid.flatMap { records[$0] }
            let status: SessionStatus = !t.running ? .exited : (info.map { SessionStatus(raw: $0.status) } ?? .starting)
            items.append(ActiveItem(
                key: sid.map { "s:\($0)" } ?? "t:\(t.id)",
                sessionId: sid,
                title: title(rec: rec, info: info, fallback: "New session"),
                cwd: info?.cwd ?? rec?.cwd ?? t.cwd,
                status: status, inApp: true, entrypoint: "aicode", pid: t.pid,
                startedAt: t.createdAt, updatedAt: info?.updatedAt ?? t.createdAt))
        }
        for (sid, info) in live where !covered.contains(sid) {
            let rec = records[sid]
            items.append(ActiveItem(
                key: "s:\(sid)", sessionId: sid,
                title: title(rec: rec, info: info, fallback: "New session"),
                cwd: info.cwd, status: SessionStatus(raw: info.status), inApp: false,
                entrypoint: info.entrypoint, pid: info.pid,
                startedAt: info.startedAt, updatedAt: info.updatedAt))
        }
        return items.sorted { $0.startedAt > $1.startedAt }
    }

    private func title(rec: SessionRecord?, info: LiveInfo?, fallback: String) -> String {
        if let t = rec?.title, !t.isEmpty { return t }
        if let n = info?.name, !n.isEmpty { return n }
        if let p = rec?.firstPrompt { return p }
        return fallback
    }

    // MARK: Selection

    var selectedSessionId: String? {
        guard let sel = selection else { return nil }
        if sel.hasPrefix("s:") { return String(sel.dropFirst(2)) }
        if sel.hasPrefix("t:") { return terminals.first { "t:\($0.id)" == sel }?.sessionId }
        return nil
    }

    var selectedTerminal: TerminalSession? {
        guard let sel = selection else { return nil }
        if sel.hasPrefix("t:") { return terminals.first { "t:\($0.id)" == sel } }
        let sid = String(sel.dropFirst(2))
        return terminals.first { $0.sessionId == sid }
    }

    private func selectionChanged() {
        if let sid = selectedSessionId, attention.contains(sid) {
            attention.remove(sid)
            updateDockBadge()
        }
    }

    // MARK: Actions

    /// `AICode --new <dir>` starts a session in dir; `AICode --resume <sessionId>` resumes one.
    func handleLaunchArguments() {
        let args = CommandLine.arguments
        if !args.contains("--no-restore") { restoreTerminals() }
        if let i = args.firstIndex(of: "--new"), i + 1 < args.count { newSession(in: args[i + 1]) }
        if let i = args.firstIndex(of: "--resume"), i + 1 < args.count { resume(args[i + 1]) }
    }

    /// Terminals opened in the app are remembered so quitting/relaunching brings them back.
    private func persistTerminals() {
        let saved = terminals.compactMap { t in t.sessionId.map { ["sid": $0, "cwd": t.cwd] } }
        UserDefaults.standard.set(saved, forKey: "openTerminals")
    }

    private func restoreTerminals() {
        guard let saved = UserDefaults.standard.array(forKey: "openTerminals") as? [[String: String]] else { return }
        refreshLive()
        for e in saved {
            guard let sid = e["sid"], let cwd = e["cwd"], live[sid] == nil else { continue } // skip if running elsewhere
            open(TerminalSession(cwd: cwd, claudeArgs: ["--resume", sid], sessionId: sid, fontSize: fontSize))
        }
        if selection == nil, let first = terminals.first { selection = first.sessionId.map { "s:\($0)" } }
    }

    private func open(_ t: TerminalSession) {
        terminals.append(t)
        observe(t)
        persistTerminals()
    }

    func resume(_ sid: String) {
        if terminals.contains(where: { $0.sessionId == sid }) { selection = "s:\(sid)"; return }
        let cwd = records[sid]?.cwd ?? live[sid]?.cwd ?? NSHomeDirectory()
        open(TerminalSession(cwd: cwd, claudeArgs: ["--resume", sid], sessionId: sid, fontSize: fontSize))
        selection = "s:\(sid)"
    }

    func newSession(in cwd: String) {
        let t = TerminalSession(cwd: cwd, claudeArgs: [], sessionId: nil, fontSize: fontSize)
        open(t)
        selection = "t:\(t.id)"
    }

    func newSessionPickingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Claude Here"
        if let cwd = selectedTerminal?.cwd ?? selectedSessionId.flatMap({ records[$0]?.cwd ?? live[$0]?.cwd }) {
            panel.directoryURL = URL(fileURLWithPath: cwd)
        }
        if panel.runModal() == .OK, let url = panel.url { newSession(in: url.path) }
    }

    func close(_ t: TerminalSession) {
        t.terminate()
        terminals.removeAll { $0 === t }
        persistTerminals()
        if selection == "t:\(t.id)" { selection = nil }
    }

    func closeSelected() {
        if let t = selectedTerminal { close(t) }
    }

    /// Kill an externally running claude process (sends SIGHUP like closing its terminal would).
    func stopExternal(pid: Int32) {
        kill(pid, SIGHUP)
    }

    func revealTranscript(_ sid: String) {
        guard let p = records[sid]?.transcriptPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    // Re-render the sidebar when a terminal's own state changes (running/exited, sessionId).
    private func observe(_ t: TerminalSession) {
        t.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    private func updateDockBadge() {
        NSApp?.dockTile.badgeLabel = attention.isEmpty ? nil : "\(attention.count)"
    }

    /// UNUserNotificationCenter crashes when not running from an .app bundle.
    static let canNotify = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")

    private func notifyFinished(sid: String, info: LiveInfo) {
        guard Self.canNotify, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title(rec: records[sid], info: info, fallback: "Claude")
        content.body = info.status == "idle" ? "Finished — ready for you" : "Status: \(info.status)"
        content.sound = .default
        let req = UNNotificationRequest(identifier: sid, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
