import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // needed when run as a bare SwiftPM executable
        // A background preview copy (--order-front, launched with `open -g`) must never take focus.
        if !CommandLine.arguments.contains("--order-front") { NSApp.activate(ignoringOtherApps: true) }
        else {
            // Background preview copies must never keep keyboard focus, even if macOS activates them on relaunch.
            // Start once launch has settled: deactivating during launch stops SwiftUI opening the first window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if NSApp.isActive { NSApp.deactivate() }
                NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                    NSApp.deactivate()
                }
            }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quit only once every session has actually exited. Otherwise a quick relaunch sees them still running,
    /// takes them for sessions running elsewhere, and doesn't reopen their tabs.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { SessionStore.terminating = true }
        let pids = MainActor.assumeIsolated { SessionStore.current?.terminals.flatMap(\.livePids) ?? [] }
        guard !pids.isEmpty else { return .terminateNow }
        pids.forEach { kill($0, SIGHUP) }
        let deadline = Date().addingTimeInterval(6)
        func check() {
            let alive = pids.filter { kill($0, 0) == 0 }
            if alive.isEmpty || Date() > deadline {
                alive.forEach { kill($0, SIGKILL) }
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
            }
        }
        check()
        return .terminateLater
    }
}

@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = SessionStore()

    init() { Self.migrateSettingsFromAICode(); LaunchEnv.refreshIfStale() }

    /// The app used to be called AICode (bundle id dev.local.aicode). Carry over saved tabs, theme, recents, etc. once.
    static func migrateSettingsFromAICode() {
        let d = UserDefaults.standard
        // Only the real app: a preview copy must never inherit the user's saved tabs.
        guard Bundle.main.bundleIdentifier == "dev.local.studio",
              !d.bool(forKey: "migratedFromAICode"), let old = UserDefaults(suiteName: "dev.local.aicode") else { return }
        for key in ["openTerminals", "recentProjects", "theme", "fontSize", "busyExpanded"] {
            if d.object(forKey: key) == nil, let v = old.object(forKey: key) { d.set(v, forKey: key) }
        }
        d.set(true, forKey: "migratedFromAICode")
    }

    var body: some Scene {
        // One window per project folder. The folder is the window's value, so it survives relaunch,
        // and opening a folder that already has a window brings that window forward.
        WindowGroup("Studio", for: String.self) { $folder in
            ProjectWindow(folder: $folder)
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1400, height: 900)
        .commands { AppCommands(store: store) }

        // ⌘, (Studio → Settings…)
        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var store: SessionStore
    @FocusedObject private var project: ProjectModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { project?.newTab() }
                .keyboardShortcut("n")
                .disabled(project == nil)
            Button("New Tab") { project?.newTab() }
                .keyboardShortcut("t")
                .disabled(project == nil)
            Button("Fork Session to the Right") { project?.fork() }
                .keyboardShortcut("e")
                .disabled(project == nil)
            Button("Toggle Native View") { project?.toggleNative() }
                .keyboardShortcut("/")
                .disabled(project == nil)
            Menu("New") {
                ForEach(Agent.allCases) { a in
                    Button("\(a.name) Session") { project?.newTab(a) }
                        .keyboardShortcut(NewTabKind.agent(a).shortcut)
                        .disabled(project == nil || !AgentChecker.shared.isInstalled(a))
                }
                Divider()
                Button("Terminal") { project?.newShellTab() }
                    .keyboardShortcut(NewTabKind.terminal.shortcut)
                    .disabled(project == nil)
                Button("Web Browser") { project?.openWeb(nil, zone: .center) }
                    .keyboardShortcut(NewTabKind.browser.shortcut)
                    .disabled(project == nil)
            }
            Button("Open Project…") {
                if let f = pickFolder(prompt: "Open", startingAt: project.map { ($0.folder as NSString).deletingLastPathComponent }) {
                    openWindow(value: f)
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Menu("Open Recent Project") {
                ForEach(RecentProjects.list(), id: \.self) { f in
                    Button(abbreviatePath(f)) { openWindow(value: f) }
                }
            }

            Button("End Session") { if let t = project?.selectedTerminal { project?.endSession(t) } }
                .disabled(project?.selectedTerminal == nil)
        }
        // ⌘W closes the tab (the session keeps running); with no tab open it closes the window, like VS Code.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if let p = project, p.selectedTerminal != nil { p.closeSelectedTab() }
                else if let p = project, p.groups.count > 1 { p.closePane(p.activeGroup) }
                else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(before: .sidebar) {
            Button("Toggle Sidebar") { project?.sidebarVisible.toggle() }
                .keyboardShortcut("b")
                .disabled(project == nil)
            Button("Equalize Pane Sizes") { project?.equalize() }
                .disabled(project == nil)
            Button("Single Pane") { project?.applyPreset(.single) }
                .disabled(project == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { store.fontSize = min(store.fontSize + 1, 24) }
                .keyboardShortcut("+")
            Button("Smaller Text") { store.fontSize = max(store.fontSize - 1, 9) }
                .keyboardShortcut("-")
            Button("Default Text Size") { store.fontSize = 12 }
                .keyboardShortcut("0")
        }
        CommandGroup(before: .toolbar) {
            Button("Go to Session…") { project?.palette = "" }
                .keyboardShortcut("p")
                .disabled(project == nil)
            Button("Next Up: Session Waiting for You") { project?.goToNextUp() }
                .keyboardShortcut("j")
                .disabled(project == nil)
            Button("Quick Prompt…") { project?.palette = nil; project?.quickPrompt = true }
                .keyboardShortcut("k")
                .disabled(project == nil)
            Button("Command Palette…") { project?.palette = ">" }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(project == nil)
            Divider()
        }
        CommandMenu("Tab") {
            Button("Previous Tab") { project?.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { project?.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
            ForEach(Array((project?.tabs ?? []).prefix(9).enumerated()), id: \.offset) { i, t in
                Button(project?.item(for: t)?.title ?? "New session") { project?.selectTab(i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
    }
}
