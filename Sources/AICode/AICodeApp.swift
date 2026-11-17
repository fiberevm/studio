import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // needed when run as a bare SwiftPM executable
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AICodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = SessionStore()

    var body: some Scene {
        Window("AICode", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1400, height: 900)
        .commands { SessionCommands(store: store) }
    }
}

struct SessionCommands: Commands {
    @ObservedObject var store: SessionStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { store.newSessionPickingFolder() }
                .keyboardShortcut("n")
            Button("New Session in Same Folder") {
                let cwd = store.selectedTerminal?.cwd
                    ?? store.selectedSessionId.flatMap { store.records[$0]?.cwd ?? store.live[$0]?.cwd }
                if let cwd { store.newSession(in: cwd) } else { store.newSessionPickingFolder() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { store.fontSize = min(store.fontSize + 1, 24) }
                .keyboardShortcut("+")
            Button("Smaller Text") { store.fontSize = max(store.fontSize - 1, 9) }
                .keyboardShortcut("-")
            Button("Default Text Size") { store.fontSize = 12 }
                .keyboardShortcut("0")
        }
        CommandMenu("Session") {
            Button("Resume Selected") { if let sid = store.selectedSessionId { store.resume(sid) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Close Terminal") { store.closeSelected() }
                .keyboardShortcut("w", modifiers: [.command, .option])
            Divider()
            Button("Previous Active Session") { cycle(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Active Session") { cycle(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
            ForEach(Array(store.activeItems.prefix(9).enumerated()), id: \.offset) { i, item in
                Button(item.title) { store.selection = item.key }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
    }

    private func cycle(_ d: Int) {
        let items = store.activeItems
        guard !items.isEmpty else { return }
        let idx = items.firstIndex { $0.key == store.selection } ?? (d > 0 ? -1 : 0)
        store.selection = items[(idx + d + items.count) % items.count].key
    }
}
