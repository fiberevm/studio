import SwiftUI

/// VS Code-style quick pick. ⌘P searches sessions (running first, then past) and commands;
/// a leading ">" (or ⇧⌘P) shows commands only. "Color Theme" opens a theme list with live preview.
struct CommandPalette: View {
    @EnvironmentObject var model: ProjectModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettingsWindow

    private func openSettings(section: String) {
        SettingsNav.pending = section
        openSettingsWindow()
        NotificationCenter.default.post(name: SettingsNav.show, object: section)
    }

    @State private var query: String
    @State private var index = 0
    @State private var mode: Mode = .main
    @State private var themeBeforePreview: AppTheme?
    @State private var keepIndexOnce = false
    @FocusState private var focused: Bool
    @StateObject private var keys = KeyMonitor()
    @State private var indexVersion = 0

    enum Mode { case main, themes, switcher }

    struct Item: Identifiable {
        enum Leading { case status(SessionStatus), icon(String), none }
        let id: String
        let title: String
        var subtitle: String = ""
        var detail: String = ""
        var leading: Leading = .none
        var section: String? = nil
        let run: () -> Void
        var preview: (() -> Void)? = nil
    }

    init(initial: String, switcher: Bool = false) {
        _query = State(initialValue: initial)
        _mode = State(initialValue: switcher ? .switcher : .main)
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(SwiftUI.Color(nsColor: Theme.background))
                .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.accent), lineWidth: 1))
                .padding(6)
                .focused($focused)
                .onChange(of: query) { _, _ in
                    if keepIndexOnce { keepIndexOnce = false; return }
                    index = 0
                    previewCurrent(results)
                }

            if items.isEmpty {
                Text("No matching results").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).frame(height: 26)
            } else {
                // Plain VStack (≤ 80 rows) with real identities: a LazyVStack keyed by position kept showing stale
                // rows when the list switched from sessions to themes. Rebuilt per mode for the same reason.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == index)
                                    .onTapGesture { index = i; activate(items) }
                            }
                        }
                    }
                    .frame(maxHeight: 26 * 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: index) { _, i in if i < items.count { proxy.scrollTo(items[i].id) } }
                }
                .id(mode)
            }
        }
        .padding(.bottom, 4)
        .frame(width: 620)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.border), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .onAppear {
            focused = true
            if model.store.history.isEmpty { model.store.loadHistory() }
            // The text field's editor swallows ↑/↓ before SwiftUI sees them, so catch keys at the window level.
            keys.start { e in
                let ctrl = e.modifierFlags.contains(.control)
                switch e.keyCode {
                case 125: move(1, results); return true                     // ↓
                case 126: move(-1, results); return true                    // ↑
                case 45 where ctrl: move(1, results); return true           // ⌃N
                case 35 where ctrl: move(-1, results); return true          // ⌃P
                case 121: move(10, results); return true                    // page down
                case 116: move(-10, results); return true                   // page up
                case 53: escape(); return true                              // esc
                case 36, 76: activate(results); return true                 // return / enter
                // (Return is handled here, not with onSubmit: the field also "submits" when it merely loses focus)
                default: return false
                }
            }
        }
        .onDisappear { keys.stop() }
        .onAppear { if mode == .switcher { _ = FileIndex.shared.files(in: model.folder) } }   // start indexing right away
        .onReceive(NotificationCenter.default.publisher(for: FileIndex.changed)) { n in
            if (n.object as? String) == model.folder { indexVersion += 1 }
        }
    }

    private var placeholder: String {
        switch mode {
        case .themes: return "Select Color Theme  ·  ↑↓ preview  ·  ⏎ keep  ·  esc back"
        case .switcher: return "Switch to a session or open a file in \(model.name)"
        case .main: return "Search sessions by name or project, or type > for commands"
        }
    }

    // MARK: Rows

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                switch item.leading {
                case .status(let s): StatusDot(status: s)
                case .icon(let name): Image(systemName: name).font(.system(size: 11)).foregroundStyle(.secondary)
                case .none: SwiftUI.Color.clear
                }
            }
            .frame(width: 14)
            Text(item.title).font(.system(size: 13)).lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let section = item.section {
                Text(section).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(selected ? SwiftUI.Color(nsColor: Theme.selection) : .clear, ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
    }

    // MARK: Results

    private var results: [Item] {
        switch mode {
        case .themes:
            return filter(themeItems, by: query)
        case .switcher:
            // sessions first, then files: recently opened ones before you type, the project's matches after
            let sessions = filter(switchItems, by: query)
            let files = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? model.recentFiles.map(fileItem)
                : FileIndex.search(FileIndex.shared.files(in: model.folder), query).map { fileItem(model.folder + "/" + $0) }
            var list = sessions
            for (i, f) in files.enumerated() {
                var f = f
                if i == 0 { f.section = query.isEmpty ? "recent files" : "files" }
                list.append(f)
            }
            _ = indexVersion   // re-run when the file index finishes building
            return list
        case .main:
            if query.hasPrefix(">") {
                return filter(commandItems, by: String(query.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
            if query.isEmpty { return Array(sessionItems.prefix(80)) }
            // Rank sessions and commands together: substring hits of either kind beat loose letter matches,
            // so "theme" finds Change Theme before a session that merely contains t…h…e…m…e.
            let pool = sessionItems.filter { $0.id != "cmd:theme-entry" } + commandItems
            return Array(filter(pool, by: query).prefix(80))
        }
    }

    private var sessionItems: [Item] {
        let store = model.store
        var out: [Item] = []
        var seen = Set<String>()
        // Running sessions everywhere, this project's first.
        let running = store.allActiveItems.sorted {
            let a = isInside($0.cwd, model.folder), b = isInside($1.cwd, model.folder)
            return a != b ? a : $0.updatedAt > $1.updatedAt
        }
        for item in running {
            guard let sid = item.sessionId else { continue }
            seen.insert(sid)
            out.append(Item(id: "run:\(sid)", title: item.title, subtitle: projectName(for: item.cwd),
                            detail: item.status.label, leading: .status(item.status),
                            section: out.isEmpty ? "running" : nil,
                            run: { open(sid: sid, cwd: item.cwd) }))
        }
        out.append(Item(id: "cmd:theme-entry", title: "Change Theme…", detail: Theme.current.name,
                        leading: .icon("paintpalette"), run: { enterThemes() }))
        var first = true
        for r in store.history where !seen.contains(r.id) {
            out.append(Item(id: "past:\(r.id)", title: r.displayTitle, subtitle: projectName(for: r.cwd),
                            detail: relativeTime(r.lastActivity), leading: .icon("clock.arrow.circlepath"),
                            section: first ? "recent" : nil,
                            run: { open(sid: r.id, cwd: r.cwd) }))
            first = false
        }
        return out
    }

    /// ⌘K: this project's running sessions, most recently active first, the one you're on last.
    /// Picking one focuses it here.
    private var switchItems: [Item] {
        let current = model.selectedSessionId
        let items = model.items.filter { $0.sessionId != nil }.sorted {
            if ($0.sessionId == current) != ($1.sessionId == current) { return $1.sessionId == current }
            return $0.updatedAt > $1.updatedAt
        }
        return items.map { item in
            let sid = item.sessionId!
            return Item(id: "sw:\(sid)", title: item.title, subtitle: projectName(for: item.cwd),
                        detail: item.status.label, leading: .status(item.status),
                        run: { open(sid: sid, cwd: item.cwd) })
        }
    }

    private func fileItem(_ path: String) -> Item {
        let rel = relativePath(path, to: model.folder)
        let dir = (rel as NSString).deletingLastPathComponent
        return Item(id: "file:\(path)", title: (path as NSString).lastPathComponent, subtitle: dir,
                    leading: .icon("doc.text"), run: { model.openFile(path) })
    }

    private var commandItems: [Item] {
        let m = model
        let s = model.store
        func cmd(_ title: String, _ key: String = "", _ icon: String, _ run: @escaping () -> Void) -> Item {
            Item(id: "cmd:\(title)", title: title, detail: key, leading: .icon(icon), run: run)
        }
        var list = [
            Item(id: "cmd:theme", title: "Change Theme…", subtitle: "Preferences: Color Theme", detail: Theme.current.name,
                 leading: .icon("paintpalette"), run: { enterThemes() }),
            cmd("Session: New Session", "⌘N", "plus") { m.newTab() },
            cmd("Session: New Claude Session", "", "sparkles") { m.select(m.store.newSession(in: m.folder, agent: .claude)) },
            cmd("Session: New Codex Session", "", "chevron.left.forwardslash.chevron.right") { m.select(m.store.newSession(in: m.folder, agent: .codex)) },
            cmd("Session: New Antigravity Session", "", "chevron.left.forwardslash.chevron.right") { m.select(m.store.newSession(in: m.folder, agent: .agy)) },
            cmd("Terminal: New Terminal", "⌃`", "terminal") { m.newShellTab() },
            cmd("Web: Open URL…", "", "globe") { m.openWeb(nil, zone: .center) },
            cmd("Session: Next Up (waiting for you)", "⌘J", "arrow.turn.down.right") { m.goToNextUp() },
            cmd("Session: Switch to Open Session…", "⌘K", "rectangle.stack") { m.paletteSwitcher = true; m.palette = "" },
            cmd("Session: Quick Prompt…", "⇧⌘K", "text.bubble") { m.quickPrompt = true },
            cmd("Session: Fork to the Right", "⌘E", "arrow.triangle.branch") { m.fork() },
            cmd("View: Toggle Native View (Studio rendering instead of the terminal UI)", "⌘/", "text.alignleft") { m.toggleNative() },
            cmd("Session: Close Tab", "⌘W", "xmark") { m.closeSelectedTab() },
            cmd("View: Next Tab", "⇧⌘]", "arrow.right") { m.cycleTab(1) },
            cmd("View: Previous Tab", "⇧⌘[", "arrow.left") { m.cycleTab(-1) },
            cmd("View: Bigger Text", "⌘+", "textformat.size.larger") { s.fontSize = min(s.fontSize + 1, 24) },
            cmd("View: Smaller Text", "⌘−", "textformat.size.smaller") { s.fontSize = max(s.fontSize - 1, 9) },
            cmd("View: Default Text Size", "⌘0", "textformat.size") { s.fontSize = 12 },
            cmd("Project: Open Project…", "⇧⌘N", "folder") {
                if let f = pickFolder(prompt: "Open") { openWindow(value: f) }
            },
            cmd("Project: Reveal in Finder", "", "folder.badge.gearshape") {
                NSWorkspace.shared.open(URL(fileURLWithPath: m.folder))
            },
        ]
        if let t = m.selectedTerminal {
            list.insert(cmd("Session: End Session", "", "stop.circle") { m.endSession(t) }, at: 3)
        }
        // Snippets go to the current session in one step; ⇧⌘K offers them for any session or a broadcast.
        if let t = m.selectedTerminal, t.isAgent {
            for sn in Snippets.all {
                list.append(Item(id: "snip:\(sn.name)", title: "Snippet: #\(sn.name)", subtitle: sn.text,
                                 leading: .icon("text.quote"), run: { t.submit(sn.text) }))
            }
        }
        list.append(cmd("Snippets: Edit…", "", "square.and.pencil") { NSWorkspace.shared.open(Snippets.file) })
        list.append(cmd("Help: Welcome to Studio", "", "sparkles") { openWindow(id: Onboarding.windowId) })
        // workers: start a session on one, or open one already running there that has no tab
        let reg = WorkerRegistry.shared
        for w in reg.workers where reg.isOnline(w.id) {
            list.append(cmd("Worker: New Session on \(w.name)", "", "server.rack") {
                Task { @MainActor in
                    do { _ = try await m.newWorkerSession(w) } catch { m.showToast(error.localizedDescription) }
                }
            })
            for ws in reg.sessions[w.id] ?? [] where ws.running
                && !s.terminals.contains(where: { $0.remote?.worker == w.id && $0.remote?.session == ws.id }) {
                list.append(Item(id: "worker:\(w.id):\(ws.id)", title: "Worker: \(w.name) · \(ws.title ?? ws.id)",
                                 subtitle: ws.cwd, leading: .icon("server.rack"), run: { m.openWorkerSession(w, ws) }))
            }
        }
        if reg.workers.isEmpty {
            list.append(cmd("Worker: Add a Worker…", "", "server.rack") { openSettings(section: "workers") })
        }
        for r in RecentProjects.list() where r != m.folder {
            list.append(cmd("Project: Open \(projectName(for: r))", "", "folder") { openWindow(value: r) })
        }
        return list
    }

    private var themeItems: [Item] {
        AppTheme.all.map { t in
            Item(id: "theme:\(t.id)", title: t.name, detail: t.id == (themeBeforePreview ?? Theme.current).id ? "current" : "",
                 leading: .icon(t.isLight ? "sun.max" : "moon"),
                 run: { model.store.setTheme(t); themeBeforePreview = nil },
                 preview: { model.store.setTheme(t, persist: false) })
        }
    }

    /// Case-insensitive match: substring hits rank above scattered-letter (subsequence) hits; order is kept within each.
    private func filter(_ items: [Item], by q: String) -> [Item] {
        let q = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        var exact: [Item] = [], fuzzy: [Item] = []
        for item in items {
            let hay = (item.title + " " + item.subtitle).lowercased()
            if hay.contains(q) { exact.append(item) }
            else if isSubsequence(q, of: hay) { fuzzy.append(item) }
        }
        return exact + fuzzy
    }

    private func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle where c != " " {
            var found = false
            while let h = it.next() { if h == c { found = true; break } }
            if !found { return false }
        }
        return true
    }

    // MARK: Actions

    private func move(_ d: Int, _ items: [Item]) {
        guard !items.isEmpty else { return }
        if abs(d) == 1 {
            index = (index + d + items.count) % items.count        // single steps wrap around
        } else {
            index = min(max(index + d, 0), items.count - 1)        // page jumps stop at the ends
        }
        items[index].preview?()
    }

    private func previewCurrent(_ items: [Item]) {
        if index < items.count { items[index].preview?() }
    }

    private func activate(_ items: [Item]) {
        guard index < items.count else { return }
        let item = items[index]
        debugLog("palette activate \(item.id) mode=\(mode) query=\(query)")
        if item.id == "cmd:theme" || item.id == "cmd:theme-entry" { item.run(); return }   // opens the theme step
        dismiss(cancel: false)
        item.run()
    }

    private func enterThemes() {
        themeBeforePreview = Theme.current
        mode = .themes
        keepIndexOnce = !query.isEmpty   // the query reset below shouldn't move the highlight
        query = ""
        index = AppTheme.all.firstIndex(of: Theme.current) ?? 0
    }

    /// Esc in the theme picker reverts the preview and steps back to the main list; otherwise it closes.
    private func escape() {
        guard mode == .themes else { dismiss(cancel: true); return }
        if let original = themeBeforePreview { model.store.setTheme(original, persist: false) }
        themeBeforePreview = nil
        mode = .main
        keepIndexOnce = !query.isEmpty
        query = ""
        index = 0
    }

    private func dismiss(cancel: Bool) {
        if cancel, let original = themeBeforePreview { model.store.setTheme(original, persist: false) }
        model.palette = nil
        model.focusTerminal()
    }

    /// Open a session: here if it belongs to this window's project, otherwise in its project's window.
    private func open(sid: String, cwd: String) {
        if isInside(cwd, model.folder) {
            model.open(sessionId: sid)
        } else {
            let root = projectRoot(cwd)
            model.store.requestFocus(sessionId: sid, in: root)
            openWindow(value: root)
        }
    }
}

/// Local key-down monitor that lives while the palette is open; the handler returns true to swallow the event.
final class KeyMonitor: ObservableObject {
    private var monitor: Any?

    func start(_ handler: @escaping (NSEvent) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in handler(e) ? nil : e }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { stop() }
}
