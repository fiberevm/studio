import AppKit

/// The project windows that are open, and where each was on screen, so a relaunch brings back exactly those
/// windows at their size and place. A window joins the list when it opens and leaves it when you close it;
/// quitting keeps the list as it is. (Saved tabs are a separate thing: a closed project's sessions keep running
/// and its tabs come back whenever you open it again.)
@MainActor
enum OpenWindows {
    private static let key = "openProjectWindows"
    private static func frameKey(_ folder: String) -> String { "windowFrame:" + folder }
    /// A throwaway side-by-side copy (--no-restore) never changes what the real app reopens.
    private static var frozen: Bool { CommandLine.arguments.contains("--no-restore") }

    /// The folders to reopen, in the order they were opened; nil before this list was first written.
    static var list: [String]? { UserDefaults.standard.stringArray(forKey: key) }

    static func opened(_ folder: String) {
        guard !frozen else { return }
        var l = list ?? []
        if !l.contains(folder) { l.append(folder); UserDefaults.standard.set(l, forKey: key) }
    }

    static func closed(_ folder: String) {
        guard !frozen, !SessionStore.terminating else { return }
        let l = list ?? []
        // closing the last window quits Studio: that one comes back next time, as if you had quit
        guard l.contains(where: { $0 != folder }) else { return }
        UserDefaults.standard.set(l.filter { $0 != folder }, forKey: key)
    }

    static func saveFrame(_ w: NSWindow, folder: String) {
        guard !frozen, w.isVisible, !w.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: frameKey(folder))
    }

    /// Put the window where it was last time, if that place is still on a screen.
    static func restoreFrame(_ w: NSWindow, folder: String) {
        guard let s = UserDefaults.standard.string(forKey: frameKey(folder)) else { return }
        let r = NSRectFromString(s)
        guard r.width >= 400, r.height >= 300,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersection(r).width >= 200 }) else { return }
        w.setFrame(r, display: true)
    }
}
