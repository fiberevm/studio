import SwiftUI
import SwiftTerm
import WebKit

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
        .onAppear {
            StudioControl.shared.openWindow = { folder in openWindow(value: folder) }
            // a beat later: setting the scene value during the window's first appearance can be dropped
            DispatchQueue.main.async { handleLaunchArguments() }
        }
    }

    /// `Studio --new <dir>` opens a window on dir with a fresh session; `--resume <id>` resumes into its project.
    private func handleLaunchArguments() {
        guard !LaunchArgs.consumed else { return }
        let args = CommandLine.arguments
        // --new works even when SwiftUI already restored this window's folder on its own
        if let i = args.firstIndex(of: "--new"), i + 1 < args.count {
            LaunchArgs.consumed = true
            LaunchArgs.pendingNewSession = args[i + 1]
            if folder != args[i + 1] { folder = args[i + 1] }
            NotificationCenter.default.post(name: .studioLaunchNewSession, object: nil)   // window may already be up
            return
        }
        guard folder == nil else { return }
        LaunchArgs.consumed = true
        if false {
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

extension Notification.Name { static let studioLaunchNewSession = Notification.Name("studioLaunchNewSession") }

@MainActor enum LaunchArgs {
    static var consumed = false
    /// Folder that should get a fresh session once its window is up (`--new <dir>`).
    static var pendingNewSession: String?
    static var pendingResume: String?
}

struct ProjectView: View {
    @StateObject private var model: ProjectModel
    @Environment(\.openSettings) private var openSettings

    init(folder: String, store: SessionStore) {
        _model = StateObject(wrappedValue: ProjectModel(folder: folder, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: model.name, subtitle: abbreviatePath(model.folder))
            Hairline()
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    Sidebar()
                        .frame(width: model.sidebarWidth)
                    SidebarEdge()
                }
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
        .overlay(alignment: .top) {
            if model.quickPrompt {
                ZStack(alignment: .top) {
                    SwiftUI.Color.black.opacity(0.001)
                        .onTapGesture { model.quickPrompt = false; model.focusTerminal() }
                    QuickPrompt().padding(.top, 34)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast).font(.system(size: 12))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(SwiftUI.Color(nsColor: Theme.chrome))
                    .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.paneDivider), lineWidth: 1))
                    .padding(.bottom, 40)
                    .allowsHitTesting(false)
            }
        }
        .environmentObject(model)
        .focusedSceneObject(model)
        .onAppear {
            model.consumeLaunchNewSession()
            if let sid = LaunchArgs.pendingResume { LaunchArgs.pendingResume = nil; model.resume(sid) }
            if CommandLine.arguments.contains("--new-terminal") { model.newShellTab() }
            // debug: split like a user would, a few seconds after launch
            if CommandLine.arguments.contains("--split-later") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if let t = model.tabs.last, model.tabs.count > 1 { model.split(t, .right) }
                }
            }
            // debug/screenshot aid: split the last tab off to the right
            if CommandLine.arguments.contains("--split-demo"), let t = model.tabs.last, model.tabs.count > 1 {
                model.move(t.id, to: model.activeGroup, zone: .right)
            }
            // debug/screenshot aid: open Settings (on a section with --settings <name>)
            if CommandLine.arguments.contains("--settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    openSettings()
                    if CommandLine.arguments.contains("--order-front") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            NSApp.windows.filter { !($0.contentView?.subviews.isEmpty ?? true) && $0.title != model.name }
                                .forEach { $0.orderFrontRegardless() }
                        }
                    }
                }
            }
            // debug: open ⌘K once a Claude session is running in this window
            if CommandLine.arguments.contains("--quick-demo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { if !model.tabs.isEmpty { model.quickPrompt = true } }
            }
            // debug/screenshot aid: keep the first tab's peek card open
            if CommandLine.arguments.contains("--peek-demo") {
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    Task { @MainActor in if model.peekTab == nil { model.peekTab = model.tabs.last?.id } }
                }
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
                NewTabButton(width: 20, height: 20, help: "New session, terminal or browser in \(model.name)")
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
                    if !busy.isEmpty { ClaudeSpinner() }
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
            if model.isOpen(t) { Button("Close Tab") { model.closeKeepingRunning(t) } }
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
            Button("Copy Resume Command") { copy("cd \(shellQuote(item.cwd)) && " + (item.entrypoint == "codex" ? "codex resume \(sid)" : item.entrypoint == "agy" ? "agy --conversation \(sid)" : "claude --resume \(sid)")) }
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
            StatusDot(status: item.status, attention: attention, activity: item.activity)
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: 28)
        .background(selected ? SwiftUI.Color(nsColor: Theme.selection) : (hovering ? SwiftUI.Color.primary.opacity(0.04) : .clear),
                    ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(PointingHandCursor())
        .help("\(item.title)\n\(item.status.label) · \(abbreviatePath(item.cwd))\(item.inApp ? "" : "\nRunning outside Studio (pid \(item.pid ?? 0))")")
    }
}

struct StatusDot: View {
    let status: SessionStatus
    /// Finished while you weren't looking: shows an unread dot instead of nothing.
    var attention = false

    /// Ready-and-read sessions show nothing; callers can drop the dot's space entirely.
    static func isVisible(_ s: SessionStatus, attention: Bool) -> Bool { !(s == .idle && !attention) }
    /// What it's doing when working (thinking, a tool…): shown as an icon instead of a dot.
    var activity: Activity? = nil

    var body: some View {
        Group {
            switch status {
            case .starting:
                ClaudeSpinner()
            case .working, .shell:
                icon(activity?.symbol ?? (status == .shell ? "terminal" : "sparkles"), ClaudeSpinner.orange, pulse: true)
                    .help(activity?.label ?? status.label)
            case .waiting:
                icon("hand.raised.fill", NeedsYouDot.red, pulse: true).help("Needs you")
            case .idle:
                if attention { icon("checkmark", SwiftUI.Color(nsColor: Theme.accent)).help("Finished while you were away") }
                else { SwiftUI.Color.clear }   // ready and read: nothing
            case .exited:
                icon("stop.circle", .gray).help("Exited")
            default:
                Circle().fill(color).frame(width: 7, height: 7)
            }
        }
        .frame(width: 14, height: 12)
    }

    private func icon(_ name: String, _ color: SwiftUI.Color, pulse: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .modifier(SlowPulse(active: pulse))
            .contentTransition(.symbolEffect(.replace))
    }

    var color: SwiftUI.Color {
        switch status {
        case .idle: return .green
        case .waiting: return NeedsYouDot.red
        case .shell: return .blue
        case .exited: return .gray
        case .inactive: return .gray.opacity(0.4)
        default: return .orange
        }
    }
}

/// Whether status animations should run: only while Studio is the active app. Every animation frame
/// redraws the whole tab bar or sidebar layer, so they stop when nobody's looking.
final class AppActivity: ObservableObject {
    static let shared = AppActivity()
    @Published private(set) var live = true
    private var tokens: [Any] = []
    private init() {
        live = NSApp?.isActive ?? true
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.live = true })
        tokens.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.live = false })
    }
}

/// Status animations run as Core Animation on a layer of their own, so the render server plays them and
/// Studio does no work per frame. (Animated inside SwiftUI, every frame re-laid-out and repainted the
/// whole tab bar or sidebar, which SwiftUI draws as one layer.) They stop while Studio is in the
/// background (or always run with --animate-in-background, for measuring).
private func animationsLive(_ a: AppActivity) -> Bool {
    a.live || CommandLine.arguments.contains("--animate-in-background")
}

/// A working session's icon breathing in and out: the SwiftUI icon is drawn once into its own layer,
/// and only that layer's opacity animates.
struct SlowPulse: ViewModifier {
    let active: Bool
    @ObservedObject private var activity = AppActivity.shared
    func body(content: Content) -> some View {
        if active {
            content.hidden().overlay(PulseHost(content: content, live: animationsLive(activity)))
        } else {
            content
        }
    }
}

private struct PulseHost<C: View>: NSViewRepresentable {
    let content: C
    let live: Bool
    func makeNSView(context: Context) -> NSView {
        let box = LayerBox()
        let host = NSHostingView(rootView: AnyView(content))
        host.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(host)
        NSLayoutConstraint.activate([host.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                                     host.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        return box
    }
    func updateNSView(_ box: NSView, context: Context) {
        (box.subviews.first as? NSHostingView<AnyView>)?.rootView = AnyView(content)
        guard let layer = box.layer else { return }
        if live, layer.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0; a.toValue = 0.45
            a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: "pulse")
        } else if !live {
            layer.removeAnimation(forKey: "pulse")
        }
    }
}

/// A layer-backed view that keeps its animations when it moves between windows or is re-shown.
private final class LayerBox: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    /// What the running animation was built from; rebuild only when it changes.
    var built: AnyHashable?
    override var isFlipped: Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // clicks go to the tab underneath
}

/// Blocked on you (permission prompt, question): a red dot with a ring that ripples out, so it reads as different from "done".
struct NeedsYouDot: View {
    static let red = SwiftUI.Color(red: 0.95, green: 0.30, blue: 0.30)
    @ObservedObject private var activity = AppActivity.shared
    var body: some View {
        NeedsYouLayer(live: animationsLive(activity)).frame(width: 12, height: 12)
    }
}

private struct NeedsYouLayer: NSViewRepresentable {
    let live: Bool
    func makeNSView(context: Context) -> NSView {
        let box = LayerBox(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        let red = NSColor(NeedsYouDot.red).cgColor
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -3.5, y: -3.5, width: 7, height: 7), transform: nil)
        ring.fillColor = nil; ring.strokeColor = red; ring.lineWidth = 1.5; ring.opacity = 0
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: -3.5, y: -3.5, width: 7, height: 7), transform: nil)
        dot.fillColor = red
        for l in [ring, dot] { l.position = CGPoint(x: 6, y: 6); box.layer?.addSublayer(l) }
        return box
    }
    func updateNSView(_ box: NSView, context: Context) {
        guard let ring = box.layer?.sublayers?.first else { return }
        if live, ring.animation(forKey: "ripple") == nil {
            let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 1.0; scale.toValue = 13.0 / 7
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.7; fade.toValue = 0.0
            let g = CAAnimationGroup(); g.animations = [scale, fade]; g.duration = 1.4; g.repeatCount = .infinity
            ring.add(g, forKey: "ripple")
        } else if !live {
            ring.removeAnimation(forKey: "ripple")
        }
    }
}

/// Studio's working indicator: a 2×2 grid of panes with the focus walking around it clockwise,
/// leaving a fading trail, like focus moving between split panes.
struct ClaudeSpinner: View {
    var size: CGFloat = 12
    static let orange = SwiftUI.Color(red: 0.91, green: 0.53, blue: 0.33)
    @ObservedObject private var activity = AppActivity.shared

    var body: some View {
        SpinnerLayer(size: size, base: NSColor(SwiftUI.Color(nsColor: Theme.foreground).opacity(0.16)),
                     live: animationsLive(activity))
            .frame(width: size, height: size)
    }
}

private struct SpinnerLayer: NSViewRepresentable {
    let size: CGFloat
    let base: NSColor
    let live: Bool
    private static let order = [0, 1, 3, 2]   // top-left → top-right → bottom-right → bottom-left
    private static let step = 0.16

    func makeNSView(context: Context) -> NSView {
        let box = LayerBox(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let cell = (size - 2) / 2
        for i in 0..<4 {
            let l = CALayer()
            l.cornerRadius = 1
            l.frame = CGRect(x: CGFloat(i % 2) * (cell + 2), y: CGFloat(i / 2) * (cell + 2), width: cell, height: cell)
            box.layer?.addSublayer(l)
        }
        return box
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard let box = view as? LayerBox else { return }
        let key = AnyHashable([AnyHashable(live), AnyHashable(base)])
        guard box.built != key else { return }   // SwiftUI updates often; restarting would stutter
        box.built = key
        let orange = NSColor(ClaudeSpinner.orange)
        let colors = [orange.cgColor, orange.withAlphaComponent(0.45).cgColor, base.cgColor, base.cgColor]
        for (i, l) in (box.layer?.sublayers ?? []).enumerated() {
            l.backgroundColor = base.cgColor
            guard live else { l.removeAnimation(forKey: "walk"); continue }
            // each pane is lit, then trails, then rests; its turn comes `pos` steps after the first pane's
            let pos = Self.order.firstIndex(of: i)!
            let a = CAKeyframeAnimation(keyPath: "backgroundColor")
            a.values = colors
            a.calculationMode = .discrete
            a.duration = Self.step * 4
            a.repeatCount = .infinity
            a.timeOffset = Self.step * Double(4 - pos)
            l.add(a, forKey: "walk")   // re-added on theme changes so the base color follows
        }
    }
}

/// The line between split panes: thicker and higher-contrast than chrome hairlines so panes read as separate.
struct PaneDivider: View {
    /// One physical pixel: a true hairline on Retina (0.5pt), 1pt elsewhere.
    static let thickness: CGFloat = 1 / max(NSScreen.main?.backingScaleFactor ?? 2, 1)
    var vertical = false
    var body: some View {
        SwiftUI.Color(nsColor: Theme.paneDivider)
            .frame(width: vertical ? Self.thickness : nil, height: vertical ? nil : Self.thickness)
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

/// The sidebar's 1px edge, draggable to resize it (VS Code style).
struct SidebarEdge: View {
    @EnvironmentObject var model: ProjectModel
    @State private var start: CGFloat?

    var body: some View {
        Hairline(vertical: true)
            .overlay(
                SwiftUI.Color.clear.frame(width: 7).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let s0 = start ?? model.sidebarWidth
                            if start == nil { start = s0 }
                            model.sidebarWidth = min(max(s0 + v.translation.width, 160), 520)
                        }
                        .onEnded { _ in start = nil })
            )
            .zIndex(1)
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
            let avail = max(total - CGFloat(box.children.count - 1) * PaneDivider.thickness, 1)
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
        PaneDivider(vertical: horizontal)
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
        .overlayPreferenceValue(TabAnchors.self) { anchors in
            GeometryReader { proxy in
                if let id = model.peekTab, let a = anchors[id], let t = model.terminal(id) {
                    let r = proxy[a]
                    PeekCard(terminal: t, item: model.item(for: t))
                        .offset(x: max(0, min(r.minX, proxy.size.width - 400)), y: r.maxY + 4)
                        .transition(.opacity)
                }
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
            NewTabButton(width: 30, height: topBarHeight, help: "New session, terminal or browser") { model.activate(group) }
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

    private var tabStatus: SessionStatus { item?.status ?? (terminal.running ? .starting : .exited) }

    private var tabTitle: String {
        let t = terminal.isWeb ? (terminal.webTitle.isEmpty ? (terminal.url?.host ?? "New tab") : terminal.webTitle)
            : terminal.isShell ? shellTitle : (terminal.isAgent && !terminal.isClaude) ? agentTitle : (item?.title ?? "New session")
        return t.count > 28 ? String(t.prefix(27)) + "…" : t
    }

    /// Codex and agy tabs use the conversation's name or first message, else the CLI's name.
    private var agentTitle: String { item?.title ?? terminal.agent?.name ?? "Session" }

    /// Shell tabs use the title the shell sets (OSC 0/2), else "zsh — folder".
    private var shellTitle: String {
        let t = terminal.terminalTitle.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        let sh = ((ProcessInfo.processInfo.environment["SHELL"] ?? "zsh") as NSString).lastPathComponent
        return "\(sh) — \(projectName(for: terminal.cwd))"
    }

    var body: some View {
        HStack(spacing: 8) {
            if terminal.isWeb {
                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 12)
            } else if terminal.isCodex || terminal.isAgy {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12)
            } else if terminal.isShell {
                Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 12)
            } else if StatusDot.isVisible(tabStatus, attention: attention) {
                StatusDot(status: tabStatus, attention: attention, activity: item?.activity)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            Text(tabTitle)
                .font(.system(size: 12))
                .foregroundStyle(selected && groupActive ? .primary : .secondary)
                .lineLimit(1)
            Button { model.close(terminal) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || selected ? 1 : 0)
            .help(Pref.bool(Pref.closeTabEndsSession, default: true) ? "Close tab and end the session (⌘W)" : "Close tab — session keeps running (⌘W)")
        }
        // the title slides over when the dot comes and goes
        .animation(.easeInOut(duration: 0.22), value: StatusDot.isVisible(tabStatus, attention: attention))
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
        .onTapGesture { model.peekTab = nil; model.select(terminal, in: group) }
        .onHover { h in
            hovering = h
            if h, terminal.isAgent {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if hovering, model.dropTarget == nil { model.peekTab = terminal.id }
                }
            } else if model.peekTab == terminal.id {
                model.peekTab = nil
            }
        }
        .anchorPreference(key: TabAnchors.self, value: .bounds) { [terminal.id: $0] }
        .onDrag { model.peekTab = nil; return TabDrag.provider(terminal) }
        .contextMenu {
            if terminal.isAgent {
                Button(terminal.isNative ? "Switch to Terminal View" : "Switch to Native View") { model.toggleNative(terminal) }
                if terminal.agent?.canFork == true {
                    Button("Fork Session to the Right") { model.fork(terminal) }
                    Button("Fork Session Below") { model.fork(terminal, zone: .bottom) }
                }
                Divider()
            }
            Button("Split Right") { model.split(terminal, .right) }
            Button("Split Left") { model.split(terminal, .left) }
            Button("Split Down") { model.split(terminal, .bottom) }
            Button("Split Up") { model.split(terminal, .top) }
            Divider()
            Button("Close Tab") { model.close(terminal) }
            if terminal.isAgent {
                Button("Close Tab, Keep Session Running") { model.closeKeepingRunning(terminal) }
            }
        }
    }
}

struct TabAnchors: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Hover card under a tab: where the session stands and Claude's last words, so you can decide without switching.
struct PeekCard: View {
    @ObservedObject var terminal: TerminalSession
    let item: ActiveItem?
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        let sid = terminal.sessionId
        let rec = sid.flatMap { model.store.records[$0] }
        let info = sid.flatMap { model.store.live[$0] }
        let status = item?.status ?? (terminal.running ? .starting : .exited)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(status: status, attention: sid.map(model.store.attention.contains) ?? false, activity: item?.activity)
                Text(item?.title ?? "New session").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(statusLine(status, info: info)).font(.system(size: 11))
                    .foregroundStyle(status == .waiting ? NeedsYouDot.red : .secondary)
            }
            if let reply = rec?.lastReply {
                Text(reply).font(.system(size: 12)).lineLimit(9).truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(status == .working ? "Working on it…" : "No reply yet").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let p = rec?.lastPrompt {
                HStack(alignment: .top, spacing: 6) {
                    Text("You").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(p).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(12)
        .frame(width: 400, alignment: .leading)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.paneDivider), lineWidth: 1))
        .allowsHitTesting(false)
    }

    private func statusLine(_ s: SessionStatus, info: LiveInfo?) -> String {
        let since = info.map { " · " + relativeTime($0.updatedAt) } ?? ""
        switch s {
        case .waiting: return "Needs you: \(info?.waitingFor ?? "input")\(since)"
        case .idle: return "Ready\(since)"
        default: return s.label + since
        }
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
                EmptyPane(group: group)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.activate(group) })
    }
}

/// Bottom strip under a session: branch, model, tokens sent/received. Icons only; hover for labels.
struct SessionStatusBar: View {
    @ObservedObject var terminal: TerminalSession
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        let sid = terminal.sessionId
        let st = sid.flatMap { model.store.stats[$0] }
        HStack(spacing: 14) {
            if terminal.isWeb { stat("globe", terminal.url?.host ?? "", help: terminal.url?.absoluteString ?? "") }
            else if terminal.isShell { stat("folder", abbreviatePath(terminal.cwd), help: "Started in") }
            if let b = st?.gitBranch { stat("arrow.triangle.branch", b, help: "Git branch") }
            if let m = st?.model { stat("cpu", prettyModel(m), help: "Model: \(m)") }
            // agy keeps no token counts on disk; its native view reports them per turn
            let tokens: (Int, Int)? = st.flatMap { $0.tokensIn > 0 ? ($0.tokensIn, $0.tokensOut) : nil }
                ?? terminal.native.flatMap { $0.tokensIn > 0 ? ($0.tokensIn, $0.tokensOut) : nil }
            if let (i, o) = tokens {
                stat("arrow.up", formatTokens(i), help: "Tokens sent: \(i.formatted()) (incl. cache)")
                stat("arrow.down", formatTokens(o), help: "Tokens received: \(o.formatted())")
            }
            if terminal.isAgent { SandboxChips(registry: model.store.sandboxes, terminal: terminal) }
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

/// The sandboxes this session uses: sailboat + name, tinted by state. Click for actions.
struct SandboxChips: View {
    @ObservedObject var registry: SandboxRegistry
    @ObservedObject var terminal: TerminalSession
    @EnvironmentObject var model: ProjectModel
    @State private var confirmDelete: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(registry.ids(for: terminal), id: \.self) { id in chip(id) }
        }
        .alert("Delete sandbox \(confirmDelete ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = confirmDelete { act { _ = try await registry.provider(for: id).delete(id); registry.forget(id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its disk and snapshots are permanently removed.") }
    }

    private func chip(_ id: String) -> some View {
        let s = registry.info[id]
        let state = s?.state ?? "…"
        return Menu {
            Text("\(s?.label ?? id) · \(state)\(s?.type.map { " · \($0)" } ?? "")")
            Divider()
            Button("Open Terminal") { openTerminal(id) }
            Button("Open Desktop") {
                act {
                    let url = try await registry.provider(for: id).desktopURL(id)
                    model.openWeb(url, beside: model.group(containing: terminal.id), zone: .right)
                }
            }
            Button("Open Desktop in Browser") { act { _ = try await registry.provider(for: id).openDesktop(id) } }
            Button("Copy ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string) }
            Divider()
            if state == "stopped" {
                Button("Resume") { act { _ = try await registry.provider(for: id).resume(id) } }
            } else {
                Button("Stop") { act { _ = try await registry.provider(for: id).stop(id) } }
            }
            Button("Remove from This Session") { registry.detach(id, from: terminal) }
            Button("Delete…") { confirmDelete = id }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sailboat").font(.system(size: 10))
                Text(s?.label ?? id).font(.system(size: 11)).lineLimit(1)
                Circle().fill(color(state)).frame(width: 5, height: 5)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sandbox \(id) (\(state))")
    }

    private func color(_ state: String) -> SwiftUI.Color {
        switch state {
        case "running", "ready", "idle", "up": return .green
        case "stopped": return .gray
        case "error": return NeedsYouDot.red
        default: return ClaudeSpinner.orange
        }
    }

    private func openTerminal(_ id: String) {
        let t = model.store.newShell(in: terminal.cwd)
        model.place(t, beside: model.group(containing: terminal.id) ?? model.activeGroup, zone: .right)
        let cmd = registry.provider(for: id).sshCommand(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { t.type(cmd + "\r") }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { model.showToast(error.localizedDescription) }
            await registry.refresh()
        }
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
        if terminal.isWeb {
            WebPane(tab: terminal)
        } else if let chat = terminal.native {
            NativeChatView(chat: chat).id(ObjectIdentifier(chat))
        } else {
        ZStack {
            TerminalHost(view: terminal.view)
                .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 4)
            if !terminal.running {
                VStack(spacing: 10) {
                    Text("\(terminal.isShell ? "Shell" : terminal.agent?.name ?? "Session") exited\(terminal.exitCode.map { " (code \($0))" } ?? "")")
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
        }
            Hairline()
            SessionStatusBar(terminal: terminal)
        }
    }
}

/// A web panel: slim toolbar (back, forward, reload, address, open in browser) over a WKWebView.
struct WebPane: View {
    @ObservedObject var tab: TerminalSession
    @State private var address = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                button("chevron.left", "Back") { tab.webView.goBack() }
                button("chevron.right", "Forward") { tab.webView.goForward() }
                button("arrow.clockwise", "Reload") { tab.webView.reload() }
                TextField("Enter a URL", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(SwiftUI.Color(nsColor: Theme.background))
                    .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: editing ? Theme.accent : Theme.paneDivider), lineWidth: 1))
                    .focused($editing)
                    .onSubmit { go() }
                button("safari", "Open in browser") { if let u = tab.url { NSWorkspace.shared.open(u) } }
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(SwiftUI.Color(nsColor: Theme.chrome))
            Hairline()
            WebHost(view: tab.webView)
        }
        .onAppear {
            address = tab.url?.absoluteString ?? ""
            if tab.url == nil { DispatchQueue.main.async { editing = true } }
        }
        .onChange(of: tab.url) { _, u in if !editing { address = u?.absoluteString ?? "" } }
    }

    private func button(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless).help(help)
    }

    /// Bare words search; anything with a dot or a scheme is a URL (localhost:3000 works too).
    private func go() {
        let s = address.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        let url: URL?
        if s.contains("://") { url = URL(string: s) }
        else if s.contains(".") || s.hasPrefix("localhost") || s.contains(":") { url = URL(string: "https://" + s.replacingOccurrences(of: "https://localhost", with: "http://localhost")) }
        else { url = URL(string: "https://www.google.com/search?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)) }
        if let u = url.map({ $0.host == "localhost" || $0.host == "127.0.0.1" ? URL(string: $0.absoluteString.replacingOccurrences(of: "https://", with: "http://"))! : $0 }) {
            tab.navigate(u)
        }
        editing = false
    }
}

/// Hosts a tab's long-lived WKWebView. Same ownership rule as TerminalHost: SwiftUI makes the new container
/// before tearing down the old one when a pane moves, splits or resizes, so the newest container (or the one
/// that just entered a window) owns the view, and a container on its way out never takes it back.
struct WebHost: NSViewRepresentable {
    let view: WKWebView

    @MainActor final class Container: NSView {
        weak var web: WKWebView?
        private static var owners: [ObjectIdentifier: WeakBox] = [:]
        private final class WeakBox { weak var c: Container?; init(_ c: Container) { self.c = c } }

        private var isOwner: Bool { web.map { Self.owners[ObjectIdentifier($0)]?.c === self } ?? false }

        func claim() {
            guard let w = web else { return }
            Self.owners[ObjectIdentifier(w)] = WeakBox(self)
            adopt()
        }

        private func adopt() {
            guard let w = web, isOwner else { return }
            if w.superview !== self {
                w.removeFromSuperview()
                addSubview(w)
            }
            w.frame = bounds
            w.autoresizingMask = [.width, .height]
        }

        func refresh() { adopt() }   // only the owner re-adopts; never steal

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { claim() }
        }

        override func layout() {
            super.layout()
            if isOwner, let w = web, w.superview === self { w.frame = bounds }
        }
    }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        c.web = view
        c.claim()
        return c
    }

    func updateNSView(_ c: Container, context: Context) {
        if c.web !== view { c.web = view; c.claim() } else { c.refresh() }
    }
}

/// Hosts a long-lived SwiftTerm view inside SwiftUI without recreating it.
///
/// A terminal view can live in only one container, and SwiftUI creates new containers before tearing down old
/// ones (and sometimes creates one it then discards). Rule: the most recent container to be created or to
/// appear in a window *owns* the terminal; only the owner adopts it. A container on its way out never steals
/// it back — that's what blanked panes after a split.
struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    @MainActor final class Container: NSView {
        weak var terminal: LocalProcessTerminalView? {
            didSet { registerForDraggedTypes([.fileURL, .png, .tiff]) }
        }

        // MARK: File & image drops — type the paths like Terminal.app, so Claude Code attaches images.
        // (Tab drags carry plain text, which this doesn't accept, so they still reach the split drop zones.)

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            Self.hasDroppable(sender.draggingPasteboard) ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            Self.hasDroppable(sender.draggingPasteboard) ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let paths = Self.droppedPaths(sender.draggingPasteboard)
            guard let t = terminal, !paths.isEmpty else { return false }
            // As a paste (bracketed when the app asked for it), like Terminal.app, so Claude Code turns an
            // image path into an attachment instead of seeing typed characters.
            t.pasteText(paths.map(Self.escapePath).joined(separator: " ") + " ")
            window?.makeFirstResponder(t)
            return true
        }

        private static func hasDroppable(_ pb: NSPasteboard) -> Bool {
            pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                || pb.canReadObject(forClasses: [NSImage.self], options: nil)
        }

        /// File URLs as-is; raw image data (e.g. dragged from a browser) is written to a temp PNG first.
        private static func droppedPaths(_ pb: NSPasteboard) -> [String] {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                return urls.map(\.path)
            }
            guard let img = (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
                  let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return [] }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StudioDrops", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("dropped-\(Int(Date().timeIntervalSince1970 * 1000)).png")
            return (try? png.write(to: url)) != nil ? [url.path] : []
        }

        /// Backslash-escape shell-special characters, as Terminal.app does for dropped paths.
        private static func escapePath(_ p: String) -> String {
            let special = Set(" \t\\'\"()[]{}&;|<>*?$`!#~")
            return String(p.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
        }
        private static var owners: [ObjectIdentifier: WeakContainer] = [:]
        private struct WeakContainer { weak var c: Container? }

        private var isOwner: Bool {
            guard let t = terminal else { return false }
            return Self.owners[ObjectIdentifier(t)]?.c === self
        }

        func claim() {
            guard let t = terminal else { return }
            Self.owners[ObjectIdentifier(t)] = WeakContainer(c: self)
            adopt()
        }

        private func adopt() {
            guard let t = terminal, t.superview !== self else { return }
            subviews.forEach { $0.removeFromSuperview() }
            t.removeFromSuperview()
            t.translatesAutoresizingMaskIntoConstraints = false
            addSubview(t)
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: leadingAnchor),
                t.trailingAnchor.constraint(equalTo: trailingAnchor),
                t.topAnchor.constraint(equalTo: topAnchor),
                t.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            t.needsLayout = true
            t.needsDisplay = true
            DispatchQueue.main.async { [weak t] in
                guard let t, let w = t.window else { return }
                t.needsDisplay = true
                if w.firstResponder == nil || w.firstResponder === w { w.makeFirstResponder(t) }
            }
        }

        /// Owner in a window keeps it; a container that shows up in a window claims it (covers the case where
        /// the newest container was a throwaway that never got on screen).
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { claim() }
        }

        /// SwiftUI update: re-attach only if we own it (e.g. it was pulled out from under us) — never steal.
        func refresh() {
            if isOwner { adopt() }
        }
    }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        c.terminal = view
        c.claim()
        return c
    }

    func updateNSView(_ c: Container, context: Context) {
        if c.terminal !== view { c.terminal = view; c.claim() } else { c.refresh() }
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

/// Shown when a pane has no tabs: quiet, low-contrast actions so it doesn't shout.
struct EmptyPane: View {
    let group: GroupNode
    @EnvironmentObject var model: ProjectModel
    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(NewTabKind.available.enumerated()), id: \.element) { i, k in
                EmptyAction(title: k.title, key: i == 0 ? "⌘N" : k.keyLabel) { model.activate(group); k.open(in: model) }
            }
            if model.groups.count > 1 {
                EmptyAction(title: "Close Pane", key: "⌘W") { model.closePane(group) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyAction: View {
    let title: String
    let key: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                Spacer(minLength: 0)
                Text(key).monospaced()
            }
            .font(.system(size: 12))
            .frame(width: 230)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(hover ? 0.75 : 0.4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(SwiftUI.Color(nsColor: Theme.foreground))
        .onHover { hover = $0 }
        .modifier(PointingHandCursor())
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
            // preview/screenshot aid: show the window without activating the app (keyboard focus stays put)
            if CommandLine.arguments.contains("--order-front") { w.orderFrontRegardless() }
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

/// Pointing-hand cursor while hovering, to show a row is clickable.
struct PointingHandCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
