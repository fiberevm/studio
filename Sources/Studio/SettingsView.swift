import SwiftUI

/// Settings keys shared by the Settings window and the code that reads them.
enum Pref {
    static let closeTabEndsSession = "closeTabEndsSession"          // Bool, default true
    static let keepSessionsAlive = "keepSessionsAlive"              // Bool, default true (needs tmux)
    static let nativePermissionMode = "nativePermissionMode"        // "" = same as the session
    static let sandboxEnabled = "sandbox.boat.enabled"              // Bool, default true
    static let sandboxType = "sandbox.boat.type"                    // small/default/large/xlarge
    static let sandboxTTL = "sandbox.boat.ttlMinutes"               // Int, 0 = provider default
    static let sandboxEnvironment = "sandbox.boat.environment"      // "" = account default
    static let sandboxPolicy = "sandbox.policy"                     // "auto" (default) | "ask"
    static let defaultAgent = "defaultAgent"                        // Agent raw value, default "claude"
    static let autoCloseEmptyPanes = "autoCloseEmptyPanes"          // Bool, default true

    static func bool(_ k: String, default d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    static func string(_ k: String) -> String? {
        let s = UserDefaults.standard.string(forKey: k) ?? ""
        return s.isEmpty ? nil : s
    }
}

/// The coding agent CLI a new session runs.
enum Agent: String, CaseIterable, Identifiable {
    case claude, codex, agy
    var id: String { rawValue }
    var name: String {
        switch self { case .claude: return "Claude Code"; case .codex: return "Codex"; case .agy: return "Antigravity" }
    }
    var command: String { self == .claude ? "claude" : rawValue }
    /// Can copy a conversation into a new session (agy has no fork).
    var canFork: Bool { self != .agy }
    /// Settings → Sessions → Default agent.
    static var preferred: Agent { Pref.string(Pref.defaultAgent).flatMap(Agent.init(rawValue:)) ?? .claude }
}

/// Opening Settings on a given section (from ⌘P): read when the window opens, or posted to an open one.
enum SettingsNav {
    nonisolated(unsafe) static var pending: String?
    static let show = Notification.Name("studio.settings.section")
}

/// ⌘, — a VS Code / System Settings style window: sections on the left, the section on the right.
struct SettingsView: View {
    @EnvironmentObject var store: SessionStore
    // debug/screenshot aid: --settings <section> opens Settings on that section
    @State private var section: Section = {
        if let p = SettingsNav.pending, let s = Section.allCases.first(where: { $0.rawValue.lowercased() == p }) {
            SettingsNav.pending = nil
            return s
        }
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--settings"), i + 1 < a.count,
           let s = Section.allCases.first(where: { $0.rawValue.lowercased() == a[i + 1].lowercased() }) { return s }
        return .appearance
    }()

    enum Section: String, CaseIterable, Identifiable {
        case appearance = "Appearance", agents = "Agents", workers = "Workers", sessions = "Sessions", worktrees = "Worktrees", sandboxes = "Sandboxes", secrets = "Secrets", account = "Account", updates = "Updates", telemetry = "Telemetry", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appearance: return "paintbrush"
            case .agents: return "terminal"
            case .workers: return "server.rack"
            case .sessions: return "rectangle.stack"
            case .sandboxes: return "sailboat"
            case .worktrees: return "arrow.triangle.branch"
            case .secrets: return "key"
            case .account: return "person.crop.circle"
            case .updates: return "arrow.down.circle"
            case .telemetry: return "chart.bar"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: "Settings", subtitle: section.rawValue)
            Hairline()
            HStack(spacing: 0) {
                // Same as the session sidebar: chrome color, 28pt rows, square selection.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Section.allCases) { s in
                        SectionRow(section: s, selected: s == section) { section = s }
                    }
                    Spacer()
                }
                .padding(.top, 6)
                .frame(width: 190)
                .background(SwiftUI.Color(nsColor: Theme.chrome), ignoresSafeAreaEdges: [])
                Hairline(vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch section {
                        case .appearance: AppearanceSettings()
                        case .agents: AgentSettings()
                        case .workers: WorkerSettings()
                        case .sessions: SessionSettings()
                        case .sandboxes: SandboxSettings(registry: store.sandboxes)
                        case .worktrees: WorktreeSettings()
                        case .secrets: SecretSettings()
                        case .account: AccountSettings()
                        case .updates: UpdatesSettings()
                        case .telemetry: TelemetrySettings()
                        case .about: AboutSettings()
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(SwiftUI.Color(nsColor: Theme.background), ignoresSafeAreaEdges: [])
                .clipped()   // scrolled content must not slide under the title bar
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(SwiftUI.Color(nsColor: Theme.foreground))
        .background(SwiftUI.Color(nsColor: Theme.chrome).ignoresSafeArea())
        .background(WindowConfigurator())
        .modifier(HideTitlebarBackground())
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(Theme.current.isLight ? .light : .dark)   // match Studio's theme
        .onReceive(NotificationCenter.default.publisher(for: SettingsNav.show)) { n in
            if let p = n.object as? String, let s = Section.allCases.first(where: { $0.rawValue.lowercased() == p }) { section = s }
        }
    }
}

private struct SectionRow: View {
    let section: SettingsView.Section
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.icon).font(.system(size: 12)).frame(width: 16)
            Text(section.rawValue).font(.system(size: 13))
            Spacer()
        }
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(selected ? SwiftUI.Color(nsColor: Theme.selection) : (hover ? SwiftUI.Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .modifier(PointingHandCursor())
    }
}

/// VS Code-style setting: bold title, one-line description, control underneath; hairline between settings.
/// The width of a settings text field that sits on the right of its row.
let settingsMenuWidth: CGFloat = 220

/// A setting: title and description on the left, its control on the right edge, centred on the text (like
/// ToggleRow's switch). `wide` puts a control that needs the room (a field, a list) under the text instead,
/// across the whole row.
struct Row<Control: View>: View {
    let title: String
    var detail: String? = nil
    var wide = false
    @ViewBuilder let control: () -> Control
    var body: some View {
        Group {
            if wide {
                VStack(alignment: .leading, spacing: 10) {
                    text
                    control().frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: 24) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    control().fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Hairline() }
    }
    private var text: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Studio's own switch, in the theme's accent: a track with a knob that slides across. Click to flip it.
struct StudioToggle: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    @ObservedObject private var theme = ThemeChanges.shared

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.14)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? SwiftUI.Color(nsColor: Theme.accent) : SwiftUI.Color.primary.opacity(0.2))
                Circle().fill(SwiftUI.Color.white).frame(width: 14, height: 14).padding(3)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
            .frame(width: 36, height: 20)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A setting that is on or off: title and description on the left, the switch on the right. `extra` goes under
/// the description (a related button).
struct ToggleRow<Extra: View>: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var disabled = false
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                extra().padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StudioToggle(isOn: $isOn).disabled(disabled)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

extension ToggleRow where Extra == EmptyView {
    init(title: String, detail: String? = nil, isOn: Binding<Bool>, disabled: Bool = false) {
        self.init(title: title, detail: detail, isOn: isOn, disabled: disabled) { EmptyView() }
    }
}

struct Group_: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, 20).padding(.bottom, 2)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("sidebarVisible.v2") private var sidebar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group_(title: "Theme")
            ThemeSwatches()
            Row(title: "Color theme", detail: "Also in ⌘P → Change Theme…, with live preview.") {
                Picker("", selection: Binding(get: { Theme.current.id }, set: { id in
                    if let t = AppTheme.all.first(where: { $0.id == id }) { store.setTheme(t) }
                })) {
                    ForEach(AppTheme.all, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
            }
            Row(title: "Text size", detail: "Terminals and the native view. ⌘+ / ⌘− / ⌘0.") {
                Stepper("\(Int(store.fontSize)) pt", value: $store.fontSize, in: 9...24, step: 1)
            }
            Group_(title: "Layout")
            ToggleRow(title: "Show session sidebar",
                detail: "A list of the project's sessions on the left: who's waiting for you, and what's busy. Applies to every window; ⌘B toggles it in one window.", isOn: $sidebar)
        }
    }
}

/// Clickable theme previews: background, chrome strip and an accent bar, like VS Code's theme picker.
private struct ThemeSwatches: View {
    @EnvironmentObject var store: SessionStore
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
            ForEach(AppTheme.all, id: \.id) { t in
                let on = t.id == Theme.current.id
                Button { store.setTheme(t) } label: {
                    VStack(spacing: 5) {
                        VStack(spacing: 0) {
                            SwiftUI.Color(nsColor: t.chrome).frame(height: 12)
                            ZStack(alignment: .topLeading) {
                                SwiftUI.Color(nsColor: t.background)
                                VStack(alignment: .leading, spacing: 4) {
                                    Capsule().fill(SwiftUI.Color(nsColor: t.accent)).frame(width: 34, height: 4)
                                    Capsule().fill(SwiftUI.Color(nsColor: t.foreground).opacity(0.7)).frame(width: 52, height: 3)
                                    Capsule().fill(SwiftUI.Color(nsColor: t.foreground).opacity(0.4)).frame(width: 40, height: 3)
                                }
                                .padding(8)
                            }
                        }
                        .frame(height: 58)
                        .overlay(Rectangle().stroke(on ? SwiftUI.Color(nsColor: Theme.accent) : SwiftUI.Color(nsColor: Theme.paneDivider), lineWidth: on ? 2 : 1))
                        Text(t.name).font(.system(size: 11)).foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Agents

/// The agent CLIs Studio can run: which one new sessions open, and for each whether it's installed and
/// logged in, with a way to log in or install it.
private struct AgentSettings: View {
    @AppStorage(Pref.defaultAgent) private var agent = Agent.claude.rawValue
    @ObservedObject private var checker = AgentChecker.shared
    @State private var lastCheck = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(title: "Default agent",
                detail: "The CLI a new session opens: ⌘N, ⇧⌘K and the new_session tool. ⌘P → New Claude / Codex / Antigravity Session opens another one.") {
                Picker("", selection: $agent) {
                    ForEach(Agent.allCases) { a in
                        let missing = checker.status[a].map { !$0.checking && $0.path == nil } ?? false
                        Text(a.name + (missing ? " (CLI not found)" : "")).tag(a.rawValue)
                    }
                }
                .labelsHidden().fixedSize()
            }
            HStack {
                Group_(title: "Agent CLIs")
                Spacer()
                Button { refresh(force: true) } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).font(.system(size: 12)).padding(.top, 20).padding(.bottom, 2)
                    .disabled(checker.status.values.contains { $0.checking })
            }
            ForEach(Agent.allCases) { a in
                AgentRow(agent: a, status: checker.status[a] ?? .init(), isDefault: a.rawValue == agent)
            }
        }
        .onAppear { refresh(force: true) }
        // back from logging in, in a terminal: check again (at most every 10s)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh(force: false) }
    }

    private func refresh(force: Bool) {
        guard force || Date().timeIntervalSince(lastCheck) > 10 else { return }
        lastCheck = Date()
        checker.refresh()
    }
}

private struct AgentRow: View {
    let agent: Agent
    let status: AgentChecker.Status
    let isDefault: Bool
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(agent.name).font(.system(size: 13, weight: .semibold))
                if isDefault {
                    Text("Default").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(SwiftUI.Color(nsColor: Theme.accent).opacity(0.25))
                }
                Spacer()
                state
            }
            detail.font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if agent == .agy, status.path != nil, let tools = status.studioTools { agyTools(tools) }
            if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// agy has no per-session MCP option: Studio's tools and skills come as an agy plugin, installed on request.
    @ViewBuilder private func agyTools(_ installed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: installed ? "checkmark.circle.fill" : "puzzlepiece.extension")
                .foregroundStyle(installed ? SwiftUI.Color.green : SwiftUI.Color.secondary)
            Text(installed ? "Studio tools and skills installed in agy" : "Give agy Studio's tools and skills (the studio MCP server, workers, sandboxes)")
                .font(.system(size: 12))
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(installed ? "Remove" : "Install") {
                busy = true
                Task {
                    let err = installed ? await AgyPlugin.uninstall() : await AgyPlugin.install()
                    busy = false
                    note = err.map { "agy: \($0)" } ?? (installed ? "Removed from agy." : "Installed: new agy sessions have Studio's tools.")
                    AgentChecker.shared.refresh()
                }
            }
            .disabled(busy)
        }
    }

    @ViewBuilder private var state: some View {
        if status.checking {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
        } else if status.path == nil {
            pill("CLI not found", .secondary)
        } else if status.loggedIn == true {
            pill("Logged in" + (status.account.map { " · \($0)" } ?? ""), .green)
        } else {
            HStack(spacing: 8) {
                pill(status.loggedIn == false ? "Not logged in" : "Couldn't check login", .orange)
                Button("Log In…") { logIn() }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if status.checking { Text(" ") }
        else if let path = status.path {
            Text([status.version, abbreviatePath(path)].compactMap { $0 }.joined(separator: " · "))
        } else {
            HStack(spacing: 8) {
                Text(AgentChecker.installHint(agent))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentChecker.installHint(agent), forType: .string)
                    note = "Copied. Run it in a terminal, then Check Again."
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy")
            }
        }
    }

    private func pill(_ text: String, _ color: SwiftUI.Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(color == .secondary ? .secondary : .primary)
    }

    /// The login is interactive (a browser opens, or a code to paste): run it in a Studio terminal tab.
    private func logIn() {
        let cmd = AgentChecker.loginCommand(agent)
        if StudioControl.shared.openTerminal(running: cmd) {
            note = "Opened a terminal tab running `\(cmd)`. Finish there; this updates when you come back."
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            note = "No Studio window is open: `\(cmd)` is copied, run it in a terminal."
        }
    }
}

// MARK: - Workers

/// Machines running `studio-worker` (an always-on Linux box on Tailscale, Cloudflare Zero Trust or a LAN):
/// pair one with the link it prints, then start sessions on it from ⌘P, and let Studio's AIs hand work to it.
private struct WorkerSettings: View {
    @ObservedObject private var registry = WorkerRegistry.shared
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(title: "Add a worker",
                detail: "On the machine, run `studio-worker serve` (or `studio-worker install-service` to keep it running) and paste the studio://worker link it prints. The machine must be reachable from this Mac: on the same Tailscale tailnet, Cloudflare Zero Trust private network, or LAN.", wide: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("studio://worker?url=…&token=…", text: $link)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                            .onSubmit(add)
                        Button("Add Worker", action: add).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                }
            }
            Group_(title: "Connected workers")
            if registry.workers.isEmpty {
                Text("None yet. Install the worker on a Linux machine:")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                Text("curl -fsSL https://raw.githubusercontent.com/fiberevm/studio/main/install-worker.sh | sh")
                    .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).padding(.top, 4)
            }
            ForEach(registry.workers) { w in WorkerRow(worker: w) }
        }
    }

    private func add() {
        do { try registry.pair(link); link = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct WorkerRow: View {
    let worker: Worker
    @ObservedObject private var registry = WorkerRegistry.shared
    @State private var folder = ""
    @State private var confirmRemove = false

    var body: some View {
        let info = registry.info[worker.id]
        let sessions = registry.sessions[worker.id] ?? []
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text(worker.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(info != nil ? SwiftUI.Color.green : SwiftUI.Color.secondary).frame(width: 6, height: 6)
                    Text(info != nil ? "Online" : "Offline").font(.system(size: 12))
                }
                Button("Remove") { confirmRemove = true }.buttonStyle(.borderless).font(.system(size: 12))
            }
            Text(worker.url + (info.map { " · \($0.hostname) · \($0.os)/\($0.arch) · studio-worker \($0.version)" } ?? ""))
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if let info {
                HStack(spacing: 14) {
                    ForEach(Agent.allCases) { a in
                        let ai = info.agents[a.rawValue]
                        HStack(spacing: 4) {
                            Image(systemName: ai?.installed == true ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(ai?.installed == true ? SwiftUI.Color.green : SwiftUI.Color.secondary)
                            Text(a.name + (ai?.version.map { " \($0)" } ?? ""))
                        }
                        .font(.system(size: 12))
                    }
                }
                Text(sessions.isEmpty ? "No sessions" : "\(sessions.count) session\(sessions.count == 1 ? "" : "s"): " + sessions.prefix(3).map { $0.title ?? $0.id }.joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            } else if let err = registry.lastError[worker.id] {
                Text("Can't reach it: \(err)").font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Text("New sessions start in").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField(info?.home ?? "~", text: $folder)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 260)
                    .onSubmit { registry.setFolder(worker.id, folder) }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Hairline() }
        .onAppear { folder = worker.folder ?? "" }
        .alert("Remove \(worker.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { registry.remove(worker.id) }
        } message: {
            Text("Its sessions keep running on the machine; pair it again to see them.")
        }
    }
}

// MARK: - Sessions

private struct SessionSettings: View {
    @AppStorage(Pref.closeTabEndsSession) private var closeEnds = true
    @AppStorage(Pref.keepSessionsAlive) private var keepAlive = true
    @AppStorage(Pref.nativePermissionMode) private var nativeMode = ""
    @AppStorage(Pref.autoCloseEmptyPanes) private var autoClosePanes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(title: "Closing a tab ends its session",
                detail: "Off: the session keeps running in the background (reopen it from ⌘P). Right-click a tab for the other behavior either way.", isOn: $closeEnds)
            ToggleRow(title: "Close a pane when its last tab closes",
                detail: "The split closes and its neighbours take the room. Off: the empty pane stays, with shortcuts for a new session, terminal or browser.", isOn: $autoClosePanes)
            ToggleRow(title: "Keep sessions running when Studio quits",
                detail: SessionHost.tmux == nil
                    ? "Needs tmux (brew install tmux). Without it, quitting ends sessions and Studio resumes their conversations."
                    : "Each tab runs in a hidden tmux session, so restarting Studio reattaches instead of interrupting Claude, its commands and dev servers. Applies to new tabs.", isOn: $keepAlive, disabled: SessionHost.tmux == nil)
            Row(title: "Native view permission mode",
                detail: "What Claude may do without asking when a session is in the native view (⌘/).") {
                Picker("", selection: $nativeMode) {
                    Text("Same as the session").tag("")
                    Text("Supervised").tag("default")
                    Text("Auto").tag("auto")
                    Text("Auto-accept edits").tag("acceptEdits")
                    Text("Full access").tag("bypassPermissions")
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}

/// Per project: the branch new session worktrees start from.
struct StartBranchSettings: View {
    struct Repo: Identifiable { let path: String; let branches: [String]; let fallback: String; var id: String { path } }
    @State private var repos: [Repo]?
    @State private var choice: [String: String] = [:]

    var body: some View {
        Row(title: "Start branch",
            detail: "The branch each project's new worktrees start from. Default is the repo's default branch (origin's HEAD, else main or master); Current branch follows whatever the project folder has checked out.", wide: true) {
            if let repos {
                if repos.isEmpty {
                    Text("No git projects yet. Open one and it shows up here.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(repos) { r in
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text((r.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium))
                                Text((r.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Picker("", selection: Binding(get: { choice[r.path] ?? "" }, set: {
                                choice[r.path] = $0; Worktrees.setStartBranch($0, for: r.path)
                            })) {
                                Text("Default (\(r.fallback))").tag("")
                                Text("Current branch").tag(Worktrees.currentBranch)
                                Divider()
                                ForEach(r.branches, id: \.self) { Text($0).tag($0) }
                                let saved = choice[r.path] ?? ""
                                if !saved.isEmpty, saved != Worktrees.currentBranch, !r.branches.contains(saved) { Text(saved).tag(saved) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            let found = await Task.detached { () -> [Repo] in
                var seen = Set<String>()
                return RecentProjects.list().compactMap { f in
                    guard let top = Worktrees.repoRoot(f), seen.insert(top).inserted else { return nil }
                    return Repo(path: top, branches: Worktrees.branches(top), fallback: Worktrees.defaultBranch(top) ?? "current branch")
                }
            }.value
            choice = Dictionary(uniqueKeysWithValues: found.map { ($0.path, Worktrees.startBranch($0.path)) })
            repos = found
        }
    }
}

// MARK: - Sandboxes

private struct SandboxSettings: View {
    @ObservedObject var registry: SandboxRegistry
    @AppStorage(Pref.sandboxEnabled) private var enabled = true
    @AppStorage(Pref.sandboxType) private var type = "small"
    @AppStorage(Pref.sandboxTTL) private var ttl = 60
    @AppStorage(Pref.sandboxEnvironment) private var environment = ""
    @AppStorage(Pref.sandboxPolicy) private var policy = "auto"
    @AppStorage("sandbox.defaultProvider") private var defaultProvider = "boat"
    @State private var status: [String: Any]?
    @State private var loading = false
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude sessions in Studio can run work in remote sandboxes through Studio's sandbox tools. Each session's sandboxes show in its status bar.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Group_(title: "Providers")
            providerCard
            AWSProviderCard(provider: registry.aws)
            Row(title: "Default provider", detail: "Where new sandboxes go unless Claude or you pick one.") {
                Picker("", selection: $defaultProvider) {
                    Text("Boat").tag("boat")
                    Text("AWS Lambda MicroVMs").tag("aws")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 300)
            }

            Group_(title: "When Claude uses sandboxes")
            Row(title: "Policy", detail: policy == "auto"
                    ? "Claude may create a sandbox on its own for builds, tests and risky commands, and stops it when done."
                    : "Claude uses a session's existing sandboxes, and creates one only when you ask.") {
                Picker("", selection: $policy) {
                    Text("When helpful").tag("auto")
                    Text("Only when I ask").tag("ask")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 240)
            }

            Group_(title: "New sandboxes")
            Row(title: "Machine size", detail: "small: 2 vCPU / 4 GB, half rate · default: 4 / 8 · large: 8 / 16, 2× · xlarge: 16 / 32") {
                Picker("", selection: $type) {
                    ForEach(["small", "default", "large", "xlarge"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Row(title: "Auto-stop after", detail: "Stops (and snapshots) an idle sandbox so it doesn't keep billing. 0 uses Boat's default.") {
                Stepper(ttl == 0 ? "Boat default" : "\(ttl) min", value: $ttl, in: 0...1440, step: 15)
            }
            Row(title: "Environment", detail: "A named Boat environment (repos, env vars, secrets). Empty uses your default.") {
                TextField("base", text: $environment).textFieldStyle(.roundedBorder).frame(width: settingsMenuWidth)
            }
        }
        .task { await load() }
    }

    private var providerCard: some View {
        let installed = registry.boat.installed
        let account = status?["account"] as? [String: Any]
        let signedIn = account?["signedIn"] as? Bool ?? false
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sailboat.fill").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Boat").font(.system(size: 14, weight: .semibold))
                    Text("boat.dev").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !installed {
                    Text("The boat CLI isn't installed.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if loading && status == nil {
                    Text("Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if signedIn {
                    let who = account?["identifier"] as? String ?? ""
                    let plan = account?["plan"] as? String ?? ""
                    Text("Signed in as \(who)\(plan.isEmpty ? "" : " · \(plan)")").font(.system(size: 12)).foregroundStyle(.secondary)
                    if let hours = status?["creditHours"] as? Double {
                        Text(String(format: "%.0f hours of credit left", hours)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not signed in.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if !installed {
                        Button("Get Boat…") { NSWorkspace.shared.open(URL(string: "https://boat.dev")!) }
                    } else {
                        if !signedIn && !loading { Button("Sign In…") { runInTerminal("boat login") } }
                        Button("Dashboard") { NSWorkspace.shared.open(URL(string: "https://boat.dev/dashboard")!) }
                        Button("Refresh") { Task { await load() } }
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
            // Off while Boat isn't connected (the stored choice comes back once it is).
            let connected = installed && (signedIn || !checked)
            StudioToggle(isOn: Binding(get: { enabled && connected }, set: { enabled = $0 }))
                .disabled(!connected)
                .help(!connected ? "Sign in to Boat to use its sandboxes"
                      : enabled ? "Sessions can use Boat sandboxes" : "Sandbox tools are turned off")
        }
        .padding(14)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.paneDivider), lineWidth: 1))
        .padding(.top, 6)
    }

    private func load() async {
        guard registry.boat.installed else { return }
        loading = true
        status = await registry.boat.status()
        loading = false
        checked = true
    }

    private func runInTerminal(_ cmd: String) {
        let script = "tell application \"Terminal\" to do script \"\(cmd)\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

/// AWS Lambda MicroVMs: account, region/profile, the Studio image, Set Up.
private struct AWSProviderCard: View {
    let provider: AWSMicroVMProvider
    @AppStorage("sandbox.aws.enabled") private var enabled = true
    @AppStorage("sandbox.aws.profile") private var profile = ""
    @AppStorage("sandbox.aws.region") private var region = ""
    @AppStorage("sandbox.aws.imageArn") private var imageArn = ""
    @State private var account: String?
    @State private var checking = false
    @State private var checked = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "cloud").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("AWS Lambda MicroVMs").font(.system(size: 14, weight: .semibold))
                    Text("Firecracker VMs · up to 8 h · suspend/resume").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Group {
                    if !provider.cliInstalled { Text("The AWS CLI isn't installed (brew install awscli).") }
                    else if checking && account == nil { Text("Checking credentials…") }
                    else if let account { Text("AWS account \(account)") }
                    else { Text("No AWS credentials. Run `aws login` (or set a profile below).") }
                    Text(imageArn.isEmpty ? "Studio image not set up yet." : "Image: \(imageArn.split(separator: ":").last ?? "")")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("profile (default)", text: $profile).textFieldStyle(.roundedBorder).frame(width: 140)
                    TextField("region (us-east-1)", text: $region).textFieldStyle(.roundedBorder).frame(width: 140)
                }
                HStack(spacing: 8) {
                    if !provider.cliInstalled {
                        Button("Get the AWS CLI…") { NSWorkspace.shared.open(URL(string: "https://aws.amazon.com/cli/")!) }
                    } else {
                        if account == nil { Button("Sign In…") { runInTerminal("aws login" + (profile.isEmpty ? "" : " --profile \(profile)")) } }
                        Button(imageArn.isEmpty ? "Set Up…" : "Rebuild Image…") { runSetup() }
                            .help("Creates an S3 bucket, two IAM roles and the studio-sandbox MicroVM image in your account")
                        Button("Refresh") { Task { await check() } }
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
            // Off while AWS isn't connected (the stored choice comes back once it is).
            let connected = provider.installed && (account != nil || !checked)
            StudioToggle(isOn: Binding(get: { enabled && connected }, set: { enabled = $0 }))
                .disabled(!connected)
                .help(!connected ? "Sign in to AWS and set up the image to use MicroVMs"
                      : enabled ? "Sessions can use AWS MicroVMs" : "AWS MicroVMs are turned off")
        }
        .padding(14)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.paneDivider), lineWidth: 1))
        .padding(.top, 8)
        .task { await check() }
    }

    private func check() async {
        checking = true
        account = (await provider.status())?["account"] as? String
        checking = false
        checked = true
    }

    /// Runs Resources/MicroVMAgent/setup.sh in Terminal so you see what it creates.
    private func runSetup() {
        guard let dir = Bundle.main.resourcePath.map({ $0 + "/MicroVMAgent" }) else { return }
        var env = "STUDIO_DOMAIN=\(Bundle.main.bundleIdentifier ?? "dev.local.studio")"
        if !profile.isEmpty { env += " AWS_PROFILE=\(profile)" }
        if !region.isEmpty { env += " AWS_REGION=\(region)" }
        runInTerminal("\(env) bash '\(dir)/setup.sh'")
    }

    private func runInTerminal(_ cmd: String) {
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

// MARK: - Telemetry

private struct TelemetrySettings: View {
    @AppStorage(Telemetry.pref) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(title: "Share anonymous usage data",
                      detail: "Helps us see which parts of Studio get used and what to improve. It never includes your code, prompts, file or project names, or anything else about your work.",
                      isOn: $enabled)
            Group_(title: "What is sent")
            VStack(alignment: .leading, spacing: 6) {
                bullet("A random id for this install, made up when Studio first runs")
                bullet("Studio's version, whether it's a release or built from source, the macOS version and the chip type")
                bullet("When Studio opens, and when a session opens: which agent (Claude Code, Codex or Antigravity), whether it is new, resumed, forked or reopened, and whether it got a worktree")
                bullet("How many tokens your sessions sent and received, added up per agent every few minutes (counts only)")
            }
            .padding(.vertical, 10)
            Group_(title: "What is never sent")
            VStack(alignment: .leading, spacing: 6) {
                bullet("Prompts, replies, code, terminal output, secrets")
                bullet("File, folder, project or branch names, and paths")
                bullet("Your name, email, IP-based location or any account")
            }
            .padding(.vertical, 10)
            Text("Events go to PostHog. Turning this off stops them at once.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(s).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            about
            Text("Updates, release notes and earlier versions are in Settings → Updates.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
    private var about: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("Studio").font(.system(size: 16, weight: .semibold))
                Text("A native macOS workspace for running many Claude Code sessions at once.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("github.com/fiberevm/studio") { NSWorkspace.shared.open(URL(string: "https://github.com/fiberevm/studio")!) }
                    .buttonStyle(.link)
            }
        }
    }
}
