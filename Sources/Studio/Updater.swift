import SwiftUI
import Sparkle

/// In-app updates through Sparkle: checks the appcast on the latest GitHub release in the background,
/// downloads a new version, verifies its signature and installs it when Studio quits. Since Studio is rarely
/// quit, a downloaded update is announced in the title bar ("Update to 0.2.0"), one click from a restart.
/// Only release builds update themselves: the release workflow writes SUFeedURL and SUPublicEDKey into
/// Info.plist, a local build (./build-app.sh) has neither, so a build from source is never replaced.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// A new version that is downloaded and waiting for a restart.
    struct Ready: Equatable { let version: String; let notes: URL? }

    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
    @Published private(set) var ready: Ready?
    /// The user chose "Later": no nudge until the next launch (the update still installs on quit).
    @Published var snoozed = false
    private var installNow: (() -> Void)?
    /// Download and install new versions without asking (they take effect at the next launch).
    @Published var automatic = false {
        didSet {
            guard let u = controller?.updater, automatic != oldValue else { return }
            u.automaticallyChecksForUpdates = automatic
            u.automaticallyDownloadsUpdates = automatic
        }
    }

    /// False in builds without an update feed (built from source, preview copies).
    var enabled: Bool { controller != nil }

    private override init() {
        super.init()
        let info = Bundle.main
        guard info.object(forInfoDictionaryKey: "SUFeedURL") is String,
              info.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        automatic = c.updater.automaticallyChecksForUpdates && c.updater.automaticallyDownloadsUpdates
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheck)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Install the downloaded version and relaunch. Sessions hosted in tmux keep running through it.
    func restartToUpdate() { installNow?() }

    // MARK: SPUUpdaterDelegate

    /// An update was downloaded in the background and will be installed on quit. Studio announces it itself
    /// (the title bar nudge) instead of Sparkle's reminder dialog; `handler` installs and relaunches right away.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock handler: @escaping () -> Void) -> Bool {
        let found = Ready(version: item.displayVersionString, notes: item.fullReleaseNotesURL ?? item.infoURL)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.installNow = handler
                self.snoozed = false
                self.ready = found
            }
        }
        return true
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
