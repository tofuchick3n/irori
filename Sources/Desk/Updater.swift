import Sparkle

/// Sparkle updates from GitHub Releases. Only a packaged app has a feed URL in its Info.plist,
/// so `swift run` and tests never start the updater.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        controller = bundle.object(forInfoDictionaryKey: "SUFeedURL") == nil
            ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
