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
    var activity: Activity? = nil
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
    /// Remote sandboxes (boat.dev) each session uses.
    let sandboxes = SandboxRegistry()
    @Published private(set) var prs: [String: [PRInfo]] = [:]            // by sessionId
    private let prMonitor = PRMonitor()
    /// Every past session on disk, loaded lazily for the command palette.
    @Published private(set) var history: [SessionRecord] = []
    /// Session to focus when a project window next looks (folder → session id). Used by the palette.
    private(set) var pendingFocus: [String: String] = [:]

    /// Codex sessions open in tabs, by session id (from their rollouts).
    @Published private(set) var codex: [String: CodexSession] = [:]
    /// Codex tabs showing an approval prompt right now.
    @Published private(set) var codexWaiting: Set<UUID> = []
    private let codexScanner = CodexScanner()
    /// agy conversations open in tabs, by conversation id.
    @Published private(set) var agy: [String: AgySession] = [:]
    private let agyScanner = AgyScanner()
    private var screenCheckBusy = false

    private let scanner = TranscriptScanner()
    private let historyScanner = TranscriptScanner()
    private let statsReader = StatsReader()
    private let scanQueue = DispatchQueue(label: "studio.scan", qos: .utility)
    private var liveTimer: Timer?
    private var scanTimer: Timer?
    private var lastStatus: [String: String] = [:]
    /// When each session last started working; a finish only notifies after real work.
    private var busySince: [String: Date] = [:]
    private let notifications = NotificationHandler()
    /// Session currently shown in each window (window id → session id); used for the attention badge.
    private var viewing: [UUID: String] = [:]
    /// Project folders whose saved terminals have been restored into a window.
    private var restoredFolders: Set<String> = []
    private var bag: Set<AnyCancellable> = []

    /// The app's single store, for the app delegate (quit handling).
    static weak var current: SessionStore?

    init() {
        Self.current = self
        StudioControl.shared.start(store: self)
        refreshLive()
        rescanTranscripts()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescanTranscripts() }
        }
        if Self.canNotify {
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
            center.setNotificationCategories([UNNotificationCategory(identifier: "session", actions: [open], intentIdentifiers: [])])
            notifications.store = self
            center.delegate = notifications
        }
    }

    // MARK: Scanning

    func rescanTranscripts() {
        let ids = Set(live.keys).union(terminals.filter(\.isClaude).compactMap(\.sessionId))
        // Token stats read a whole transcript (some are hundreds of MB): only for sessions Studio shows them
        // for, the tabs and sidebar rows of open windows, not every Claude running on the machine.
        let folders = restoredFolders
        let statIds = Set(terminals.filter(\.isClaude).compactMap(\.sessionId))
            .union(live.values.filter { i in folders.contains { isInside(i.cwd, $0) } }.map(\.sessionId))
        let codexIds = Set(terminals.filter(\.isCodex).compactMap(\.sessionId))
        // Codex tabs that haven't learned their conversation yet (Codex writes it on the first message)
        let pending = terminals.filter { $0.isCodex && $0.sessionId == nil && $0.running }.map { ($0.id, $0.cwd, $0.createdAt) }
        let agyIds = Set(terminals.filter(\.isAgy).compactMap(\.sessionId))
        let agyPending = terminals.filter { $0.isAgy && $0.sessionId == nil && $0.running }.map { ($0.id, $0.cwd, $0.createdAt) }
        scanQueue.async { [scanner, statsReader, codexScanner, agyScanner] in
            let recs = scanner.scan(ids: ids)
            var dict = Dictionary(recs.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.lastActivity > b.lastActivity ? a : b })
            var st: [String: TranscriptStats] = [:]
            for r in dict.values where statIds.contains(r.id) { st[r.id] = statsReader.stats(for: r.transcriptPath) }
            var found: [UUID: String] = [:]
            var taken = codexIds
            for (tab, cwd, since) in pending {
                if let id = codexScanner.started(in: cwd, since: since, excluding: taken) { found[tab] = id; taken.insert(id) }
            }
            let cx = taken.isEmpty ? [:] : codexScanner.scan(ids: taken)   // no Codex tabs: don't touch ~/.codex
            for (id, c) in cx { dict[id] = c.record; st[id] = c.stats }
            var agyTaken = agyIds
            for (tab, cwd, since) in agyPending {
                if let id = agyScanner.started(in: cwd, since: since, excluding: agyTaken) { found[tab] = id; agyTaken.insert(id) }
            }
            let ag = agyTaken.isEmpty ? [:] : agyScanner.scan(ids: agyTaken)
            for (id, a) in ag { dict[id] = a.record }
            DispatchQueue.main.async {
                if self.agy != ag { self.agy = ag }
                for (tab, id) in found { self.terminals.first { $0.id == tab && $0.sessionId == nil }?.sessionId = id }
                if !found.isEmpty { self.persistTerminals() }
                if self.codex != cx { self.codex = cx }
                if self.records != dict { self.records = dict }
                if self.stats != st { self.stats = st }
                self.refreshPRs()
            }
        }
    }

    /// Look up PRs for every running session (throttled per session inside PRMonitor).
    func refreshPRs(force: Bool = false) {
        let reqs: [PRMonitor.Request] = allActiveItems.compactMap { item in
            guard let sid = item.sessionId, let st = stats[sid] else { return nil }
            return .init(sessionId: sid, cwd: item.cwd, prURLs: st.prURLs, branch: st.gitBranch)
        }
        prMonitor.refresh(reqs, force: force) { sid, list in
            if self.prs[sid] != list { self.prs[sid] = list }
        }
    }

    func loadHistory() {
        scanQueue.async { [historyScanner] in
            let all = (historyScanner.scan(ids: nil) + self.codexScanner.all() + self.agyScanner.all()).sorted { $0.lastActivity > $1.lastActivity }
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
        for t in terminals where t.running && t.isClaude {
            if let info = byPid[t.sessionPid], t.sessionId != info.sessionId {
                if let previous = t.sessionId { forgotten.insert(previous) }   // e.g. after /clear
                t.sessionId = info.sessionId
                persistTerminals()
            }
        }

        // Transitions that mean "this session needs you": it finished, or it's blocked on you.
        // Nothing happens for a session you're looking at; a finish only notifies after 30s+ of work.
        // Codex logs no pending approvals, so look for its approval prompt on screen (read through tmux;
        // only mid-turn, the only time it asks). Off the main thread; the result lands a moment later.
        let asking = terminals.compactMap { t -> (UUID, String)? in
            guard t.isCodex, t.running, let h = t.hostName, let sid = t.sessionId, codex[sid]?.busy == true else { return nil }
            return (t.id, h)
        }
        if asking.isEmpty { if !codexWaiting.isEmpty { codexWaiting = [] } }
        else if !screenCheckBusy {
            screenCheckBusy = true
            DispatchQueue.global(qos: .utility).async {
                let w = Set(asking.filter { SessionHost.screen($0.1).map(CodexScanner.isAskingApproval) == true }.map(\.0))
                DispatchQueue.main.async {
                    self.screenCheckBusy = false
                    if self.codexWaiting != w { self.codexWaiting = w }
                }
            }
        }
        let waiting = codexWaiting

        let viewed = Set(viewing.values)
        var states = bySid.map { (sid: $0.key, status: $0.value.status, waitingFor: $0.value.waitingFor, cwd: $0.value.cwd, name: $0.value.name) }
        for t in terminals where t.isCodex && t.running {
            guard let sid = t.sessionId else { continue }
            let s = waiting.contains(t.id) ? "waiting" : codex[sid]?.busy == true ? "busy" : "idle"
            states.append((sid, s, waiting.contains(t.id) ? "approval" : nil, t.cwd, nil))
        }
        for t in terminals where t.isAgy && t.running {
            guard let sid = t.sessionId, let a = agy[sid] else { continue }
            states.append((sid, a.waiting ? "waiting" : a.busy ? "busy" : "idle", a.waiting ? "permission" : nil, t.cwd, nil))
        }
        for st in states {
            let sid = st.sid
            let prev = lastStatus[sid]
            let watching = viewed.contains(sid) && NSApp.isActive
            if st.status == "busy", prev != "busy" { busySince[sid] = Date() }
            if let prev, prev != st.status {
                if st.status == "waiting", !watching {
                    attention.insert(sid)
                    notify(sid: sid, waiting: true, waitingFor: st.waitingFor, cwd: st.cwd, name: st.name)
                } else if prev == "busy", st.status == "idle", !watching {
                    attention.insert(sid)
                    if let since = busySince[sid], Date().timeIntervalSince(since) >= 30 {
                        notify(sid: sid, waiting: false, waitingFor: nil, cwd: st.cwd, name: st.name)
                    }
                }
            }
            if st.status != "busy" { busySince[sid] = nil }
            lastStatus[sid] = st.status
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
        for t in terminals where t.isClaude {   // plain terminals aren't Claude sessions
            let sid = t.sessionId
            if let sid { covered.insert(sid) }
            let info = sid.flatMap { live[$0] }
            let rec = sid.flatMap { records[$0] }
            let status: SessionStatus = t.native?.status
                ?? (!t.running ? .exited : (info.map { SessionStatus(raw: $0.status) } ?? .starting))
            items.append(ActiveItem(
                key: "t:\(t.id)",
                sessionId: sid,
                title: title(rec: rec, info: info, fallback: "New session"),
                cwd: info?.cwd ?? rec?.cwd ?? t.cwd,
                status: status, inApp: true, entrypoint: "studio", pid: t.sessionPid,
                startedAt: t.createdAt, updatedAt: info?.updatedAt ?? t.createdAt,
                activity: t.native.map { $0.activity } ?? Self.activity(status, rec)))
        }
        for t in terminals where t.isCodex || t.isAgy {
            let sid = t.sessionId
            if let sid { covered.insert(sid) }
            let rec = sid.flatMap { records[$0] }
            let waiting = t.isCodex ? codexWaiting.contains(t.id) : sid.flatMap { agy[$0] }?.waiting == true
            let busy = t.isCodex ? sid.flatMap { codex[$0] }?.busy == true : sid.flatMap { agy[$0] }?.busy == true
            let status: SessionStatus = !t.running ? .exited : waiting ? .waiting : busy ? .working : .idle
            items.append(ActiveItem(
                key: "t:\(t.id)", sessionId: sid,
                title: title(rec: rec, info: nil, fallback: t.agent?.name ?? "Session"),
                cwd: rec?.cwd ?? t.cwd, status: status, inApp: true, entrypoint: t.agent?.rawValue, pid: t.sessionPid,
                startedAt: t.createdAt, updatedAt: rec?.lastActivity ?? t.createdAt,
                activity: status == .working ? (rec?.activity ?? .thinking) : nil))
        }
        for (sid, info) in live where !covered.contains(sid) {
            let rec = records[sid]
            items.append(ActiveItem(
                key: "s:\(sid)", sessionId: sid,
                title: title(rec: rec, info: info, fallback: "New session"),
                cwd: info.cwd, status: SessionStatus(raw: info.status), inApp: false,
                entrypoint: info.entrypoint, pid: info.pid,
                startedAt: info.startedAt, updatedAt: info.updatedAt,
                activity: Self.activity(SessionStatus(raw: info.status), rec)))
        }
        return items.sorted { $0.startedAt > $1.startedAt }
    }

    /// Only a working session has an activity; "shell" status means Claude is running a command.
    static func activity(_ s: SessionStatus, _ rec: SessionRecord?) -> Activity? {
        switch s {
        case .shell: return .tool("Bash")
        case .working: return rec?.activity ?? .thinking
        default: return nil
        }
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
    /// another Studio instance) are kept; only sessions this instance ended are dropped.
    private var forgotten: Set<String> = []

    private func persistTerminals() {
        // A --no-restore instance is a throwaway side-by-side copy: never touch the saved tab list.
        guard !CommandLine.arguments.contains("--no-restore") else { return }
        let current: [[String: String]] = terminals.compactMap { t in
            guard let sid = t.sessionId, t.isAgent else { return nil }
            var e = ["sid": sid, "cwd": t.cwd, "tab": t.id.uuidString]
            if !t.isClaude { e["agent"] = t.agent?.rawValue }
            if let h = t.hostName, !t.isNative { e["tmux"] = h }   // reattach to it next launch
            return e
        }
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
            let root = home(of: e, cwd: cwd)
            if !seen.contains(root) && !restoredFolders.contains(root) { seen.append(root) }
        }
        return seen
    }

    /// The window a saved tab reopens in: the one whose saved layout lists it, else its project root.
    private func home(of e: [String: String], cwd: String) -> String {
        e["sid"].flatMap(SavedLayout.owner(of:)) ?? projectRoot(cwd)
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
            // Only this window's own sessions: a window for ~ must not swallow every project under it.
            guard let sid = e["sid"], let cwd = e["cwd"], home(of: e, cwd: cwd) == folder,
                  !terminals.contains(where: { $0.sessionId == sid }) else { continue }
            if let agent = e["agent"].flatMap(Agent.init(rawValue:)), agent != .claude {
                let tab = e["tab"].flatMap(UUID.init(uuidString:)) ?? UUID()
                let host = e["tmux"].flatMap { SessionHost.enabled && SessionHost.exists($0) ? $0 : nil }
                guard host != nil || scanQueue.sync(execute: { agent == .codex ? codexScanner.exists(sid) : agyScanner.exists(sid) })
                else { forgotten.insert(sid); continue }
                let t = agent == .codex ? newCodex(in: cwd, resume: sid, id: tab, host: host) : newAgy(in: cwd, resume: sid, id: tab, host: host)
                out.append(t)
                continue
            }
            // Still running in its host session (Studio was only restarted): reattach, same tab id.
            if let h = e["tmux"], SessionHost.enabled, SessionHost.exists(h) {
                let t = TerminalSession(cwd: cwd, claudeArgs: ["--resume", sid], sessionId: sid, fontSize: fontSize,
                                        id: e["tab"].flatMap(UUID.init(uuidString:)) ?? UUID(), host: h)
                add(t)
                out.append(t)
                continue
            }
            guard live[sid] == nil else { continue }                  // running elsewhere → leave it
            guard Self.transcriptExists(sid) else { forgotten.insert(sid); continue } // never prompted
            let t = TerminalSession(cwd: Self.resumeDir(sid, fallback: cwd), claudeArgs: ["--resume", sid], sessionId: sid, fontSize: fontSize,
                                    native: TerminalSession.nativeSessions.contains(sid))
            add(t)
            out.append(t)
        }
        return out
    }

    /// The folder a conversation must be resumed in: the project Claude filed its transcript under
    /// (~/.claude/projects/<cwd with non-alphanumerics as dashes>/<sid>.jsonl). A saved tab can carry a
    /// stale folder; resuming there lands on a trust prompt and an empty, MCP-less session.
    static func resumeDir(_ sid: String, fallback: String) -> String {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: Paths.projects.path),
              let dir = dirs.first(where: { fm.fileExists(atPath: Paths.projects.appendingPathComponent($0).appendingPathComponent("\(sid).jsonl").path) })
        else { return fallback }
        func encode(_ p: String) -> String { p.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression) }
        // the fallback or one of its parents usually matches
        var c = fallback
        while c.count > 1 {
            if encode(c) == dir { return c }
            c = (c as NSString).deletingLastPathComponent
        }
        // otherwise rebuild the path from the encoded name, choosing at each dash between "/" and a literal
        // character by what exists on disk
        let tokens = dir.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func walk(_ i: Int, _ path: String, _ seg: String) -> String? {
            if i == tokens.count {
                let full = path + "/" + seg
                return fm.fileExists(atPath: full) ? full : nil
            }
            let t = tokens[i]
            if !seg.isEmpty, fm.fileExists(atPath: path + "/" + seg), let r = walk(i + 1, path + "/" + seg, t) { return r }
            for sep in ["-", ".", "_", " "] where !seg.isEmpty {
                if let r = walk(i + 1, path, seg + sep + t) { return r }
            }
            return seg.isEmpty ? walk(i + 1, path, t) : nil
        }
        if tokens.count > 1, let found = walk(2, "", tokens[1]), encode(found) == dir { return found }
        return fallback
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
        if let r = records[sid] ?? history.first(where: { $0.id == sid }), r.agent != .claude {
            let dir = FileManager.default.fileExists(atPath: r.cwd) ? r.cwd : NSHomeDirectory()
            return r.agent == .codex ? newCodex(in: dir, resume: sid) : newAgy(in: dir, resume: sid)
        }
        let cwd = Self.resumeDir(sid, fallback: records[sid]?.cwd ?? live[sid]?.cwd ?? NSHomeDirectory())
        let t = TerminalSession(cwd: cwd, claudeArgs: ["--resume", sid], sessionId: sid, fontSize: fontSize,
                                native: TerminalSession.nativeSessions.contains(sid))
        add(t)
        return t
    }

    /// A copy of a conversation under a new session id (`claude --resume <id> --fork-session`).
    /// The original keeps running untouched; the fork learns its own id once Claude starts.
    func fork(_ sid: String, cwd: String, agent: Agent = .claude) -> TerminalSession {
        if agent == .codex { return newCodex(in: cwd, fork: sid) }
        let t = TerminalSession(cwd: cwd, claudeArgs: ["--resume", sid, "--fork-session"], sessionId: nil, fontSize: fontSize)
        add(t)
        return t
    }

    /// A new agent session: the default CLI from Settings (Claude Code or Codex) unless `agent` says which.
    func newSession(in cwd: String, prompt: String? = nil, agent: Agent? = nil) -> TerminalSession {
        switch agent ?? Agent.preferred {
        case .codex: return newCodex(in: cwd, prompt: prompt)
        case .agy: return newAgy(in: cwd, prompt: prompt)
        case .claude: break
        }
        let t = TerminalSession(cwd: cwd, claudeArgs: prompt.map { [$0] } ?? [], sessionId: nil, fontSize: fontSize)
        add(t)
        return t
    }

    /// A Codex CLI session: new, continuing conversation `resume` (or the folder's latest with `resumeLast`),
    /// or a copy of conversation `fork`. `host` reattaches to a tab still running in tmux.
    func newCodex(in cwd: String, prompt: String? = nil, resume: String? = nil, resumeLast: Bool = false,
                  fork: String? = nil, id: UUID = UUID(), host: String? = nil) -> TerminalSession {
        let args = resume.map { ["resume", $0] } ?? fork.map { ["fork", $0] }
            ?? (resumeLast ? ["resume", "--last"] : prompt.map { ["--", $0] } ?? [])
        let t = TerminalSession(cwd: cwd, claudeArgs: args, sessionId: resume, fontSize: fontSize, kind: .codex,
                                id: id, host: host)
        add(t)
        return t
    }

    /// An Antigravity (`agy`) session: new (with a first prompt), or continuing conversation `resume`.
    func newAgy(in cwd: String, prompt: String? = nil, resume: String? = nil, id: UUID = UUID(), host: String? = nil) -> TerminalSession {
        let args = resume.map { ["--conversation", $0] } ?? prompt.map { ["-i", $0] } ?? []
        let t = TerminalSession(cwd: cwd, claudeArgs: args, sessionId: resume, fontSize: fontSize, kind: .agy, id: id, host: host)
        add(t)
        return t
    }

    /// Whether a tab's conversation is on disk yet (something to fork).
    func hasConversation(_ t: TerminalSession) -> Bool {
        guard let sid = t.sessionId else { return false }
        return t.isClaude ? Self.transcriptExists(sid) : records[sid] != nil
    }

    /// Reattach to a Codex tab still running in its host session (or continue its last conversation).
    func reattachCodex(tab: UUID, host: String, cwd: String) -> TerminalSession {
        if let t = terminals.first(where: { $0.id == tab }) { return t }
        let alive = SessionHost.exists(host)
        let t = TerminalSession(cwd: cwd, claudeArgs: alive ? [] : ["resume", "--last"], sessionId: nil, fontSize: fontSize,
                                kind: .codex, id: tab, host: alive ? host : nil)
        add(t)
        return t
    }

    /// A plain terminal (⌃`) in the folder; not a Claude session, so it isn't listed or restored.
    /// A web panel tab (opened by ⌘P → Open URL, the open_url MCP tool, or a sandbox's desktop/URL).
    func newWeb(_ url: URL?, cwd: String) -> TerminalSession {
        let t = TerminalSession(cwd: cwd, claudeArgs: [], sessionId: nil, fontSize: fontSize, kind: .web)
        t.url = url
        add(t)
        return t
    }

    /// Reattach to a terminal tab still running in its host session (or start a fresh shell there).
    func reattachShell(tab: UUID, host: String, cwd: String) -> TerminalSession {
        if let t = terminals.first(where: { $0.id == tab }) { return t }
        let t = TerminalSession(cwd: cwd, claudeArgs: [], sessionId: nil, fontSize: fontSize, kind: .shell,
                                id: tab, host: SessionHost.exists(host) ? host : nil)
        add(t)
        return t
    }

    /// Set while the app quits: windows closing then must not end hosted sessions.
    static var terminating = false

    func newShell(in cwd: String) -> TerminalSession {
        let t = TerminalSession(cwd: cwd, claudeArgs: [], sessionId: nil, fontSize: fontSize, kind: .shell)
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

    /// Only while you're in another app: inside Studio the tab badges already say it.
    private func notify(sid: String, waiting: Bool, waitingFor: String?, cwd: String, name: String?) {
        guard Self.canNotify, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        let rec = records[sid]
        content.title = rec?.title.flatMap { $0.isEmpty ? nil : $0 } ?? name ?? rec?.firstPrompt ?? (rec?.agent ?? .claude).name
        if waiting {
            content.subtitle = "Needs you: \(waitingFor ?? "input")"
        }
        let reply = rec?.lastReply.map { $0.replacingOccurrences(of: "\n", with: " ") }
        content.body = reply.map { String($0.suffix(180)) } ?? (waiting ? "Blocked until you answer" : "Finished — ready for you")
        content.sound = .default
        content.categoryIdentifier = "session"
        content.userInfo = ["sid": sid, "cwd": cwd]
        let req = UNNotificationRequest(identifier: sid, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Next up

    /// Studio sessions that need you, most urgent first: blocked ones (permission, questions), then
    /// finished-and-unread ones; within each, whoever has waited longest.
    var nextUp: [ActiveItem] {
        allActiveItems
            .filter { $0.inApp && ($0.status == .waiting || $0.sessionId.map(attention.contains) == true) }
            .sorted {
                let (a, b) = ($0.status == .waiting, $1.status == .waiting)
                return a != b ? a : $0.updatedAt < $1.updatedAt
            }
    }

    /// Bring a session forward in its project's window, opening the window if needed.
    func reveal(sessionId sid: String, cwd: String) {
        let root = projectRoot(cwd)
        requestFocus(sessionId: sid, in: root)
        StudioControl.shared.openWindow?(root)
    }
}

/// Clicking a Studio notification (or its Open button) jumps to that session.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    weak var store: SessionStore?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let sid = info["sid"] as? String, let cwd = info["cwd"] as? String {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                MainActor.assumeIsolated { self.store?.reveal(sessionId: sid, cwd: cwd) }
            }
        }
        done()
    }
}
