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
        RecentProjects.add(folder)
        // Re-render this window whenever global session state changes.
        store.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            DispatchQueue.main.async { self?.consumePendingFocus() }
        }.store(in: &bag)
        let restored = store.restoreTerminals(in: folder)
        first.tabIds = restored.map(\.id)
        first.selection = restored.first.map { "t:\($0.id)" }
        consumePendingFocus()   // opened from another window's palette
        watchClicks()
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

    func focusTerminal() {
        guard let v = selectedTerminal?.view else { return }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }

    func newTab() { select(store.newSession(in: folder)) }

    func newShellTab() { select(store.newShell(in: folder)) }

    func resume(_ sid: String) { select(store.resume(sid)) }

    func select(_ t: TerminalSession) { selection = "t:\(t.id)" }

    func select(_ t: TerminalSession, in g: GroupNode) {
        activeGroupId = g.id
        g.selection = "t:\(t.id)"
        changed()
        focusTerminal()
    }

    /// Close the tab only; the session keeps running and stays in the sidebar.
    /// A plain terminal has nowhere else to live, so closing its tab ends it.
    func close(_ t: TerminalSession) {
        guard let g = group(containing: t.id) else { return }
        detach(t.id, from: g)
        if g.tabIds.isEmpty, groups.count > 1 { remove(g) }
        if t.isShell { store.close(t) }
        changed()
    }

    /// Stop the claude process for good (it can still be resumed later with `claude --resume`).
    func endSession(_ t: TerminalSession) {
        close(t)
        if !t.isShell { store.close(t) }   // close() already ended a shell
    }

    func closeSelectedTab() { if let t = selectedTerminal { close(t) } }

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
        store.endViewing(window: windowId)
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

    func resize(_ box: SplitBox, fractions: [CGFloat]) {
        box.fractions = fractions
        objectWillChange.send()
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
