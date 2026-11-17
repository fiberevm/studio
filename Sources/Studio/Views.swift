import SwiftUI
import SwiftTerm

private let topBarHeight: CGFloat = 35
private let sidebarWidth: CGFloat = 250

// MARK: - Window root

/// Each window is bound to one project folder (the scene value). With no folder yet, show a picker.
struct ProjectWindow: View {
    @Binding var folder: String?
    @EnvironmentObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let folder {
                ProjectView(folder: folder, store: store).id(folder)
            } else {
                ProjectPicker(folder: $folder)
            }
        }
        .background(SwiftUI.Color(nsColor: Theme.chrome).ignoresSafeArea())
        .background(WindowConfigurator())
        .modifier(HideTitlebarBackground())
        .ignoresSafeArea()
        .preferredColorScheme(Theme.current.isLight ? .light : .dark)
        .navigationTitle(folder.map { projectName(for: $0) } ?? "Studio")
        .onAppear(perform: handleLaunchArguments)
    }

    /// `Studio --new <dir>` opens a window on dir with a fresh session; `--resume <id>` resumes into its project.
    private func handleLaunchArguments() {
        guard folder == nil, !LaunchArgs.consumed else { return }
        LaunchArgs.consumed = true
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--new"), i + 1 < args.count {
            LaunchArgs.pendingNewSession = true
            folder = args[i + 1]
        } else if let i = args.firstIndex(of: "--resume"), i + 1 < args.count {
            let sid = args[i + 1]
            LaunchArgs.pendingResume = sid
            folder = projectRoot(store.records[sid]?.cwd ?? store.live[sid]?.cwd ?? NSHomeDirectory())
        } else if !args.contains("--no-restore") {
            // Fresh launch: reopen a window for every project that had tabs open last time.
            let projects = store.savedProjectFolders
            if let first = projects.first {
                folder = first
                for p in projects.dropFirst() { openWindow(value: p) }
            }
        }
    }
}

@MainActor enum LaunchArgs {
    static var consumed = false
    static var pendingNewSession = false
    static var pendingResume: String?
}

struct ProjectView: View {
    @StateObject private var model: ProjectModel

    init(folder: String, store: SessionStore) {
        _model = StateObject(wrappedValue: ProjectModel(folder: folder, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: model.name, subtitle: abbreviatePath(model.folder))
            Hairline()
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: sidebarWidth)
                Hairline(vertical: true)
                LayoutView(node: model.root)
            }
        }
        .overlay(alignment: .top) {
            if let initial = model.palette {
                ZStack(alignment: .top) {
                    // click outside closes it
                    SwiftUI.Color.black.opacity(0.001)
                        .onTapGesture { model.palette = nil; model.focusTerminal() }
                    CommandPalette(initial: initial)
                        .padding(.top, 34)
                }
            }
        }
        .environmentObject(model)
        .focusedSceneObject(model)
        .onAppear {
            if LaunchArgs.pendingNewSession { LaunchArgs.pendingNewSession = false; model.newTab() }
            if let sid = LaunchArgs.pendingResume { LaunchArgs.pendingResume = nil; model.resume(sid) }
            // debug/screenshot aid: split the last tab off to the right
            if CommandLine.arguments.contains("--split-demo"), let t = model.tabs.last, model.tabs.count > 1 {
                model.move(t.id, to: model.activeGroup, zone: .right)
            }
            // debug/screenshot aid: open the palette on launch
            if let i = CommandLine.arguments.firstIndex(of: "--open-palette") {
                model.palette = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
            }
        }
        .onDisappear { model.windowClosed() }
    }
}

// MARK: - Project picker

struct ProjectPicker: View {
    @Binding var folder: String?
    @EnvironmentObject var store: SessionStore

    var body: some View {
        let running = store.runningProjects
        let recents = RecentProjects.list().filter { r in !running.contains { $0.folder == r } }
        VStack(alignment: .leading, spacing: 18) {
            Text("Open a project").font(.title2.weight(.semibold))
            if !running.isEmpty {
                section("With running sessions") {
                    ForEach(running, id: \.folder) { p in row(p.folder, trailing: "\(p.count) running") }
                }
            }
            if !recents.isEmpty {
                section("Recent") {
                    ForEach(recents, id: \.self) { row($0, trailing: nil) }
                }
            }
            Button("Open Folder…") { if let f = pickFolder(prompt: "Open") { folder = f } }
                .keyboardShortcut("o")
            Spacer()
        }
        .padding(.horizontal, 40).padding(.top, 56)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.bottom, 2)
            content()
        }
    }

    private func row(_ path: String, trailing: String?) -> some View {
        Button { folder = path } label: {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(projectName(for: path)).fontWeight(.medium)
                Text(abbreviatePath(path)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(SwiftUI.Color.primary.opacity(0.04))
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: ProjectModel
    @AppStorage("busyExpanded") private var busyExpanded = false

    var body: some View {
        let items = model.items
        // Working, or running a ! shell command, counts as busy.
        let isBusy: (ActiveItem) -> Bool = { $0.status == .working || $0.status == .shell }
        let busy = items.filter(isBusy)
        let rest = items.filter { !isBusy($0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.name.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button { model.newTab() } label: {
                    Image(systemName: "plus").font(.system(size: 12)).frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("New session in \(model.name) (⌘N)")
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 30)
            .help(abbreviatePath(model.folder))

            sectionHeader("Waiting for you", count: rest.count)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rest) { row($0) }
                }
            }
            .overlay {
                if items.isEmpty {
                    Text("No sessions running here").font(.callout).foregroundStyle(.secondary)
                } else if rest.isEmpty {
                    Text("Everything is busy").font(.callout).foregroundStyle(.tertiary)
                }
            }

            busyDrawer(busy)   // always shown, even at 0
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .padding(.horizontal, 5)
                .background(SwiftUI.Color.primary.opacity(0.12))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 24)
    }

    private func row(_ item: ActiveItem) -> some View {
        SessionRow(item: item,
                   attention: item.sessionId.map(model.store.attention.contains) ?? false,
                   selected: model.selection == item.key,
                   prs: item.sessionId.flatMap { model.store.prs[$0] } ?? [])
            .onTapGesture { model.selection = item.key }
            .onDrag {
                // in-app sessions can be dragged from the sidebar into a split, like tabs
                if item.key.hasPrefix("t:"), let t = model.store.terminals.first(where: { "t:\($0.id)" == item.key }) {
                    return TabDrag.provider(t)
                }
                return NSItemProvider()
            }
            .contextMenu { menu(item) }
    }

    /// Sessions that are working right now, tucked into a collapsible drawer pinned to the bottom.
    /// Busy sessions (working or in a shell command). The header stays pinned at the bottom, level with the
    /// session status bar; expanding opens the list upward.
    private func busyDrawer(_ busy: [ActiveItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            if busyExpanded && !busy.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(busy) { row($0) }
                    }
                }
                .frame(maxHeight: 28 * 8)
                .fixedSize(horizontal: false, vertical: true)
                Hairline()
            }
            Button { busyExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: busyExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text("BUSY").font(.system(size: 11, weight: .semibold))
                    Text("\(busy.count)")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 5)
                        .background(SwiftUI.Color.primary.opacity(0.12))
                    Spacer()
                    if !busy.isEmpty { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(SwiftUI.Color(nsColor: Theme.chrome), ignoresSafeAreaEdges: [])
        }
    }

    @ViewBuilder private func menu(_ item: ActiveItem) -> some View {
        if let t = model.store.terminals.first(where: { "t:\($0.id)" == item.key }) {
            if !t.running { Button("Restart") { t.restart() } }
            if model.isOpen(t) { Button("Close Tab") { model.close(t) } }
            Button("End Session") { model.endSession(t) }
        } else if let sid = item.sessionId {
            Button("Open as Tab") { model.resume(sid) }
            if let pid = item.pid {
                Button("Stop External Process (pid \(pid))") { model.store.stopExternal(pid: pid) }
            }
        }
        Divider()
        Button("Reveal Folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: item.cwd)) }
        if let sid = item.sessionId {
            Button("Copy Session ID") { copy(sid) }
            Button("Copy Resume Command") { copy("cd \(shellQuote(item.cwd)) && claude --resume \(sid)") }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// One 28px line: title on the left, status dot on the right. Unread (finished while you were away) shows bold.
struct SessionRow: View {
    let item: ActiveItem
    let attention: Bool
    let selected: Bool
    var prs: [PRInfo] = []
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(item.title)
                .font(.system(size: 13, weight: attention ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // an open PR matters more than the newest one
            if let pr = prs.last(where: { $0.state == .open || $0.state == .draft }) ?? prs.last {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pr.state.color)
                    .help("PR #\(pr.number) \(pr.state.rawValue): \(pr.title)")
            }
            StatusDot(status: item.status)
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: 28)
        .background(selected ? SwiftUI.Color(nsColor: Theme.selection) : (hovering ? SwiftUI.Color.primary.opacity(0.04) : .clear),
                    ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(item.title)\n\(item.status.label) · \(abbreviatePath(item.cwd))\(item.inApp ? "" : "\nRunning outside Studio (pid \(item.pid ?? 0))")")
    }
}

struct StatusDot: View {
    let status: SessionStatus
    var body: some View {
        Group {
            switch status {
            case .working, .starting:
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            default:
                Circle().fill(color).frame(width: 7, height: 7)
            }
        }
        .frame(width: 12, height: 12)
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

/// 1px divider in the chrome border color.
struct Hairline: View {
    var vertical = false
    var body: some View {
        SwiftUI.Color(nsColor: Theme.border)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// MARK: - Title bar

/// Full-width title bar holding the traffic lights, with the project name centered (like VS Code).
struct TitleBar: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("—").foregroundStyle(.tertiary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        }
        .allowsHitTesting(false)    // let clicks fall through to the drag area
        .padding(.horizontal, 90)   // clear the traffic lights on the left
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(WindowDragArea())
    }
}

// MARK: - Split layout

/// Renders the layout tree: groups, and splits with draggable dividers between them.
struct LayoutView: View {
    let node: LayoutNode

    var body: some View {
        switch node {
        case .group(let g): GroupView(group: g)
        case .split(let box): SplitBoxView(box: box)
        }
    }
}

struct SplitBoxView: View {
    let box: SplitBox
    @EnvironmentObject var model: ProjectModel
    @State private var dragStart: [CGFloat]?

    var body: some View {
        GeometryReader { geo in
            let horizontal = box.axis == .horizontal
            let total = horizontal ? geo.size.width : geo.size.height
            let avail = max(total - CGFloat(box.children.count - 1), 1)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(box.children.enumerated()), id: \.element.id) { i, child in
                    LayoutView(node: child)
                        .frame(width: horizontal ? avail * box.fractions[i] : nil,
                               height: horizontal ? nil : avail * box.fractions[i])
                    if i < box.children.count - 1 {
                        divider(after: i, avail: avail, horizontal: horizontal)
                    }
                }
            }
        }
    }

    /// 1px line with a wider invisible grab area; dragging moves space between the two neighbours.
    private func divider(after i: Int, avail: CGFloat, horizontal: Bool) -> some View {
        Hairline(vertical: horizontal)
            .overlay(
                SwiftUI.Color.clear
                    .frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                        else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let start = dragStart ?? box.fractions
                            if dragStart == nil { dragStart = start }
                            let delta = (horizontal ? v.translation.width : v.translation.height) / avail
                            let minF: CGFloat = 0.08
                            let pair = start[i] + start[i + 1]
                            let a = min(max(start[i] + delta, minF), pair - minF)
                            var f = start
                            f[i] = a
                            f[i + 1] = pair - a
                            model.resize(box, fractions: f)
                        }
                        .onEnded { _ in dragStart = nil })
            )
            .zIndex(1)
    }
}

/// One editor group: its own tab strip, pane and status bar. Accepts dropped tabs with VS Code-style snap zones.
struct GroupView: View {
    let group: GroupNode
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(group: group)
                .frame(height: topBarHeight)
                .onDrop(of: [.text], delegate: TabDropDelegate(group: group, model: model, fixedZone: .center))
            Hairline()
            GeometryReader { geo in
                GroupPane(group: group)
                    .overlay(alignment: .topLeading) {
                        if let t = model.dropTarget, t.group == group.id { dropPreview(t.zone, size: geo.size) }
                    }
                    .onDrop(of: [.text], delegate: TabDropDelegate(group: group, model: model, size: geo.size))
            }
        }
    }

    /// Shaded area showing where the tab will land.
    private func dropPreview(_ z: DropZone, size: CGSize) -> some View {
        let w = size.width, h = size.height
        let rect: CGRect
        switch z {
        case .center: rect = CGRect(x: 0, y: 0, width: w, height: h)
        case .left: rect = CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .right: rect = CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .top: rect = CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottom: rect = CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        }
        return SwiftUI.Color(nsColor: Theme.accent).opacity(0.18)
            .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.accent).opacity(0.6), lineWidth: 1))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.1), value: z)
    }
}

/// Drag payload for a tab: "studio-tab:<terminal uuid>".
enum TabDrag {
    static let prefix = "studio-tab:"
    static func provider(_ t: TerminalSession) -> NSItemProvider { NSItemProvider(object: (prefix + t.id.uuidString) as NSString) }
}

struct TabDropDelegate: DropDelegate {
    let group: GroupNode
    let model: ProjectModel
    var size: CGSize = .zero
    var fixedZone: DropZone? = nil

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // the tab strip (fixedZone) drops into the group, so it previews the whole pane too
        model.setDropTarget(group, fixedZone ?? DropZone.at(info.location, in: size))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { model.clearDropTarget(group) }

    func performDrop(info: DropInfo) -> Bool {
        let target = fixedZone ?? DropZone.at(info.location, in: size)
        model.clearDropTarget()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String, str.hasPrefix(TabDrag.prefix),
                  let id = UUID(uuidString: String(str.dropFirst(TabDrag.prefix.count))) else { return }
            DispatchQueue.main.async { model.move(id, to: group, zone: target) }
        }
        return true
    }
}

// MARK: - Tabs

struct TabStrip: View {
    let group: GroupNode
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        let active = model.activeGroupId == group.id
        HStack(spacing: 0) {
            ForEach(model.tabs(in: group)) { t in
                TabButton(terminal: t, group: group, item: model.item(for: t),
                          selected: group.selection == "t:\(t.id)", groupActive: active,
                          attention: t.sessionId.map(model.store.attention.contains) ?? false)
                Hairline(vertical: true)
            }
            Button { model.activate(group); model.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 12)).frame(width: 30, height: topBarHeight)
            }
            .buttonStyle(.borderless)
            .help("New tab (⌘N)")
            SwiftUI.Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).background(WindowDragArea())
        }
    }
}

/// VS Code-style tab: square, full height; the selected tab takes the editor color, with an accent line in the active group.
struct TabButton: View {
    @ObservedObject var terminal: TerminalSession
    let group: GroupNode
    let item: ActiveItem?
    let selected: Bool
    let groupActive: Bool
    let attention: Bool
    @EnvironmentObject var model: ProjectModel
    @State private var hovering = false

    private var tabTitle: String {
        let t = item?.title ?? "New session"
        return t.count > 28 ? String(t.prefix(27)) + "…" : t
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: item?.status ?? (terminal.running ? .starting : .exited))
            Text(tabTitle)
                .font(.system(size: 12))
                .foregroundStyle(selected && groupActive ? .primary : .secondary)
                .lineLimit(1)
            Button { model.close(terminal) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close tab — session keeps running (⌘W)")
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: topBarHeight)
        .background(selected ? SwiftUI.Color(nsColor: Theme.background) : (hovering ? SwiftUI.Color.primary.opacity(0.03) : .clear),
                    ignoresSafeAreaEdges: [])
        .overlay(alignment: .top) {
            if selected && groupActive { SwiftUI.Color(nsColor: Theme.accent).frame(height: 1) }
        }
        // the selected tab merges into the pane below it
        .overlay(alignment: .bottom) {
            if selected { SwiftUI.Color(nsColor: Theme.background).frame(height: 1).offset(y: 1) }
        }
        .zIndex(selected ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { model.select(terminal, in: group) }
        .onHover { hovering = $0 }
        .onDrag { TabDrag.provider(terminal) }
        .contextMenu {
            Button("Split Right") { model.split(terminal, .right) }
            Button("Split Left") { model.split(terminal, .left) }
            Button("Split Down") { model.split(terminal, .bottom) }
            Button("Split Up") { model.split(terminal, .top) }
            Divider()
            Button("Close Tab") { model.close(terminal) }
            Button("End Session") { model.endSession(terminal) }
        }
        .help(abbreviatePath(terminal.cwd))
    }
}

// MARK: - Detail

/// What a group shows below its tabs: the selected session's terminal, an info pane, or the empty state.
struct GroupPane: View {
    let group: GroupNode
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        ZStack {
            SwiftUI.Color(nsColor: Theme.background)
            if let t = model.selectedTerminal(in: group) {
                TerminalPane(terminal: t).id(t.id)
            } else if let sel = group.selection, sel.hasPrefix("s:") {
                SessionInfoPane(sid: String(sel.dropFirst(2)))
            } else {
                EmptyPane()
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.activate(group) })
    }
}

/// Bottom strip under a session: branch, model, tokens sent/received, PRs. Icons only; hover for labels.
struct SessionStatusBar: View {
    @ObservedObject var terminal: TerminalSession
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        let sid = terminal.sessionId
        let st = sid.flatMap { model.store.stats[$0] }
        HStack(spacing: 14) {
            if let b = st?.gitBranch { stat("arrow.triangle.branch", b, help: "Git branch") }
            if let m = st?.model { stat("cpu", prettyModel(m), help: "Model: \(m)") }
            if let st {
                stat("arrow.up", formatTokens(st.tokensIn), help: "Tokens sent: \(st.tokensIn.formatted()) (incl. cache)")
                stat("arrow.down", formatTokens(st.tokensOut), help: "Tokens received: \(st.tokensOut.formatted())")
            }
            ForEach(sid.flatMap { model.store.prs[$0] } ?? []) { PRChip(pr: $0) }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(SwiftUI.Color(nsColor: Theme.chrome), ignoresSafeAreaEdges: [])
    }

    private func stat(_ icon: String, _ value: String, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(value).font(.system(size: 11)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// "⤴ #1115 ✓" — PR number tinted by state, plus CI result. Click opens it in the browser.
struct PRChip: View {
    let pr: PRInfo

    var body: some View {
        Button { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pr.state.color)
                Text("#\(pr.number)").font(.system(size: 11)).monospacedDigit()
                if let icon = pr.checks.icon {
                    Image(systemName: icon.name).font(.system(size: 10)).foregroundStyle(icon.color)
                }
                if pr.review == "APPROVED" {
                    Image(systemName: "hand.thumbsup.fill").font(.system(size: 9)).foregroundStyle(.green)
                } else if pr.review == "CHANGES_REQUESTED" {
                    Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["#\(pr.number) \(pr.title)", "State: \(pr.state.rawValue)"]
        switch pr.checks {
        case .passing: parts.append("Checks: passing")
        case .failing: parts.append("Checks: failing")
        case .pending: parts.append("Checks: running")
        case .none: break
        }
        if let r = pr.review { parts.append("Review: \(r.replacingOccurrences(of: "_", with: " ").lowercased())") }
        parts.append("Click to open")
        return parts.joined(separator: "\n")
    }
}

extension PRInfo.State {
    var color: SwiftUI.Color {
        switch self {
        case .open: return .green
        case .draft: return .gray
        case .merged: return .purple
        case .closed: return .red
        }
    }
}

extension PRInfo.Checks {
    var icon: (name: String, color: SwiftUI.Color)? {
        switch self {
        case .passing: return ("checkmark.circle.fill", .green)
        case .failing: return ("xmark.circle.fill", .red)
        case .pending: return ("clock.fill", .yellow)
        case .none: return nil
        }
    }
}

struct TerminalPane: View {
    @ObservedObject var terminal: TerminalSession
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
        ZStack {
            TerminalHost(view: terminal.view)
                .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 4)
            if !terminal.running {
                VStack(spacing: 10) {
                    Text("Claude exited\(terminal.exitCode.map { " (code \($0))" } ?? "")")
                        .font(.headline)
                    HStack {
                        Button("Restart") { terminal.restart() }.keyboardShortcut(.defaultAction)
                        Button("Remove") { model.endSession(terminal) }
                    }
                }
                .padding(20)
                .background(SwiftUI.Color(nsColor: Theme.chrome))
                .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.border)))
            }
        }
            Hairline()
            SessionStatusBar(terminal: terminal)
        }
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
        // Only adopt an orphaned view. When the layout changes, SwiftUI briefly keeps the old container alive;
        // stealing the view back into it would leave the new pane blank.
        if view.superview == nil { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view.needsLayout = true
        view.needsDisplay = true
        DispatchQueue.main.async { [view] in
            view.needsDisplay = true
            if view.window?.firstResponder == nil || view.window?.firstResponder === view.window {
                view.window?.makeFirstResponder(view)
            }
        }
    }
}

struct SessionInfoPane: View {
    let sid: String
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        let rec = model.store.records[sid]
        let info = model.store.live[sid]
        VStack(alignment: .leading, spacing: 14) {
            Text(rec?.displayTitle ?? info?.name ?? "Session").font(.title2.weight(.semibold))
            Text(abbreviatePath(rec?.cwd ?? info?.cwd ?? "")).foregroundStyle(.secondary)
            if let p = rec?.lastPrompt { Text("Last prompt: \(p)").font(.callout).foregroundStyle(.secondary).lineLimit(3) }

            if let info {
                Text("Running in \(info.entrypoint == "claude-desktop" ? "Claude desktop" : "another terminal") (pid \(info.pid)). Opening it here while it's still running would give two processes writing to the same conversation.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Stop There & Open Here") {
                        model.store.stopExternal(pid: info.pid)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { model.resume(sid) }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Open Here Anyway") { model.resume(sid) }
                }
                .controlSize(.large)
            } else {
                Button { model.resume(sid) } label: { Label("Open as Tab", systemImage: "play.fill") }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct EmptyPane: View {
    @EnvironmentObject var model: ProjectModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("No open sessions in \(model.name)").foregroundStyle(.secondary)
            Button("New Session") { model.newTab() }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AppKit helpers

/// Translucent window background shared by the sidebar and the area around the terminal card.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        // Tint toward the terminal's slate so sidebar and card read as one surface.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.075, green: 0.09, blue: 0.125, alpha: 0.82).cgColor
        tint.autoresizingMask = [.width, .height]
        v.addSubview(tint)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Lets the (hidden) title bar area drag the window, and double-click to zoom like a normal title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Hides the title bar and lets content extend under it, keeping the traffic lights.
struct WindowConfigurator: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarSeparatorStyle = .none
            w.toolbar = nil
            w.tabbingMode = .disallowed
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HideTitlebarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}
