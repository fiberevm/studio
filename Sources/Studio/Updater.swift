import SwiftUI
import Sparkle

/// In-app updates through Sparkle: checks the appcast on the latest GitHub release in the background,
/// downloads a new version, verifies its signature and installs it when Studio quits. Since Studio is rarely
/// quit, a downloaded update is announced in the title bar ("Update to 0.2.0"), one click from a restart.
/// Studio draws its own update window (UpdateWindow, in the active theme) by being Sparkle's user driver.
/// Only release builds update themselves: the release workflow writes SUFeedURL and SUPublicEDKey into
/// Info.plist, a local build (./build-app.sh) has neither, so a build from source is never replaced; Check for
/// Updates there still reports the latest release.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUUserDriver {
    static let shared = Updater()
    static let feed = URL(string: "https://github.com/fiberevm/studio/releases/latest/download/appcast.xml")!
    static let releases = URL(string: "https://github.com/fiberevm/studio/releases/latest")!

    /// A new version that is downloaded and waiting for a restart.
    struct Ready: Equatable { let version: String; let notes: URL? }

    /// What the update window shows.
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// A newer version exists: not downloaded yet, or downloaded and waiting to install.
        case available(version: String, downloaded: Bool)
        case downloading(received: UInt64, expected: UInt64?)
        case extracting(Double)
        case installing
        case failed(String)
        /// A build from source: the latest release, which this copy can't install itself.
        case sourceBuild(latest: String?)
    }

    private var updater: SPUUpdater?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notes: URL?
    @Published private(set) var ready: Ready?
    /// The user chose "Later": no nudge until the next launch (the update still installs on quit).
    @Published var snoozed = false
    private var installNow: (() -> Void)?
    /// What answers the open question in the window: install, later, skip.
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancel: (() -> Void)?
    /// The user pressed Install Now: install as soon as the download is ready, without asking again.
    private var installWhenReady = false
    /// Download and install new versions without asking (they take effect at the next launch).
    @Published var automatic = false {
        didSet {
            guard let u = updater, automatic != oldValue else { return }
            u.automaticallyChecksForUpdates = automatic
            u.automaticallyDownloadsUpdates = automatic
        }
    }

    /// False in builds without an update feed (built from source, preview copies).
    var enabled: Bool { updater != nil }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    private override init() {
        super.init()
        let info = Bundle.main
        guard info.object(forInfoDictionaryKey: "SUFeedURL") is String,
              info.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do { try u.start() } catch { debugLog("updater failed to start: \(error)"); return }
        updater = u
        automatic = u.automaticallyChecksForUpdates && u.automaticallyDownloadsUpdates
    }

    /// Studio → Check for Updates…: always available. Opens the update window and checks; while an update is
    /// already downloading or waiting, the window shows that instead.
    func checkForUpdates() {
        UpdateWindow.show()
        guard let u = updater else { checkLatestRelease(); return }
        if ready != nil, case .idle = phase { phase = .available(version: ready!.version, downloaded: true); return }
        switch phase {
        case .checking, .downloading, .extracting, .installing: return     // already on screen
        default: break
        }
        if u.canCheckForUpdates { phase = .checking; u.checkForUpdates() }
        else { phase = .checking }   // a background check is running: its answer lands here
    }

    /// Install the downloaded version and relaunch. Sessions hosted in tmux keep running through it.
    func restartToUpdate() {
        if let i = installNow { phase = .installing; i(); return }
        if let c = choice { choice = nil; installWhenReady = true; c(.install) }
    }

    /// The window's main button: download (if needed), install and relaunch now.
    func installNowPressed() {
        installWhenReady = true
        if let i = installNow { phase = .installing; i(); return }
        if let c = choice { choice = nil; c(.install) }
    }

    func later() {
        if let c = choice { choice = nil; c(.dismiss) }
        installWhenReady = false
        UpdateWindow.close()
    }

    func skipVersion() {
        if let c = choice { choice = nil; c(.skip) }
        UpdateWindow.close()
    }

    func cancelPressed() {
        cancel?(); cancel = nil
        installWhenReady = false
        phase = .idle
        UpdateWindow.close()
    }

    /// The window closed: answer whatever it was asking with "later", so Sparkle isn't left waiting.
    func windowClosed() {
        if let c = choice { choice = nil; c(.dismiss) }
        switch phase {
        case .upToDate, .failed, .sourceBuild, .available: phase = .idle
        default: break
        }
    }

    /// Without an updater (a build from source): read the feed for the latest version and say so.
    private func checkLatestRelease() {
        phase = .checking
        URLSession.shared.dataTask(with: Self.feed) { data, _, _ in
            let xml = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let v = xml.range(of: #"(?<=<sparkle:shortVersionString>)[^<]+"#, options: .regularExpression).map { String(xml[$0]) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.phase = .sourceBuild(latest: v) } }
        }.resume()
    }

    // MARK: SPUUpdaterDelegate

    /// An update was downloaded in the background and will be installed on quit. Studio announces it itself
    /// (the title bar nudge); `handler` installs and relaunches right away.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock handler: @escaping () -> Void) -> Bool {
        let found = Ready(version: item.displayVersionString, notes: item.fullReleaseNotesURL ?? item.infoURL)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.installNow = handler
                self.snoozed = false
                self.ready = found
                if self.installWhenReady { self.phase = .installing; handler() }
                else if UpdateWindow.isOpen { self.phase = .available(version: found.version, downloaded: true) }
            }
        }
        return true
    }

    // MARK: SPUUserDriver (Studio's own update UI)

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancel = cancellation
        phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        notes = appcastItem.fullReleaseNotesURL ?? appcastItem.infoURL
        let version = appcastItem.displayVersionString
        if installWhenReady { reply(.install); return }
        // found by a background check: no window pops up on its own (the title bar pill says it once downloaded)
        if !state.userInitiated && !UpdateWindow.isOpen { reply(.dismiss); return }
        choice = reply
        phase = .available(version: version, downloaded: state.stage != .notDownloaded)
        UpdateWindow.show()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        phase = .upToDate
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        installWhenReady = false
        phase = .failed(error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancel = cancellation
        phase = .downloading(received: 0, expected: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        phase = .downloading(received: 0, expected: expectedContentLength > 0 ? expectedContentLength : nil)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if case .downloading(let r, let e) = phase { phase = .downloading(received: r + length, expected: e) }
    }

    func showDownloadDidStartExtractingUpdate() { cancel = nil; phase = .extracting(0) }
    func showExtractionReceivedProgress(_ progress: Double) { phase = .extracting(progress) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installWhenReady { phase = .installing; reply(.install); return }
        choice = reply
        if case .available(let v, _) = phase { phase = .available(version: v, downloaded: true) }
        else { phase = .available(version: ready?.version ?? "", downloaded: true) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        phase = .idle
    }

    func showUpdateInFocus() { UpdateWindow.show() }

    func dismissUpdateInstallation() {
        cancel = nil
        choice = nil
        // keep what the window is showing as an answer (up to date, an error); clear the work in progress
        switch phase {
        case .checking, .downloading, .extracting: phase = .idle
        default: break
        }
    }
}

// MARK: - The update window

/// "Software Update", in the active theme: checking, up to date, a new version (Install Now, Later, Skip),
/// download and unpacking progress, installing. One window for the app, brought forward on each check.
@MainActor
enum UpdateWindow {
    private static var window: NSWindow?
    private static var closeObserver: Any?
    static var isOpen: Bool { window?.isVisible == true }

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingController(rootView: UpdatePanel())
        let w = NSWindow(contentViewController: host)
        w.title = "Software Update"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 520, height: 240))
        w.center()
        window = w
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                Updater.shared.windowClosed()
                window = nil
                if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
            }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() { window?.close() }
}

private struct UpdatePanel: View {
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var theme = ThemeChanges.shared
    private var accent: SwiftUI.Color { SwiftUI.Color(nsColor: Theme.accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if case .available = updater.phase, let n = updater.notes {
                        Button("See what's new") { NSWorkspace.shared.open(n) }.buttonStyle(.link).font(.system(size: 12))
                    }
                    if let p = progress {
                        ProgressBar(value: p, accent: accent).padding(.top, 4)
                    } else if busy {
                        ProgressBar(value: nil, accent: accent).padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 16)
            buttons
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 20)
        .frame(width: 520, height: 240)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .preferredColorScheme(Theme.current.isLight ? .light : .dark)
    }

    private var busy: Bool {
        switch updater.phase { case .checking, .installing: return true; default: return false }
    }

    private var progress: Double? {
        switch updater.phase {
        case .downloading(let r, let e): return e.map { min(1, Double(r) / Double(max($0, 1))) }
        case .extracting(let p): return p
        default: return nil
        }
    }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: return "Checking for updates…"
        case .upToDate: return "Studio is up to date"
        case .available(let v, _): return "Studio \(v) is available"
        case .downloading: return "Downloading the update…"
        case .extracting: return "Preparing the update…"
        case .installing: return "Installing and restarting…"
        case .failed: return "Couldn't check for updates"
        case .sourceBuild(let v): return v.map { "The latest release is Studio \($0)" } ?? "Couldn't reach the update feed"
        }
    }

    private var detail: String {
        let current = Updater.currentVersion
        switch updater.phase {
        case .idle, .checking: return "Looking at the latest release on GitHub."
        case .upToDate: return "You have \(current), the newest version."
        case .available(_, let downloaded):
            return (downloaded ? "It's downloaded and ready. " : "") + "You have \(current). Studio restarts to install it; your sessions keep running."
        case .downloading(let r, let e):
            let got = ByteCountFormatter.string(fromByteCount: Int64(r), countStyle: .file)
            return e.map { "\(got) of \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? got
        case .extracting: return "Checking the signature and unpacking."
        case .installing: return "Studio will reopen in a moment, with your sessions where you left them."
        case .failed(let m): return m
        case .sourceBuild: return "This copy is built from source (\(current)), so it doesn't update itself. Download the release, or pull and rebuild."
        }
    }

    /// One or two buttons across the whole window, never cut: the main action on the right.
    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch updater.phase {
            case .available(_, let downloaded):
                PanelButton("Install Later") { updater.later() }
                PanelButton(downloaded ? "Restart and Install Now" : "Install Now", primary: true) { updater.installNowPressed() }
            case .downloading, .checking:
                PanelButton("Cancel") { updater.cancelPressed() }
            case .sourceBuild(let v):
                PanelButton("Close") { UpdateWindow.close() }
                if v != nil { PanelButton("Open Release Page", primary: true) { NSWorkspace.shared.open(Updater.releases); UpdateWindow.close() } }
            case .upToDate, .failed, .idle:
                PanelButton("OK", primary: true) { UpdateWindow.close() }
            case .extracting, .installing:
                PanelButton("Installing…") {}.disabled(true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A flat button in the theme: the accent for the main action, an outline for the rest.
private struct PanelButton: View {
    let title: String
    var primary = false
    let action: () -> Void
    init(_ title: String, primary: Bool = false, action: @escaping () -> Void) { self.title = title; self.primary = primary; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: primary ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 32)
                .foregroundStyle(primary ? SwiftUI.Color.white : SwiftUI.Color(nsColor: Theme.foreground))
                .background(primary ? SwiftUI.Color(nsColor: Theme.accent) : .clear)
                .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.border), lineWidth: primary ? 0 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(primary ? .defaultAction : nil)
    }
}

/// A thin bar: filled to `value`, or a sliding segment while there's no number yet.
private struct ProgressBar: View {
    let value: Double?
    let accent: SwiftUI.Color
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(SwiftUI.Color.primary.opacity(0.12))
                if let v = value {
                    Capsule().fill(accent).frame(width: max(6, g.size.width * v))
                        .animation(.easeOut(duration: 0.2), value: v)
                } else {
                    Capsule().fill(accent).frame(width: g.size.width * 0.3)
                        .offset(x: (g.size.width * 0.7) * phase)
                        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 1 } }
                }
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }
}

/// Title bar nudge once a new version is downloaded: "Update to 0.2.0". Click for Restart to Update,
/// What's New and Later.
struct UpdateNudge: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let r = updater.ready, !updater.snoozed {
            Menu {
                Text("Studio \(r.version) is downloaded and ready")
                Text(SessionHost.enabled ? "Sessions keep running while Studio restarts" : "Otherwise it installs when you quit")
                Divider()
                Button("Restart to Update") { updater.restartToUpdate() }
                if let u = r.notes { Button("What's New in \(r.version)") { NSWorkspace.shared.open(u) } }
                Button("Later") { updater.snoozed = true }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 11))
                    Text("Update to \(r.version)").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
            }
            // the capsule goes on the menu, not its label: a borderless menu draws only the label's text and icon
            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.white).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(SwiftUI.Color(nsColor: Theme.accent)))
            .help("Studio \(r.version) is ready: click to restart into it")
        }
    }
}
