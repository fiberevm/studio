import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // needed when run as a bare SwiftPM executable
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = SessionStore()

    init() { Self.migrateSettingsFromAICode() }

    /// The app used to be called AICode (bundle id dev.local.aicode). Carry over saved tabs, theme, recents, etc. once.
    static func migrateSettingsFromAICode() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromAICode"), let old = UserDefaults(suiteName: "dev.local.aicode") else { return }
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
                else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
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
            Button("Command Palette…") { project?.palette = ">" }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(project == nil)
            Divider()
        }
        CommandMenu("Tab") {
            Button("Previous Tab") { project?.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Tab") { project?.cycleTab(1) }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            ForEach(Array((project?.tabs ?? []).prefix(9).enumerated()), id: \.offset) { i, t in
                Button(project?.item(for: t)?.title ?? "New session") { project?.selectTab(i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
    }
}
