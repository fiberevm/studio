import SwiftUI
import SwiftTerm

private let topBarHeight: CGFloat = 40
private let sidebarWidth: CGFloat = 270

struct ContentView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: sidebarWidth)
            VStack(spacing: 0) {
                DetailHeader()
                    .frame(height: topBarHeight)
                DetailCard()
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(VisualEffectBackground().ignoresSafeArea())
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .task { store.handleLaunchArguments() }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        let items = store.activeItems
        VStack(spacing: 0) {
            // Traffic lights live in the top-left; keep the row draggable and put the + on the right.
            HStack {
                Spacer()
                Button { store.newSessionPickingFolder() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.borderless)
                .help("New session (⌘N)")
            }
            .padding(.horizontal, 10)
            .frame(height: topBarHeight)
            .background(WindowDragArea())

            List(selection: $store.selection) {
                ForEach(items) { item in
                    SessionRow(item: item, attention: item.sessionId.map(store.attention.contains) ?? false)
                        .tag(item.key)
                        .contextMenu { menu(item) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if items.isEmpty {
                    Text("No running sessions").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func menu(_ item: ActiveItem) -> some View {
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

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct SessionRow: View {
    let item: ActiveItem
    let attention: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: item.status)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .fontWeight(attention ? .semibold : .regular)
            Spacer(minLength: 4)
            if attention { Circle().fill(SwiftUI.Color.accentColor).frame(width: 6, height: 6) }
            if !item.inApp {
                Image(systemName: item.entrypoint == "claude-desktop" ? "macwindow" : "apple.terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
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

// MARK: - Detail

struct DetailHeader: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        HStack(spacing: 8) {
            if let item = selectedItem {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(abbreviatePath(item.cwd)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Text(item.status.label).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
    }

    private var selectedItem: ActiveItem? {
        guard let sel = store.selection else { return nil }
        return store.activeItems.first { $0.key == sel }
    }
}

struct DetailCard: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        ZStack {
            SwiftUI.Color(nsColor: Theme.background)
            if let t = store.selectedTerminal {
                TerminalPane(terminal: t).id(t.id)
            } else if let sid = store.selectedSessionId {
                SessionInfoPane(sid: sid)
            } else {
                EmptyPane()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}

struct TerminalPane: View {
    @ObservedObject var terminal: TerminalSession
    @EnvironmentObject var store: SessionStore

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
                        Button("Close") { store.close(terminal) }
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
    @EnvironmentObject var store: SessionStore

    var body: some View {
        let rec = store.records[sid]
        let info = store.live[sid]
        VStack(alignment: .leading, spacing: 14) {
            Text(rec?.displayTitle ?? info?.name ?? "Session").font(.title2.weight(.semibold))
            Text(abbreviatePath(rec?.cwd ?? info?.cwd ?? "")).foregroundStyle(.secondary)
            if let p = rec?.lastPrompt { Text("Last prompt: \(p)").font(.callout).foregroundStyle(.secondary).lineLimit(3) }

            if let info {
                Text("Running in \(info.entrypoint == "claude-desktop" ? "Claude desktop" : "another terminal") (pid \(info.pid)). Resuming it here while it's still running would give two processes writing to the same conversation.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Stop There & Resume Here") {
                        store.stopExternal(pid: info.pid)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { store.resume(sid) }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Resume Here Anyway") { store.resume(sid) }
                }
                .controlSize(.large)
            } else {
                Button { store.resume(sid) } label: { Label("Resume Session", systemImage: "play.fill") }
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
    @EnvironmentObject var store: SessionStore
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Select a session, or start a new one").foregroundStyle(.secondary)
            Button("New Session…") { store.newSessionPickingFolder() }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AppKit helpers

/// Translucent window background shared by the sidebar and the area around the terminal card.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
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
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.toolbar = nil
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
