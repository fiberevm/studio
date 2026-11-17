import SwiftUI
import SwiftTerm

struct ContentView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 480)
        } detail: {
            DetailPane()
        }
        .task { store.handleLaunchArguments() }
        .navigationTitle(windowTitle)
        .toolbar {
            ToolbarItem {
                Button { store.newSessionPickingFolder() } label: { Label("New Session", systemImage: "plus") }
                    .help("New Claude session (⌘N)")
            }
        }
    }

    private var windowTitle: String {
        if let sid = store.selectedSessionId, let item = store.activeItems.first(where: { $0.sessionId == sid }) {
            return item.title
        }
        if let sid = store.selectedSessionId, let r = store.records[sid] { return r.displayTitle }
        return "AICode"
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: SessionStore
    @State private var expanded: Set<String> = []
    @State private var showAllHistory = false

    var body: some View {
        let active = store.activeItems
        let groups = store.historyGroups
        List(selection: $store.selection) {
            Section("Active · \(active.count)") {
                if active.isEmpty {
                    Text("No running sessions").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(active) { item in
                    ActiveRow(item: item, attention: item.sessionId.map(store.attention.contains) ?? false)
                        .tag(item.key)
                        .contextMenu { activeMenu(item) }
                }
            }
            Section("History") {
                if !store.loaded { ProgressView().controlSize(.small) }
                ForEach(groups) { g in
                    DisclosureGroup(isExpanded: binding(for: g.project)) {
                        ForEach(g.sessions.prefix(showAllHistory || !store.search.isEmpty ? 500 : 15)) { r in
                            HistoryRow(record: r)
                                .tag("s:\(r.id)")
                                .contextMenu { historyMenu(r) }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(g.project).lineLimit(1)
                            Spacer()
                            Text("\(g.sessions.count)").foregroundStyle(.tertiary).font(.caption).monospacedDigit()
                        }
                        .contextMenu {
                            Button("New Session in \(g.project)") { store.newSession(in: g.cwd) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $store.search, placement: .sidebar, prompt: "Filter sessions")
        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { keys in
            // double-click / Return on a history row resumes it
            if let k = keys.first, k.hasPrefix("s:") { store.resume(String(k.dropFirst(2))) }
        }
        .onChange(of: store.search) { _, q in
            if !q.isEmpty { expanded = Set(groups.map(\.project)) }
        }
        .onChange(of: store.loaded) { _, loaded in
            if loaded, let first = store.historyGroups.first { expanded.insert(first.project) }
        }
        .safeAreaInset(edge: .bottom) {
            Toggle("Show scratch/tmp sessions", isOn: $store.showTempSessions)
                .toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
    }

    private func binding(for project: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(project) },
                set: { if $0 { expanded.insert(project) } else { expanded.remove(project) } })
    }

    @ViewBuilder private func activeMenu(_ item: ActiveItem) -> some View {
        if let t = store.terminals.first(where: { "t:\($0.id)" == item.key || ($0.sessionId != nil && $0.sessionId == item.sessionId) }) {
            if !t.running { Button("Restart") { t.restart() } }
            Button("Close Terminal") { store.close(t) }
        } else if let sid = item.sessionId {
            Button("Resume Here") { store.resume(sid) }
            if let pid = item.pid {
                Button("Stop External Process (pid \(pid))") { store.stopExternal(pid: pid) }
            }
        }
        Divider()
        Button("New Session in Same Folder") { store.newSession(in: item.cwd) }
        Button("Reveal Folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: item.cwd)) }
        if let sid = item.sessionId {
            Button("Copy Session ID") { copy(sid) }
            Button("Copy Resume Command") { copy("cd \(shellQuote(item.cwd)) && claude --resume \(sid)") }
        }
    }

    @ViewBuilder private func historyMenu(_ r: SessionRecord) -> some View {
        Button("Resume") { store.resume(r.id) }
        Button("New Session in Same Folder") { store.newSession(in: r.cwd) }
        Divider()
        Button("Reveal Transcript in Finder") { store.revealTranscript(r.id) }
        Button("Copy Session ID") { copy(r.id) }
        Button("Copy Resume Command") { copy("cd \(shellQuote(r.cwd)) && claude --resume \(r.id)") }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct StatusDot: View {
    let status: SessionStatus
    var body: some View {
        Group {
            switch status {
            case .working, .starting:
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            default:
                Circle().fill(color).frame(width: 8, height: 8)
            }
        }
        .frame(width: 12)
        .help(status.label)
    }
    var color: SwiftUI.Color {
        switch status {
        case .idle: return .green
        case .waiting: return .yellow
        case .shell: return .blue
        case .exited: return .gray
        case .inactive: return .gray.opacity(0.4)
        default: return .orange
        }
    }
}

struct ActiveRow: View {
    let item: ActiveItem
    let attention: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(status: item.status).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title).lineLimit(1).fontWeight(attention ? .semibold : .regular)
                    if attention { Circle().fill(SwiftUI.Color.accentColor).frame(width: 6, height: 6) }
                }
                HStack(spacing: 4) {
                    Text(item.status.label).foregroundStyle(statusColor)
                    Text("·")
                    Text(projectName(for: item.cwd)).lineLimit(1)
                    Spacer(minLength: 4)
                    if !item.inApp {
                        Text(externalLabel).padding(.horizontal, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                            .help("Running outside AICode (pid \(item.pid ?? 0))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var externalLabel: String {
        switch item.entrypoint {
        case "claude-desktop": return "desktop"
        case "cli": return "terminal"
        case let e?: return e
        default: return "external"
        }
    }

    private var statusColor: SwiftUI.Color {
        switch item.status {
        case .working: return .orange
        case .waiting: return .yellow
        default: return .secondary
        }
    }
}

struct HistoryRow: View {
    let record: SessionRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.displayTitle).lineLimit(1)
            HStack {
                Text(record.lastPrompt ?? "").lineLimit(1)
                Spacer(minLength: 4)
                Text(relativeTime(record.lastActivity)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .help(record.firstPrompt ?? record.displayTitle)
    }
}

// MARK: - Detail

struct DetailPane: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        if let t = store.selectedTerminal {
            TerminalPane(terminal: t).id(t.id)
        } else if let sid = store.selectedSessionId {
            SessionInfoPane(sid: sid)
        } else {
            EmptyPane()
        }
    }
}

struct TerminalPane: View {
    @ObservedObject var terminal: TerminalSession
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                TerminalHost(view: terminal.view)
                if !terminal.running {
                    VStack(spacing: 10) {
                        Text("Claude exited\(terminal.exitCode.map { " (code \($0))" } ?? "")")
                            .font(.headline)
                        HStack {
                            Button("Restart") { terminal.restart() }.keyboardShortcut(.defaultAction)
                            Button("Close") { store.close(terminal) }
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .background(SwiftUI.Color(nsColor: terminal.view.nativeBackgroundColor))
    }

    private var header: some View {
        let item = store.activeItems.first { $0.sessionId == terminal.sessionId && terminal.sessionId != nil }
        return HStack(spacing: 8) {
            StatusDot(status: item?.status ?? (terminal.running ? .starting : .exited))
            Text(abbreviatePath(terminal.cwd)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            if let sid = terminal.sessionId {
                Text(sid.prefix(8)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    .help(sid).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(SwiftUI.Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Hosts a long-lived SwiftTerm view inside SwiftUI without recreating it.
struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first !== view { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { [view] in view.window?.makeFirstResponder(view) }
    }
}

struct SessionInfoPane: View {
    let sid: String
    @EnvironmentObject var store: SessionStore

    var body: some View {
        let rec = store.records[sid]
        let info = store.live[sid]
        VStack(alignment: .leading, spacing: 14) {
            Text(rec?.displayTitle ?? info?.name ?? "Session").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { label("Folder"); Text(abbreviatePath(rec?.cwd ?? info?.cwd ?? "")).textSelection(.enabled) }
                GridRow { label("Session"); Text(sid).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                if let r = rec { GridRow { label("Last active"); Text(r.lastActivity.formatted(date: .abbreviated, time: .shortened)) } }
                if let p = rec?.firstPrompt { GridRow { label("First prompt"); Text(p).lineLimit(3) } }
                if let p = rec?.lastPrompt, p != rec?.firstPrompt { GridRow { label("Last prompt"); Text(p).lineLimit(3) } }
            }
            .font(.callout)

            if let info {
                VStack(alignment: .leading, spacing: 8) {
                    Label("This session is running elsewhere (\(info.entrypoint ?? "external"), pid \(info.pid)) — \(SessionStatus(raw: info.status).label.lowercased()).",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Resuming it here while it's still running would give two processes writing to the same conversation. Stop the other one first, or open it anyway.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Stop External & Resume Here") {
                            store.stopExternal(pid: info.pid)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { store.resume(sid) }
                        }
                        .keyboardShortcut(.defaultAction)
                        Button("Resume Here Anyway") { store.resume(sid) }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack {
                    Button { store.resume(sid) } label: { Label("Resume Session", systemImage: "play.fill") }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                    Button("New Session in Same Folder") { store.newSession(in: rec?.cwd ?? NSHomeDirectory()) }
                        .controlSize(.large)
                }
                Text("Tip: double-click a session in the sidebar to resume it directly.").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

struct EmptyPane: View {
    @EnvironmentObject var store: SessionStore
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("Select a session, or start a new one").foregroundStyle(.secondary)
            Button("New Session…") { store.newSessionPickingFolder() }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
