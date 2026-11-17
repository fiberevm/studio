import AppKit
import Combine

/// State for one project window: which folder it's scoped to and what's selected.
/// Selection keys: "t:<terminal uuid>" for an in-app tab, "s:<session id>" for a session running elsewhere.
@MainActor
final class ProjectModel: ObservableObject {
    let windowId = UUID()
    let folder: String
    let store: SessionStore
    @Published var selection: String? {
        didSet {
            // Selecting an in-app session from the sidebar reopens its tab.
            if let sel = selection, sel.hasPrefix("t:"), let t = store.terminals.first(where: { "t:\($0.id)" == sel }),
               !tabIds.contains(t.id) {
                tabIds.append(t.id)
            }
            store.setViewing(window: windowId, sessionId: selectedSessionId)
        }
    }
    /// Tabs are just quick access: closing one hides it, the claude process keeps running.
    @Published private(set) var tabIds: [UUID] = []
    private var bag: Set<AnyCancellable> = []

    init(folder: String, store: SessionStore) {
        self.folder = folder
        self.store = store
        RecentProjects.add(folder)
        // Re-render this window whenever global session state changes.
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        let restored = store.restoreTerminals(in: folder)
        tabIds = restored.map(\.id)
        selection = restored.first.map { "t:\($0.id)" }
    }

    var name: String { projectName(for: folder) }
    var tabs: [TerminalSession] {
        let all = store.terminals(in: folder)
        return tabIds.compactMap { id in all.first { $0.id == id } }
    }
    var items: [ActiveItem] { store.activeItems(in: folder) }

    var selectedTerminal: TerminalSession? {
        guard let sel = selection, sel.hasPrefix("t:") else { return nil }
        return store.terminals.first { "t:\($0.id)" == sel }
    }

    var selectedSessionId: String? {
        guard let sel = selection else { return nil }
        if sel.hasPrefix("s:") { return String(sel.dropFirst(2)) }
        return selectedTerminal?.sessionId
    }

    func item(for t: TerminalSession) -> ActiveItem? { store.allActiveItems.first { $0.key == "t:\(t.id)" } }

    // MARK: Actions

    func newTab() { select(store.newSession(in: folder)) }

    func resume(_ sid: String) { select(store.resume(sid)) }

    func select(_ t: TerminalSession) { selection = "t:\(t.id)" }

    /// Close the tab only; the session keeps running and stays in the sidebar.
    func close(_ t: TerminalSession) {
        let idx = tabIds.firstIndex(of: t.id) ?? 0
        let wasSelected = selection == "t:\(t.id)"
        tabIds.removeAll { $0 == t.id }
        if wasSelected {
            let rest = tabs
            selection = rest.isEmpty ? nil : "t:\(rest[min(idx, rest.count - 1)].id)"
        }
    }

    /// Stop the claude process for good (it can still be resumed later with `claude --resume`).
    func endSession(_ t: TerminalSession) {
        close(t)
        store.close(t)
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

    func windowClosed() { store.endViewing(window: windowId) }
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
