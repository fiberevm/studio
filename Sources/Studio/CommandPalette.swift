import SwiftUI

/// VS Code-style quick pick. ⌘P searches sessions (running first, then past) and commands;
/// a leading ">" (or ⇧⌘P) shows commands only. "Color Theme" opens a theme list with live preview.
struct CommandPalette: View {
    @EnvironmentObject var model: ProjectModel
    @Environment(\.openWindow) private var openWindow

    @State private var query: String
    @State private var index = 0
    @State private var mode: Mode = .main
    @State private var themeBeforePreview: AppTheme?
    @State private var keepIndexOnce = false
    @FocusState private var focused: Bool

    enum Mode { case main, themes }

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

    init(initial: String) { _query = State(initialValue: initial) }

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
                .onSubmit { activate(items) }
                .onKeyPress(.downArrow) { move(1, items); return .handled }
                .onKeyPress(.upArrow) { move(-1, items); return .handled }
                .onKeyPress(.escape) { dismiss(cancel: true); return .handled }
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == index)
                                    .id(i)
                                    .onTapGesture { index = i; activate(items) }
                            }
                        }
                    }
                    .frame(maxHeight: 26 * 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: index) { _, i in proxy.scrollTo(i) }
                }
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
        }
    }

    private var placeholder: String {
        switch mode {
        case .themes: return "Select Color Theme (↑↓ to preview)"
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
        case .main:
            if query.hasPrefix(">") {
                return filter(commandItems, by: String(query.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
            let sessions = filter(sessionItems, by: query)
            let cmds = query.isEmpty ? [] : filter(commandItems, by: query)
            return Array(sessions.prefix(60)) + cmds
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

    private var commandItems: [Item] {
        let m = model
        let s = model.store
        func cmd(_ title: String, _ key: String = "", _ icon: String, _ run: @escaping () -> Void) -> Item {
            Item(id: "cmd:\(title)", title: title, detail: key, leading: .icon(icon), run: run)
        }
        var list = [
            Item(id: "cmd:theme", title: "Preferences: Color Theme", detail: Theme.current.name,
                 leading: .icon("paintpalette"), run: { enterThemes() }),
            cmd("Session: New Session", "⌘N", "plus") { m.newTab() },
            cmd("Terminal: New Terminal", "⌃`", "terminal") { m.newShellTab() },
            cmd("Session: Close Tab", "⌘W", "xmark") { m.closeSelectedTab() },
            cmd("View: Next Tab", "⌘]", "arrow.right") { m.cycleTab(1) },
            cmd("View: Previous Tab", "⌘[", "arrow.left") { m.cycleTab(-1) },
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
        index = (index + d + items.count) % items.count
        items[index].preview?()
    }

    private func previewCurrent(_ items: [Item]) {
        if index < items.count { items[index].preview?() }
    }

    private func activate(_ items: [Item]) {
        guard index < items.count else { return }
        let item = items[index]
        if item.id == "cmd:theme" { item.run(); return }   // switches mode, palette stays open
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
