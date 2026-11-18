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

    static func bool(_ k: String, default d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    static func string(_ k: String) -> String? {
        let s = UserDefaults.standard.string(forKey: k) ?? ""
        return s.isEmpty ? nil : s
    }
}

/// ⌘, — a VS Code / System Settings style window: sections on the left, the section on the right.
struct SettingsView: View {
    @EnvironmentObject var store: SessionStore
    // debug/screenshot aid: --settings <section> opens Settings on that section
    @State private var section: Section = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--settings"), i + 1 < a.count,
           let s = Section.allCases.first(where: { $0.rawValue.lowercased() == a[i + 1].lowercased() }) { return s }
        return .appearance
    }()

    enum Section: String, CaseIterable, Identifiable {
        case appearance = "Appearance", sessions = "Sessions", sandboxes = "Sandboxes", snippets = "Snippets", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appearance: return "paintbrush"
            case .sessions: return "rectangle.stack"
            case .sandboxes: return "sailboat"
            case .snippets: return "text.quote"
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
                        case .sessions: SessionSettings()
                        case .sandboxes: SandboxSettings(registry: store.sandboxes)
                        case .snippets: SnippetSettings()
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
private struct Row<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            control().padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct Group_: View {
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
                .labelsHidden().frame(width: 200)
            }
            Row(title: "Text size", detail: "Terminals and the native view. ⌘+ / ⌘− / ⌘0.") {
                Stepper("\(Int(store.fontSize)) pt", value: $store.fontSize, in: 9...24, step: 1).frame(width: 120)
            }
            Group_(title: "Layout")
            Row(title: "Show session sidebar",
                detail: "A list of the project's sessions on the left: who's waiting for you, and what's busy. Applies to every window; ⌘B toggles it in one window.") {
                Toggle("", isOn: $sidebar).labelsHidden().toggleStyle(.switch)
            }
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

// MARK: - Sessions

private struct SessionSettings: View {
    @AppStorage(Pref.closeTabEndsSession) private var closeEnds = true
    @AppStorage(Pref.keepSessionsAlive) private var keepAlive = true
    @AppStorage(Pref.nativePermissionMode) private var nativeMode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(title: "Closing a tab ends its session",
                detail: "Off: the session keeps running in the background (reopen it from ⌘P). Right-click a tab for the other behavior either way.") {
                Toggle("", isOn: $closeEnds).labelsHidden().toggleStyle(.switch)
            }
            Row(title: "Keep sessions running when Studio quits",
                detail: SessionHost.tmux == nil
                    ? "Needs tmux (brew install tmux). Without it, quitting ends sessions and Studio resumes their conversations."
                    : "Each tab runs in a hidden tmux session, so restarting Studio reattaches instead of interrupting Claude, its commands and dev servers. Applies to new tabs.") {
                Toggle("", isOn: $keepAlive).labelsHidden().toggleStyle(.switch).disabled(SessionHost.tmux == nil)
            }
            Row(title: "Native view permission mode",
                detail: "What Claude may do without asking when a session is in the native view (⌘/).") {
                Picker("", selection: $nativeMode) {
                    Text("Same as the session").tag("")
                    Text("Supervised").tag("default")
                    Text("Auto").tag("auto")
                    Text("Auto-accept edits").tag("acceptEdits")
                    Text("Full access").tag("bypassPermissions")
                }
                .labelsHidden().frame(width: 200)
            }
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
    @State private var status: [String: Any]?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude sessions in Studio can run work in remote sandboxes through Studio's sandbox tools. Each session's sandboxes show in its status bar.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Group_(title: "Providers")
            providerCard

            Group_(title: "When Claude uses sandboxes")
            Row(title: "Policy", detail: policy == "auto"
                    ? "Claude may create a sandbox on its own for builds, tests and risky commands, and stops it when done."
                    : "Claude uses a session's existing sandboxes, and creates one only when you ask.") {
                Picker("", selection: $policy) {
                    Text("When helpful").tag("auto")
                    Text("Only when I ask").tag("ask")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 230)
            }

            Group_(title: "New sandboxes")
            Row(title: "Machine size", detail: "small: 2 vCPU / 4 GB, half rate · default: 4 / 8 · large: 8 / 16, 2× · xlarge: 16 / 32") {
                Picker("", selection: $type) {
                    ForEach(["small", "default", "large", "xlarge"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
            Row(title: "Auto-stop after", detail: "Stops (and snapshots) an idle sandbox so it doesn't keep billing. 0 uses Boat's default.") {
                Stepper(ttl == 0 ? "Boat default" : "\(ttl) min", value: $ttl, in: 0...1440, step: 15).frame(width: 150)
            }
            Row(title: "Environment", detail: "A named Boat environment (repos, env vars, secrets). Empty uses your default.") {
                TextField("base", text: $environment).textFieldStyle(.roundedBorder).frame(width: 160)
            }
        }
        .task { await load() }
    }

    private var providerCard: some View {
        let installed = registry.provider.installed
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
            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch).disabled(!installed)
                .help(enabled ? "Sessions can use Boat sandboxes" : "Sandbox tools are turned off")
        }
        .padding(14)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.paneDivider), lineWidth: 1))
        .padding(.top, 6)
    }

    private func load() async {
        guard registry.provider.installed else { return }
        loading = true
        status = await registry.provider.status()
        loading = false
    }

    private func runInTerminal(_ cmd: String) {
        let script = "tell application \"Terminal\" to do script \"\(cmd)\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

// MARK: - Snippets

private struct SnippetSettings: View {
    @State private var list = Snippets.all
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reusable prompts. Type # in ⌘K to insert one, or pick \"Snippet: …\" in ⌘P to send it to the current session.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach($list) { $s in
                HStack(alignment: .top, spacing: 10) {
                    TextField("name", text: $s.name).textFieldStyle(.roundedBorder).frame(width: 120)
                    TextField("prompt", text: $s.text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                    Button { list.removeAll { $0.id == s.id }; save() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Delete")
                }
                .onChange(of: s) { _, _ in save() }
            }
            HStack {
                Button("Add Snippet") { list.append(Snippet(name: "new-\(list.count + 1)", text: "")); save() }
                Button("Open File") { NSWorkspace.shared.open(Snippets.file) }
                Button("Reset to Defaults") { list = Snippets.defaults; save() }
            }
            .padding(.top, 6)
        }
    }

    private func save() {
        Snippets.all = list.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
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
