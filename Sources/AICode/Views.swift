import SwiftUI
import SwiftTerm

private let topBarHeight: CGFloat = 40
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
        .background(VisualEffectBackground().ignoresSafeArea())
        .background(WindowConfigurator())
        .modifier(HideTitlebarBackground())
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .navigationTitle(folder.map { projectName(for: $0) } ?? "AICode")
        .onAppear(perform: handleLaunchArguments)
    }

    /// `AICode --new <dir>` opens a window on dir with a fresh session; `--resume <id>` resumes into its project.
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
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: sidebarWidth)
            VStack(spacing: 0) {
                TabStrip()
                    .frame(height: topBarHeight)
                DetailCard()
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
        }
        .environmentObject(model)
        .focusedSceneObject(model)
        .onAppear {
            if LaunchArgs.pendingNewSession { LaunchArgs.pendingNewSession = false; model.newTab() }
            if let sid = LaunchArgs.pendingResume { LaunchArgs.pendingResume = nil; model.resume(sid) }
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
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: ProjectModel
    @AppStorage("busyExpanded") private var busyExpanded = false

    var body: some View {
        let items = model.items
        VStack(alignment: .leading, spacing: 0) {
            // Traffic lights sit in this row; keep it draggable.
            SwiftUI.Color.clear.frame(height: topBarHeight).background(WindowDragArea())

            HStack {
                Text(model.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { model.newTab() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .help("New session in \(model.name) (⌘T)")
            }
            .padding(.leading, 18).padding(.trailing, 12)
            .help(abbreviatePath(model.folder))

            let busy = items.filter { $0.status == .working }
            let rest = items.filter { $0.status != .working }
            List(selection: $model.selection) {
                ForEach(rest) { item in
                    SessionRow(item: item, attention: item.sessionId.map(model.store.attention.contains) ?? false)
                        .tag(item.key)
                        .contextMenu { menu(item) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if items.isEmpty {
                    Text("No sessions running here").font(.callout).foregroundStyle(.secondary)
                } else if rest.isEmpty {
                    Text("Everything is busy").font(.callout).foregroundStyle(.tertiary)
                }
            }

            if !busy.isEmpty { busyDrawer(busy) }
        }
    }

    /// Sessions that are working right now, tucked into a collapsible drawer pinned to the bottom.
    private func busyDrawer(_ busy: [ActiveItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5)
            Button { withAnimation(.easeInOut(duration: 0.15)) { busyExpanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(busyExpanded ? 90 : 0))
                    Text("Busy").font(.system(size: 12, weight: .semibold))
                    Text("\(busy.count)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.orange.opacity(0.25), in: Capsule())
                    Spacer()
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if busyExpanded {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(busy) { item in
                            SessionRow(item: item, attention: false)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(model.selection == item.key ? SwiftUI.Color.white.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { model.selection = item.key }
                                .contextMenu { menu(item) }
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func menu(_ item: ActiveItem) -> some View {
        if let t = model.tabs.first(where: { "t:\($0.id)" == item.key }) {
            if !t.running { Button("Restart") { t.restart() } }
            Button("Close Tab") { model.close(t) }
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

/// One line: title on the left, status dot on the right. Unread (finished while you were away) shows bold.
struct SessionRow: View {
    let item: ActiveItem
    let attention: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .fontWeight(attention ? .semibold : .regular)
            Spacer(minLength: 4)
            StatusDot(status: item.status)
        }
        .help("\(item.title)\n\(item.status.label) · \(abbreviatePath(item.cwd))\(item.inApp ? "" : "\nRunning outside AICode (pid \(item.pid ?? 0))")")
    }
}

struct StatusDot: View {
    let status: SessionStatus
    var body: some View {
        Group {
            switch status {
            case .working, .starting:
                ProgressView().controlSize(.mini).scaleEffect(0.8)
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

// MARK: - Tabs

struct TabStrip: View {
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(model.tabs) { t in
                TabButton(terminal: t, item: model.item(for: t),
                          selected: model.selection == "t:\(t.id)",
                          attention: t.sessionId.map(model.store.attention.contains) ?? false)
            }
            Button { model.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 3)
            .help("New tab (⌘T)")
            SwiftUI.Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).background(WindowDragArea())
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.trailing, 10)
    }
}

struct TabButton: View {
    @ObservedObject var terminal: TerminalSession
    let item: ActiveItem?
    let selected: Bool
    let attention: Bool
    @EnvironmentObject var model: ProjectModel
    @State private var hovering = false

    private var tabTitle: String {
        let t = item?.title ?? "New session"
        return t.count > 28 ? String(t.prefix(27)) + "…" : t
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: item?.status ?? (terminal.running ? .starting : .exited))
            Text(tabTitle)
                .font(.system(size: 12, weight: selected || attention ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
            Button { model.close(terminal) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close tab (⌥⌘W)")
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 30)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous)
                .fill(selected ? SwiftUI.Color(nsColor: Theme.background) : (hovering ? .white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(terminal) }
        .onHover { hovering = $0 }
        .help(abbreviatePath(terminal.cwd))
    }
}

// MARK: - Detail

struct DetailCard: View {
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        ZStack {
            SwiftUI.Color(nsColor: Theme.background)
            if let t = model.selectedTerminal {
                TerminalPane(terminal: t).id(t.id)
            } else if let sid = model.selectedSessionId {
                SessionInfoPane(sid: sid)
            } else {
                EmptyPane()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}

struct TerminalPane: View {
    @ObservedObject var terminal: TerminalSession
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        ZStack {
            TerminalHost(view: terminal.view)
                .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 8)
            if !terminal.running {
                VStack(spacing: 10) {
                    Text("Claude exited\(terminal.exitCode.map { " (code \($0))" } ?? "")")
                        .font(.headline)
                    HStack {
                        Button("Restart") { terminal.restart() }.keyboardShortcut(.defaultAction)
                        Button("Close Tab") { model.close(terminal) }
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
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
        if container.subviews.first !== view { attach(to: container) }
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
        DispatchQueue.main.async { [view] in view.window?.makeFirstResponder(view) }
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
