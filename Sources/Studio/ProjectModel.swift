import AppKit
import Combine
import SwiftUI

/// State for one project window: its folder, the split layout of editor groups, and which group is active.
/// Selection keys: "t:<terminal uuid>" for an in-app tab, "s:<session id>" for a session running elsewhere.
@MainActor
final class ProjectModel: ObservableObject {
    let windowId = UUID()
    let folder: String
    let store: SessionStore
    @Published private(set) var root: LayoutNode
    @Published private(set) var activeGroupId: UUID
    /// Command palette: nil when closed, otherwise the text it opened with ("" for sessions, ">" for commands).
    @Published var palette: String?
    /// Sidebar visibility and width (⌘B, drag its edge, or the Studio MCP). Shared by all windows.
    private var sidebarPref: Any?
    @Published var sidebarVisible: Bool = UserDefaults.standard.object(forKey: "sidebarVisible.v2") as? Bool ?? false {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible.v2") }
    }
    @Published var sidebarWidth: CGFloat = UserDefaults.standard.object(forKey: "sidebarWidth") as? CGFloat ?? 250 {
        didSet { UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") }
    }
    /// Where a tab being dragged would land (drives the shaded snap preview). One per window, so a preview can
    /// never linger in a group the drag already left.
    @Published private(set) var dropTarget: (group: UUID, zone: DropZone)?
    private var dropWatch: Timer?
    private var bag: Set<AnyCancellable> = []
    private var clickMonitor: Any?

    init(folder: String, store: SessionStore) {
        self.folder = folder
        self.store = store
        let first = GroupNode()
        root = .group(first)
        activeGroupId = first.id
        // Settings → Appearance → Show session sidebar applies to every open window, live.
        sidebarPref = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let v = UserDefaults.standard.object(forKey: "sidebarVisible.v2") as? Bool ?? false
                if v != self.sidebarVisible { self.sidebarVisible = v }
            }
        }
        RecentProjects.add(folder)
        // Re-render this window whenever global session state changes.
        // Delivered a run-loop turn later, never synchronously: the store changes while this window is being
        // built (restoring and reattaching tabs), and telling SwiftUI about it mid-build aborts the app.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
                self?.consumePendingFocus()
                self?.saveLayoutSoon()   // new sessions learn their id later; save once they have it
            }.store(in: &bag)
        watchClicks()
        StudioControl.shared.register(self)
        launchObserver = NotificationCenter.default.addObserver(forName: .studioLaunchNewSession, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.consumeLaunchNewSession() }
        }
        // Restore after this window is built, not while SwiftUI is creating it: restoring adds sessions to the
        // shared store, and changing observed state in the middle of a view update aborts the app.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // tabs opened before this ran (--new, a session opened from another window) must survive the restore
            let opened = self.groups.flatMap(\.tabIds)
            let restored = self.store.restoreTerminals(in: folder)
            if !self.restoreLayout() {
                first.tabIds = opened + restored.map(\.id).filter { !opened.contains($0) }
                first.selection = first.selection ?? first.tabIds.first.map { "t:\($0)" }
            } else if !opened.isEmpty {
                let present = Set(self.groups.flatMap(\.tabIds))
                let missing = opened.filter { !present.contains($0) }
                if let g = self.groups.first, !missing.isEmpty {
                    g.tabIds += missing
                    g.selection = "t:\(missing.last!)"
                    self.activeGroupId = g.id
                }
            }
            self.objectWillChange.send()
            self.consumePendingFocus()   // opened from another window's palette
            self.restored = true
            self.consumeLaunchNewSession()
            self.focusTerminal()
        }
    }

    var name: String { projectName(for: folder) }
    var items: [ActiveItem] { store.activeItems(in: folder) }
    var groups: [GroupNode] { root.groups }
    var activeGroup: GroupNode { groups.first { $0.id == activeGroupId } ?? groups[0] }

    func terminal(_ id: UUID) -> TerminalSession? { store.terminals.first { $0.id == id } }
    func tabs(in g: GroupNode) -> [TerminalSession] { g.tabIds.compactMap(terminal) }
    func group(containing id: UUID) -> GroupNode? { groups.first { $0.tabIds.contains(id) } }
    func isOpen(_ t: TerminalSession) -> Bool { group(containing: t.id) != nil }

    /// Tabs of the active group (what ⌘[ / ⌘] / ⌘1-9 act on).
    var tabs: [TerminalSession] { tabs(in: activeGroup) }

    /// The active group's selection. Setting a terminal that isn't open anywhere opens it in the active group;
    /// setting one open in another group activates that group instead.
    var selection: String? {
        get { activeGroup.selection }
        set {
            if let sel = newValue, sel.hasPrefix("t:"), let id = UUID(uuidString: String(sel.dropFirst(2))) {
                if let g = group(containing: id) {
                    activeGroupId = g.id
                    g.selection = sel
                } else if terminal(id) != nil {
                    activeGroup.tabIds.append(id)
                    activeGroup.selection = sel
                }
            } else {
                activeGroup.selection = newValue
            }
            changed()
            focusTerminal()   // picking a session (⌘P, ⌘J, ⌘1…9, the sidebar) puts you in its input
        }
    }

    func selectedTerminal(in g: GroupNode) -> TerminalSession? {
        guard let sel = g.selection, sel.hasPrefix("t:"), let id = UUID(uuidString: String(sel.dropFirst(2))) else { return nil }
        return terminal(id)
    }
    var selectedTerminal: TerminalSession? { selectedTerminal(in: activeGroup) }

    var selectedSessionId: String? {
        guard let sel = selection else { return nil }
        if sel.hasPrefix("s:") { return String(sel.dropFirst(2)) }
        return selectedTerminal?.sessionId
    }

    func item(for t: TerminalSession) -> ActiveItem? { store.allActiveItems.first { $0.key == "t:\(t.id)" } }

    private func changed() {
        objectWillChange.send()
        saveLayout()
        StudioControl.shared.noteActive(self)
        store.setViewing(window: windowId, sessionId: selectedSessionId)
    }

    // MARK: Actions

    /// Show a session in this window: its tab if it runs here, the info pane if it runs elsewhere, else resume it.
    func open(sessionId sid: String) {
        if let t = store.terminals.first(where: { $0.sessionId == sid }) { select(t) }
        else if store.live[sid] != nil { selection = "s:\(sid)" }
        else { resume(sid) }
    }

    private func consumePendingFocus() {
        if let sid = store.takePendingFocus(for: folder) { open(sessionId: sid) }
    }

    func activate(_ g: GroupNode) {
        guard activeGroupId != g.id else { return }
        activeGroupId = g.id
        changed()
    }

    /// Put keyboard focus in the selected tab: its terminal, its page for a web panel, or the input of the
    /// native view. A tab that was just selected may not be in the window yet, so keep trying for a moment.
    func focusTerminal() {
        guard let t = selectedTerminal else { return }
        func attempt(_ left: Int) {
            guard selectedTerminal === t else { return }   // the selection moved on
            let v: NSView? = t.isNative ? t.native?.inputView : t.isWeb ? t.webView : t.view
            if let v, let w = v.window { w.makeFirstResponder(v) }
            else if left > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attempt(left - 1) } }
        }
        DispatchQueue.main.async { attempt(40) }   // up to 2s: a native view may still be starting
    }

    func newTab() { select(store.newSession(in: folder)) }

    private var restored = false
    private var launchObserver: Any?
    /// `--new <dir>`: once this window has restored its tabs, add the fresh session (asked for from either side
    /// of the restore, since SwiftUI may bring the window up before or after the launch flag is read).
    func consumeLaunchNewSession() {
        guard restored, LaunchArgs.pendingNewSession == folder else { return }   // the restore pass calls this again
        LaunchArgs.pendingNewSession = nil
        newTab()
    }

    /// ⌘K quick prompt is open.
    @Published var quickPrompt = false

    /// Sessions ⌘K can message: the current one first, then this window's tabs, then other projects'.
    var quickTargets: [TerminalSession] {
        let claude = store.terminals.filter { $0.isAgent && $0.running }
        let mine = tabs.filter { $0.isAgent && $0.running }
        var out: [TerminalSession] = []
        if let cur = selectedTerminal, cur.isAgent, cur.running { out.append(cur) }
        for t in mine + claude where !out.contains(where: { $0 === t }) { out.append(t) }
        return out
    }

    func title(of t: TerminalSession) -> String { item(for: t)?.title ?? "New session" }

    /// Short message shown at the bottom of the window ("All caught up").
    @Published var toast: String?
    /// Tab whose peek card is showing (hover).
    @Published var peekTab: UUID?

    /// ⌘J: jump to the session that has waited longest for you (blocked ones first), in any project.
    func goToNextUp() {
        let current = selectedSessionId
        guard let item = store.nextUp.first(where: { $0.sessionId != current }), let sid = item.sessionId else {
            showToast("All caught up")
            return
        }
        if isInside(item.cwd, folder) || isInside(projectRoot(item.cwd), folder) { open(sessionId: sid) }
        else { store.reveal(sessionId: sid, cwd: item.cwd) }
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    func newShellTab() { select(store.newShell(in: folder)) }

    /// Open a web panel: in a split beside the active pane (or as a tab with zone .center).
    @discardableResult
    func openWeb(_ url: URL?, beside g: GroupNode? = nil, zone: DropZone = .right) -> TerminalSession {
        let t = store.newWeb(url, cwd: folder)
        place(t, beside: g ?? activeGroup, zone: zone)
        return t
    }

    /// ⌘/: switch the session between Claude's terminal UI and Studio's native view.
    func toggleNative(_ t: TerminalSession? = nil) {
        guard let t = t ?? selectedTerminal, t.isClaude else { showToast("Select a Claude session"); return }
        guard t.sessionId != nil else { showToast("Send a message first, then switch views"); return }
        let goingNative = !t.isNative
        t.toggleNative()
        showToast(goingNative ? "Native view" : "Terminal view")
        focusTerminal()   // into the new view's input once it's up
    }

    /// ⌘E: fork a session into a new pane beside it, so you can try another direction without losing this one.
    func fork(_ t: TerminalSession? = nil, zone: DropZone = .right) {
        guard let t = t ?? selectedTerminal, let agent = t.agent else { showToast("Select a session to fork"); return }
        guard agent.canFork else { showToast("\(agent.name) can't fork a conversation"); return }
        guard let sid = t.sessionId, store.hasConversation(t) else { showToast("Nothing to fork yet: send a message first"); return }
        let g = group(containing: t.id) ?? activeGroup
        place(store.fork(sid, cwd: t.cwd, agent: agent), beside: g, zone: zone)
    }

    func resume(_ sid: String) { select(store.resume(sid)) }

    func select(_ t: TerminalSession) { selection = "t:\(t.id)" }

    func select(_ t: TerminalSession, in g: GroupNode) {
        activeGroupId = g.id
        g.selection = "t:\(t.id)"
        changed()
        focusTerminal()
    }

    /// Close a tab. Without the sidebar there's nowhere for a hidden session to show up, so closing ends it
    /// (⌘P can still resume the conversation). With the sidebar visible, the session keeps running there.
    func close(_ t: TerminalSession) {
        if !Pref.bool(Pref.closeTabEndsSession, default: true) && t.isAgent { closeKeepingRunning(t) } else { endSession(t) }
    }

    /// Close the tab only; a Claude session keeps running (find it with ⌘P). A terminal ends.
    func closeKeepingRunning(_ t: TerminalSession) {
        guard let g = group(containing: t.id) else { return }
        detach(t.id, from: g)   // an emptied pane stays, showing its empty state
        if !t.isAgent { store.close(t) }   // terminals and web panels have nowhere else to live
        changed()
    }

    /// Stop the claude process for good (it can still be resumed later with `claude --resume`).
    func endSession(_ t: TerminalSession) {
        closeKeepingRunning(t)
        if t.isAgent { store.close(t) }   // a shell or web panel was already ended
    }

    func closeSelectedTab() { if let t = selectedTerminal { close(t) } }

    /// Remove a pane from the split (its tabs, if any, fold into a neighbour).
    func closePane(_ g: GroupNode) { merge(g) }

    func cycleTab(_ d: Int) {
        let list = tabs
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { "t:\($0.id)" == selection } ?? (d > 0 ? -1 : 0)
        select(list[(idx + d + list.count) % list.count])
    }

    func selectTab(_ i: Int) {
        let list = tabs
        if i < list.count { select(list[i]) }
    }

    func windowClosed() {
        saveLayout()
        // Plain terminals live only in this window's layout; end them rather than leave them running unreachable.
        // (Quitting is different: hosted terminals keep running and the next launch reattaches them.)
        if !SessionStore.terminating {
            for g in groups { for t in tabs(in: g) where !t.isAgent { store.close(t) } }
        }
        store.endViewing(window: windowId)
        StudioControl.shared.unregister(self)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: Drop preview

    func setDropTarget(_ g: GroupNode, _ zone: DropZone) {
        if dropTarget?.group != g.id || dropTarget?.zone != zone { dropTarget = (g.id, zone) }
        // SwiftUI doesn't always report a drag leaving (drop on another target, outside the window, Esc).
        // While a preview shows, check the mouse button; once it's up the drag is over.
        if dropWatch == nil {
            dropWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    if NSEvent.pressedMouseButtons & 1 == 0 { self?.clearDropTarget() }
                }
            }
        }
    }

    func clearDropTarget(_ g: GroupNode? = nil) {
        if let g, dropTarget?.group != g.id { return }
        if dropTarget != nil { dropTarget = nil }
        dropWatch?.invalidate()
        dropWatch = nil
    }

    // MARK: Splits

    /// Move a tab into `target`: the middle drops it in as a tab, an edge splits `target` that way.
    func move(_ id: UUID, to target: GroupNode, zone: DropZone) {
        guard let source = group(containing: id) else {
            // a running session not open as a tab (dragged in some other way) — just place it
            if zone == .center { target.tabIds.append(id); target.selection = "t:\(id)"; activeGroupId = target.id }
            else { let g = GroupNode(tabIds: [id], selection: "t:\(id)"); insert(g, beside: target, zone: zone); activeGroupId = g.id }
            changed(); focusTerminal(); return
        }
        if zone == .center {
            guard source !== target else { return }
            detach(id, from: source)
            target.tabIds.append(id)
            target.selection = "t:\(id)"
            activeGroupId = target.id
        } else {
            // splitting a group off its own only tab would leave nothing behind
            if source === target && source.tabIds.count == 1 { return }
            detach(id, from: source)
            let g = GroupNode(tabIds: [id], selection: "t:\(id)")
            insert(g, beside: target, zone: zone)
            activeGroupId = g.id
        }
        if source.tabIds.isEmpty, groups.count > 1 { remove(source) }
        changed()
        focusTerminal()
    }

    /// Right-click "Split Right/Left/Up/Down": move the tab into a new group on that side.
    /// If it's the group's only tab, the new group gets a fresh session instead (like VS Code's split terminal).
    func split(_ t: TerminalSession, _ zone: DropZone) {
        guard let g = group(containing: t.id) else { return }
        if g.tabIds.count > 1 {
            move(t.id, to: g, zone: zone)
        } else {
            let fresh = store.newSession(in: folder)
            let ng = GroupNode(tabIds: [fresh.id], selection: "t:\(fresh.id)")
            insert(ng, beside: g, zone: zone)
            activeGroupId = ng.id
            changed()
            focusTerminal()
        }
    }

    /// Show a new terminal: as a tab in `g` (zone nil/center), or in a new group split off `g` on that side.
    func place(_ t: TerminalSession, beside g: GroupNode, zone: DropZone?) {
        if let zone, zone != .center {
            let ng = GroupNode(tabIds: [t.id], selection: "t:\(t.id)")
            insert(ng, beside: g, zone: zone)
            activeGroupId = ng.id
        } else {
            g.tabIds.append(t.id)
            g.selection = "t:\(t.id)"
            activeGroupId = g.id
        }
        changed()
        focusTerminal()
    }

    func resize(_ box: SplitBox, fractions: [CGFloat]) {
        box.fractions = fractions
        objectWillChange.send()
        saveLayoutSoon()
    }

    // MARK: Layout operations (menus + Studio MCP)

    func split(byId id: UUID) -> SplitBox? {
        func find(_ n: LayoutNode) -> SplitBox? {
            guard case .split(let b) = n else { return nil }
            if b.id == id { return b }
            for c in b.children { if let r = find(c) { return r } }
            return nil
        }
        return find(root)
    }

    var splits: [SplitBox] {
        func all(_ n: LayoutNode) -> [SplitBox] {
            guard case .split(let b) = n else { return [] }
            return [b] + b.children.flatMap(all)
        }
        return all(root)
    }

    /// Give a pane `share` (0–1) of its split; its siblings keep their proportions in the rest.
    @discardableResult
    func resize(_ g: GroupNode, share: CGFloat) -> Bool {
        guard let (box, i) = parent(of: g.id) else { return false }
        let share = min(max(share, 0.05), 0.95)
        let others = box.fractions.enumerated().filter { $0.offset != i }.map(\.element).reduce(0, +)
        box.fractions = box.fractions.enumerated().map { j, f in
            j == i ? share : (others > 0 ? f / others * (1 - share) : (1 - share) / CGFloat(box.fractions.count - 1))
        }
        changed()
        return true
    }

    func setSizes(_ box: SplitBox, _ sizes: [CGFloat]) {
        let total = sizes.reduce(0, +)
        guard sizes.count == box.children.count, total > 0 else { return }
        box.fractions = sizes.map { max($0 / total, 0.05) }
        let t2 = box.fractions.reduce(0, +)
        box.fractions = box.fractions.map { $0 / t2 }
        changed()
    }

    func equalize() {
        for b in splits { b.fractions = Array(repeating: 1 / CGFloat(b.children.count), count: b.children.count) }
        changed()
    }

    func focus(_ g: GroupNode) {
        activeGroupId = g.id
        changed()
        focusTerminal()
    }

    /// Fold a pane's tabs into a neighbouring pane and remove it.
    func merge(_ g: GroupNode) {
        guard groups.count > 1 else { return }
        let target = siblingGroup(of: g) ?? groups.first { $0 !== g }!
        target.tabIds += g.tabIds
        if target.selection == nil { target.selection = g.selection }
        g.tabIds = []
        remove(g)
        activeGroupId = target.id
        changed()
    }

    private func siblingGroup(of g: GroupNode) -> GroupNode? {
        guard let (box, i) = parent(of: g.id) else { return nil }
        let near = i > 0 ? box.children[i - 1] : box.children[min(i + 1, box.children.count - 1)]
        return near.groups.first
    }

    func reorder(_ t: TerminalSession, to index: Int) {
        guard let g = group(containing: t.id), let from = g.tabIds.firstIndex(of: t.id) else { return }
        g.tabIds.remove(at: from)
        g.tabIds.insert(t.id, at: min(max(index, 0), g.tabIds.count))
        changed()
    }

    enum Preset: String { case single, columns, rows, grid }

    /// Rearrange every open tab: one pane, N columns, N rows, or a 2×2 grid. Tabs keep their order.
    func applyPreset(_ preset: Preset, panes requested: Int = 2) {
        let all = groups.flatMap(\.tabIds)
        let selected = Set(groups.compactMap { selectedTerminal(in: $0)?.id })
        let activeTab = selectedTerminal?.id
        let n: Int
        switch preset {
        case .single: n = 1
        case .grid: n = 4
        case .columns, .rows: n = max(1, min(requested, 6))
        }
        let count = max(1, min(n, all.count))
        // contiguous chunks, as even as possible
        var chunks: [[UUID]] = []
        var start = 0
        for k in 0..<count {
            let size = all.count / count + (k < all.count % count ? 1 : 0)
            chunks.append(Array(all[start..<start + size]))
            start += size
        }
        let gs = chunks.map { ids -> GroupNode in
            let sel = ids.first { selected.contains($0) } ?? ids.first
            return GroupNode(tabIds: ids, selection: sel.map { "t:\($0)" })
        }
        if gs.count == 1 {
            root = .group(gs[0])
        } else if preset == .grid && gs.count == 4 {
            let top = SplitBox(axis: .horizontal, children: [.group(gs[0]), .group(gs[1])])
            let bottom = SplitBox(axis: .horizontal, children: [.group(gs[2]), .group(gs[3])])
            root = .split(SplitBox(axis: .vertical, children: [.split(top), .split(bottom)]))
        } else {
            root = .split(SplitBox(axis: preset == .rows ? .vertical : .horizontal, children: gs.map { .group($0) }))
        }
        activeGroupId = (activeTab.flatMap { id in gs.first { $0.tabIds.contains(id) } } ?? gs[0]).id
        changed()
        focusTerminal()
    }

    // MARK: Layout persistence

    private var saveWork: DispatchWorkItem?

    /// Divider drags fire continuously; save once they settle.
    private func saveLayoutSoon() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveLayout() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func saveLayout() {
        func encode(_ n: LayoutNode) -> SavedLayout? {
            switch n {
            case .group(let g):
                // Claude tabs are saved by session id; plain terminals as "shell:<cwd>" and reopened fresh.
                func token(_ t: TerminalSession?) -> String? {
                    guard let t else { return nil }
                    if t.isWeb { return "web:" + (t.url?.absoluteString ?? "about:blank") }
                    if t.isAgent, !t.isClaude, let sid = t.sessionId { return sid }   // restored like a Claude tab, by session id
                    if t.isAgy { return "agy:" + t.cwd }   // not prompted yet: a fresh agy there
                    if t.isCodex {
                        // not prompted yet: like terminals: "codexh:<tab>|<host>|<cwd>", else "codex:<cwd>" (continues its last conversation)
                        if let h = t.hostName { return "codexh:\(t.id.uuidString)|\(h)|\(t.cwd)" }
                        return "codex:" + t.cwd
                    }
                    if t.isShell {
                        // hosted terminals reattach next launch: "shellh:<tab>|<host>|<cwd>"
                        if let h = t.hostName { return "shellh:\(t.id.uuidString)|\(h)|\(t.cwd)" }
                        return "shell:" + t.cwd
                    }
                    return t.sessionId
                }
                let sids = g.tabIds.compactMap { token(terminal($0)) }
                let sel = token(selectedTerminal(in: g))
                return .group(tabs: sids, selected: sel, active: g.id == activeGroupId)
            case .split(let box):
                let kids = zip(box.children, box.fractions).compactMap { c, f in encode(c).map { ($0, Double(f)) } }
                guard !kids.isEmpty else { return nil }
                return .split(horizontal: box.axis == .horizontal, fractions: kids.map(\.1), children: kids.map(\.0))
            }
        }
        // Don't overwrite a saved layout while restored sessions are still learning their ids.
        guard groups.flatMap(\.tabIds).allSatisfy({ terminal($0)?.isClaude == false || terminal($0)?.sessionId != nil })
        else { return }
        guard let layout = encode(root), let data = try? JSONEncoder().encode(layout), data != lastSavedLayout else { return }
        lastSavedLayout = data
        layout.save(folder)
    }

    private var lastSavedLayout: Data?

    /// Rebuild the saved split layout from this folder's restored sessions. Returns false if there was nothing to restore.
    private func restoreLayout() -> Bool {
        guard let saved = SavedLayout.load(folder) else { return false }
        // Match by session id across all terminals: a session listed in this layout belongs here even if
        // Claude recorded it under another folder (e.g. one first started in ~).
        let mine = store.terminals
        var used = Set<UUID>()
        var active: UUID?

        func build(_ s: SavedLayout) -> LayoutNode? {
            switch s {
            case .group(let sids, let sel, let isActive):
                var selected: TerminalSession?
                let ts: [TerminalSession] = sids.compactMap { sid in
                    let t: TerminalSession?
                    if sid.hasPrefix("web:") {
                        t = store.newWeb(URL(string: String(sid.dropFirst(4))), cwd: folder)
                    } else if sid.hasPrefix("shellh:") {
                        let parts = sid.dropFirst(7).split(separator: "|", maxSplits: 2).map(String.init)
                        if parts.count == 3, let tab = UUID(uuidString: parts[0]) {
                            t = store.reattachShell(tab: tab, host: parts[1], cwd: parts[2])
                        } else { t = nil }
                    } else if sid.hasPrefix("codexh:") {
                        let parts = sid.dropFirst(7).split(separator: "|", maxSplits: 2).map(String.init)
                        if parts.count == 3, let tab = UUID(uuidString: parts[0]) {
                            t = store.reattachCodex(tab: tab, host: parts[1], cwd: parts[2])
                        } else { t = nil }
                    } else if sid.hasPrefix("agy:") {
                        let cwd = String(sid.dropFirst(4))
                        t = store.newAgy(in: FileManager.default.fileExists(atPath: cwd) ? cwd : folder)
                    } else if sid.hasPrefix("codex:") {
                        let cwd = String(sid.dropFirst(6))
                        t = store.newCodex(in: FileManager.default.fileExists(atPath: cwd) ? cwd : folder, resumeLast: true)
                    } else if sid.hasPrefix("shell:") {
                        let cwd = String(sid.dropFirst(6))
                        t = store.newShell(in: FileManager.default.fileExists(atPath: cwd) ? cwd : folder)
                    } else {
                        t = mine.first { $0.sessionId == sid && !used.contains($0.id) }
                    }
                    if let t, sid == sel, selected == nil { selected = t }
                    return t
                }
                ts.forEach { used.insert($0.id) }
                // an empty pane was kept on purpose (closing its last tab leaves it), so it comes back empty
                let g = GroupNode(tabIds: ts.map(\.id), selection: (selected ?? ts.first).map { "t:\($0.id)" })
                if isActive { active = g.id }
                return .group(g)
            case .split(let horizontal, let fractions, let children):
                let built = zip(children, fractions).compactMap { c, f in build(c).map { ($0, CGFloat(f)) } }
                if built.isEmpty { return nil }
                if built.count == 1 { return built[0].0 }
                let box = SplitBox(axis: horizontal ? .horizontal : .vertical, children: built.map(\.0))
                let total = built.map(\.1).reduce(0, +)
                box.fractions = built.map { total > 0 ? $0.1 / total : 1 / CGFloat(built.count) }
                return .split(box)
            }
        }

        guard let node = build(saved) else { return false }
        root = node
        // sessions that were restored but missing from the saved layout go into the first group
        let leftovers = store.terminals(in: folder).filter { !used.contains($0.id) && $0.sessionId != nil && $0.isAgent }
        if let g = root.groups.first { g.tabIds += leftovers.map(\.id) }
        activeGroupId = active ?? root.groups.first?.id ?? activeGroupId
        return true
    }

    private func detach(_ id: UUID, from g: GroupNode) {
        let idx = g.tabIds.firstIndex(of: id) ?? 0
        g.tabIds.removeAll { $0 == id }
        if g.selection == "t:\(id)" {
            g.selection = g.tabIds.isEmpty ? nil : "t:\(g.tabIds[min(idx, g.tabIds.count - 1)])"
        }
    }

    /// Put `g` next to `target` on the `zone` side, reusing the parent split when it runs the same way.
    private func insert(_ g: GroupNode, beside target: GroupNode, zone: DropZone) {
        guard let axis = zone.axis else { return }
        let new = LayoutNode.group(g)
        if let (parent, i) = parent(of: target.id), parent.axis == axis {
            let half = parent.fractions[i] / 2
            parent.fractions[i] = half
            let at = zone.before ? i : i + 1
            parent.children.insert(new, at: at)
            parent.fractions.insert(half, at: at)
        } else {
            let box = SplitBox(axis: axis, children: zone.before ? [new, .group(target)] : [.group(target), new])
            replace(target.id, with: .split(box))
        }
    }

    private func remove(_ g: GroupNode) {
        guard let (parent, i) = parent(of: g.id) else { return }
        parent.children.remove(at: i)
        let removed = parent.fractions.remove(at: i)
        let rest = parent.fractions.reduce(0, +)
        parent.fractions = parent.fractions.map { rest > 0 ? $0 / rest : 1 / CGFloat(parent.fractions.count) }
        _ = removed
        if parent.children.count == 1 { replace(parent.id, with: parent.children[0]) }
        if activeGroupId == g.id { activeGroupId = groups.first?.id ?? activeGroupId }
    }

    private func parent(of id: UUID) -> (SplitBox, Int)? {
        func search(_ n: LayoutNode) -> (SplitBox, Int)? {
            guard case .split(let box) = n else { return nil }
            if let i = box.children.firstIndex(where: { $0.id == id }) { return (box, i) }
            for c in box.children { if let r = search(c) { return r } }
            return nil
        }
        return search(root)
    }

    private func replace(_ id: UUID, with node: LayoutNode) {
        if root.id == id { root = node; return }
        if let (parent, i) = parent(of: id) { parent.children[i] = node }
    }

    // MARK: Focus follows clicks

    /// Clicking into a group's terminal makes that group active (the terminal view eats the click otherwise).
    private func watchClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            for g in self.groups {
                guard let v = self.selectedTerminal(in: g)?.view, v.window === event.window else { continue }
                if v.bounds.contains(v.convert(event.locationInWindow, from: nil)) {
                    self.activate(g)
                    break
                }
            }
            return event
        }
    }
}

func pickFolder(prompt: String, startingAt: String? = nil) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = prompt
    if let s = startingAt { panel.directoryURL = URL(fileURLWithPath: s) }
    return panel.runModal() == .OK ? panel.url?.path : nil
}
