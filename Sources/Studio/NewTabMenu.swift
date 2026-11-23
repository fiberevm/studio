import AppKit
import SwiftUI

/// What + can open, with its shortcut. The same list backs the + dropdowns and the File menu,
/// so the shortcuts shown in the dropdown are the ones that work everywhere.
enum NewTabKind: Hashable {
    case agent(Agent), terminal, browser, files

    var title: String {
        switch self {
        case .agent(let a): return "\(a.name) Session"
        case .terminal: return "Terminal"
        case .browser: return "Web Browser"
        case .files: return "Files"
        }
    }
    var icon: String {
        switch self {
        case .agent(.claude): return "sparkle"
        case .agent(.codex): return "chevron.left.forwardslash.chevron.right"
        case .agent(.agy): return "atom"
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .files: return "folder"
        }
    }
    /// ⌘N opens the default agent; each agent also has ⌃⌘1/2/3.
    var key: (String, NSEvent.ModifierFlags) {
        switch self {
        case .agent(let a): return (String((Agent.allCases.firstIndex(of: a) ?? 0) + 1), [.control, .command])
        case .terminal: return ("`", [.control])
        case .browser: return ("b", [.command, .shift])
        case .files: return ("e", [.command, .shift])    // VS Code's Explorer shortcut
        }
    }
    /// "⌃⌘1", "⌃`", "⇧⌘B"
    var keyLabel: String {
        let (k, m) = key
        return (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "")
            + (m.contains(.command) ? "⌘" : "") + k.uppercased()
    }
    var shortcut: KeyboardShortcut {
        let (k, m) = key
        var mods: EventModifiers = []
        if m.contains(.command) { mods.insert(.command) }
        if m.contains(.control) { mods.insert(.control) }
        if m.contains(.shift) { mods.insert(.shift) }
        if m.contains(.option) { mods.insert(.option) }
        return KeyboardShortcut(KeyEquivalent(Character(k)), modifiers: mods)
    }

    /// Installed agents (default first), then Terminal, Web Browser and Files.
    @MainActor static var available: [NewTabKind] {
        let check = AgentChecker.shared
        let agents = [Agent.preferred] + Agent.allCases.filter { $0 != Agent.preferred }
        return agents.filter(check.isInstalled).map(NewTabKind.agent) + [.terminal, .browser, .files]
    }

    @MainActor func open(in model: ProjectModel) {
        switch self {
        case .agent(let a): model.newTab(a)
        case .terminal: model.newShellTab()
        case .browser: model.openWeb(nil, zone: .center)
        case .files: model.openFiles()
        }
    }
}

/// The + button: a dropdown of everything a new tab can be. `before` runs first (e.g. activate the pane).
struct NewTabButton: View {
    let width: CGFloat
    let height: CGFloat
    var help = "New tab"
    var before: () -> Void = {}
    @EnvironmentObject var model: ProjectModel

    var body: some View {
        Button { popUp() } label: {
            Image(systemName: "plus").font(.system(size: 12)).frame(width: width, height: height).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func popUp() {
        before()
        let menu = NSMenu()
        let target = MenuTarget.shared
        target.model = model
        for (i, kind) in NewTabKind.available.enumerated() {
            if kind == .terminal { menu.addItem(.separator()) }
            let item = NSMenuItem(title: kind.title, action: #selector(MenuTarget.open(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = kind
            item.image = NSImage(systemSymbolName: kind.icon, accessibilityDescription: nil)
            let (k, m) = i == 0 ? ("n", NSEvent.ModifierFlags.command) : kind.key   // the default agent is ⌘N
            item.keyEquivalent = k
            item.keyEquivalentModifierMask = m
            menu.addItem(item)
        }
        let reg = WorkerRegistry.shared
        if !reg.workers.isEmpty {
            menu.addItem(.separator())
            for w in reg.workers {
                let online = reg.isOnline(w.id)
                let item = NSMenuItem(title: "On \(w.name)" + (online ? "" : " (offline)"), action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
                let sub = NSMenu()
                let has = reg.info[w.id]?.agents
                for a in Agent.allCases where has?[a.rawValue]?.installed ?? (a == .claude) {
                    let s = NSMenuItem(title: "\(a.name) Session", action: #selector(MenuTarget.openWorker(_:)), keyEquivalent: "")
                    s.target = target
                    s.representedObject = [w.id, a.rawValue]
                    s.isEnabled = online
                    sub.addItem(s)
                }
                item.submenu = sub
                item.isEnabled = online
                menu.addItem(item)
            }
        }
        guard let e = NSApp.currentEvent, let v = e.window?.contentView else { return }
        menu.popUp(positioning: nil, at: v.convert(e.locationInWindow, from: nil), in: v)
    }
}

@MainActor
private final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    weak var model: ProjectModel?

    @objc func open(_ sender: NSMenuItem) {
        guard let m = model, let k = sender.representedObject as? NewTabKind else { return }
        k.open(in: m)
    }

    @objc func openWorker(_ sender: NSMenuItem) {
        guard let m = model, let p = sender.representedObject as? [String], p.count == 2,
              let w = WorkerRegistry.shared.worker(p[0]), let a = Agent(rawValue: p[1]) else { return }
        Task { @MainActor in
            do { _ = try await m.newWorkerSession(w, agent: a) } catch { m.showToast(error.localizedDescription) }
        }
    }
}
