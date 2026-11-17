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
struct AICodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = SessionStore()

    var body: some Scene {
        // One window per project folder. The folder is the window's value, so it survives relaunch,
        // and opening a folder that already has a window brings that window forward.
        WindowGroup("AICode", for: String.self) { $folder in
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
            Button("New Tab") { project?.newTab() }
                .keyboardShortcut("t")
                .disabled(project == nil)
            Button("Open Project…") {
                if let f = pickFolder(prompt: "Open", startingAt: project.map { ($0.folder as NSString).deletingLastPathComponent }) {
                    openWindow(value: f)
                }
            }
            .keyboardShortcut("n")
            Menu("Open Recent Project") {
                ForEach(RecentProjects.list(), id: \.self) { f in
                    Button(abbreviatePath(f)) { openWindow(value: f) }
                }
            }
            Divider()
            Button("Close Tab") { project?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(project?.selectedTerminal == nil)
            Button("End Session") { if let t = project?.selectedTerminal { project?.endSession(t) } }
                .disabled(project?.selectedTerminal == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { store.fontSize = min(store.fontSize + 1, 24) }
                .keyboardShortcut("+")
            Button("Smaller Text") { store.fontSize = max(store.fontSize - 1, 9) }
                .keyboardShortcut("-")
            Button("Default Text Size") { store.fontSize = 12 }
                .keyboardShortcut("0")
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
