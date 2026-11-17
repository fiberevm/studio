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
    @Published private(set) var attention: Set<String> = []          // session ids that finished while unviewed
    @Published var fontSize: CGFloat = UserDefaults.standard.object(forKey: "fontSize") as? CGFloat ?? 12 {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            terminals.forEach { $0.setFontSize(fontSize) }
        }
    }

    @Published private(set) var stats: [String: TranscriptStats] = [:]   // by sessionId
    /// Every past session on disk, loaded lazily for the command palette.
    @Published private(set) var history: [SessionRecord] = []
    /// Session to focus when a project window next looks (folder → session id). Used by the palette.
    private(set) var pendingFocus: [String: String] = [:]

    private let scanner = TranscriptScanner()
    private let historyScanner = TranscriptScanner()
    private let statsReader = StatsReader()
    private let scanQueue = DispatchQueue(label: "aicode.scan", qos: .utility)
    private var liveTimer: Timer?
    private var scanTimer: Timer?
    private var lastStatus: [String: String] = [:]
    /// Session currently shown in each window (window id → session id); used for the attention badge.
    private var viewing: [UUID: String] = [:]
    /// Project folders whose saved terminals have been restored into a window.
    private var restoredFolders: Set<String> = []
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
        scanQueue.async { [scanner, statsReader] in
            let recs = scanner.scan(ids: ids)
            let dict = Dictionary(recs.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.lastActivity > b.lastActivity ? a : b })
            var st: [String: TranscriptStats] = [:]
            for r in dict.values { st[r.id] = statsReader.stats(for: r.transcriptPath) }
            DispatchQueue.main.async {
                if self.records != dict { self.records = dict }
                if self.stats != st { self.stats = st }
            }
        }
    }

    func loadHistory() {
        scanQueue.async { [historyScanner] in
            let all = historyScanner.scan(ids: nil).sorted { $0.lastActivity > $1.lastActivity }
            DispatchQueue.main.async { self.history = all }
        }
    }

    // MARK: Theme

    func setTheme(_ t: AppTheme, persist: Bool = true) {
        Theme.current = t
        for term in terminals { Theme.apply(to: term.view, fontSize: fontSize) }
        if persist { UserDefaults.standard.set(t.id, forKey: "theme") }
        objectWillChange.send()
    }

    // MARK: Cross-window focus

    func requestFocus(sessionId: String, in folder: String) {
        pendingFocus[folder] = sessionId
        objectWillChange.send()
    }

    func takePendingFocus(for folder: String) -> String? {
        pendingFocus.removeValue(forKey: folder)
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
                if let previous = t.sessionId { forgotten.insert(previous) }   // e.g. after /clear
                t.sessionId = info.sessionId
                persistTerminals()
            }
        }

        // Detect "finished working" transitions for the attention badge.
        let viewed = Set(viewing.values)
        for (sid, info) in bySid {
            let prev = lastStatus[sid]
            if prev == "busy" && info.status != "busy" && !(viewed.contains(sid) && NSApp.isActive) {
                attention.insert(sid)
                notifyFinished(sid: sid, info: info)
            }
            lastStatus[sid] = info.status
        }
        if live != bySid { live = bySid }
        updateDockBadge()
    }

    // MARK: Derived lists

    func activeItems(in folder: String) -> [ActiveItem] {
        allActiveItems.filter { isInside($0.cwd, folder) }
    }

    func terminals(in folder: String) -> [TerminalSession] {
        terminals.filter { isInside($0.cwd, folder) }
    }

    var allActiveItems: [ActiveItem] {
        var items: [ActiveItem] = []
        var covered = Set<String>()
        for t in terminals {
            let sid = t.sessionId
            if let sid { covered.insert(sid) }
            let info = sid.flatMap { live[$0] }
            let rec = sid.flatMap { records[$0] }
            let status: SessionStatus = !t.running ? .exited : (info.map { SessionStatus(raw: $0.status) } ?? .starting)
            items.append(ActiveItem(
                key: "t:\(t.id)",
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

    func title(rec: SessionRecord?, info: LiveInfo?, fallback: String) -> String {
        if let t = rec?.title, !t.isEmpty { return t }
        if let n = info?.name, !n.isEmpty { return n }
        if let p = rec?.firstPrompt { return p }
        return fallback
    }

    // MARK: Viewing

    func setViewing(window: UUID, sessionId: String?) {
        viewing[window] = sessionId
        if let sid = sessionId, attention.contains(sid) {
            attention.remove(sid)
            updateDockBadge()
        }
    }

    func endViewing(window: UUID) { viewing.removeValue(forKey: window) }

    // MARK: Actions

    /// Terminals opened in the app are remembered so quitting/relaunching brings them back.
    /// Merge, don't overwrite: entries this instance doesn't know about (another window's project,
    /// another AICode instance) are kept; only sessions this instance ended are dropped.
    private var forgotten: Set<String> = []

    private func persistTerminals() {
        // A --no-restore instance is a throwaway side-by-side copy: never touch the saved tab list.
        guard !CommandLine.arguments.contains("--no-restore") else { return }
        let current = terminals.compactMap { t in t.sessionId.map { ["sid": $0, "cwd": t.cwd] } }
        let currentIds = Set(current.compactMap { $0["sid"] })
        let kept = savedTerminals().filter { e in
            guard let sid = e["sid"] else { return false }
            return !currentIds.contains(sid) && !forgotten.contains(sid)
        }
        UserDefaults.standard.set(kept + current, forKey: "openTerminals")
    }

    /// Project roots that have saved tabs not yet restored into a window.
    var savedProjectFolders: [String] {
        var seen: [String] = []
        for e in savedTerminals() {
            guard let cwd = e["cwd"] else { continue }
            let root = projectRoot(cwd)
            if !seen.contains(root) && !restoredFolders.contains(root) { seen.append(root) }
        }
        return seen
    }

    private func savedTerminals() -> [[String: String]] {
        UserDefaults.standard.array(forKey: "openTerminals") as? [[String: String]] ?? []
    }

    /// Reopen terminals that were open in this project when the app last quit. Returns them in order.
    @discardableResult
    func restoreTerminals(in folder: String) -> [TerminalSession] {
        guard !restoredFolders.contains(folder) else { return [] }
        restoredFolders.insert(folder)
        guard !CommandLine.arguments.contains("--no-restore") else { return [] }
        refreshLive()
        var out: [TerminalSession] = []
        for e in savedTerminals() {
            guard let sid = e["sid"], let cwd = e["cwd"], isInside(cwd, folder),
                  live[sid] == nil,                                   // running elsewhere → leave it
                  !terminals.contains(where: { $0.sessionId == sid }) else { continue }
            guard Self.transcriptExists(sid) else { forgotten.insert(sid); continue } // never prompted
            let t = TerminalSession(cwd: cwd, claudeArgs: ["--resume", sid], sessionId: sid, fontSize: fontSize)
            add(t)
            out.append(t)
        }
        return out
    }

    static func transcriptExists(_ sid: String) -> Bool {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: Paths.projects.path) else { return false }
        return dirs.contains { fm.fileExists(atPath: Paths.projects.appendingPathComponent($0).appendingPathComponent("\(sid).jsonl").path) }
    }

    private func add(_ t: TerminalSession) {
        terminals.append(t)
        observe(t)
        persistTerminals()
    }

    /// Resume a session in an embedded terminal (or return the one already open).
    func resume(_ sid: String) -> TerminalSession {
        if let t = terminals.first(where: { $0.sessionId == sid }) { return t }
        let cwd = records[sid]?.cwd ?? live[sid]?.cwd ?? NSHomeDirectory()
        let t = TerminalSession(cwd: cwd, claudeArgs: ["--resume", sid], sessionId: sid, fontSize: fontSize)
        add(t)
        return t
    }

    func newSession(in cwd: String) -> TerminalSession {
        let t = TerminalSession(cwd: cwd, claudeArgs: [], sessionId: nil, fontSize: fontSize)
        add(t)
        return t
    }

    func close(_ t: TerminalSession) {
        t.terminate()
        if let sid = t.sessionId { forgotten.insert(sid) }
        terminals.removeAll { $0 === t }
        persistTerminals()
    }

    /// Folders that have running sessions, grouped by project root (worktrees fold into their repo).
    var runningProjects: [(folder: String, count: Int)] {
        let roots = allActiveItems.map { projectRoot($0.cwd) }
        return Dictionary(grouping: roots, by: { $0 }).map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.folder < $1.folder }
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
