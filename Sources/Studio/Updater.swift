import SwiftUI
import Sparkle

/// In-app updates through Sparkle: checks the appcast on the latest GitHub release in the background,
/// downloads a new version, verifies its signature and installs it when Studio quits.
/// Only release builds update themselves: the release workflow writes SUFeedURL and SUPublicEDKey into
/// Info.plist, a local build (./build-app.sh) has neither, so a build from source is never replaced.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
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

    private init() {
        let info = Bundle.main
        guard info.object(forInfoDictionaryKey: "SUFeedURL") is String,
              info.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { controller = nil; return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        automatic = c.updater.automaticallyChecksForUpdates && c.updater.automaticallyDownloadsUpdates
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheck)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
