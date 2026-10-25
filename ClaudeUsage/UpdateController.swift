import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

// In-app updates via Sparkle.
//
// Deliberately compiled behind `canImport(Sparkle)` so the project still builds
// before the package has been added, and lights up on its own once it has —
// nothing else in the app needs to change either way. Until then "Check for
// Updates…" just opens the releases page, which is what people were doing by
// hand anyway.
//
// Sparkle verifies each update with an EdDSA signature (SUPublicEDKey in
// Info.plist) on top of Apple notarization, so a tampered download is rejected
// even if someone could serve it from our URL.
//
// This fork builds without the package (removed 2026-10-24): its feed and key
// are upstream's, so an in-app update would install upstream's build over the
// fork's changes. "Check for Updates…" opens upstream's releases page, to see
// what is new there. To restore in-app updates, add the Sparkle package back
// and an Info.plist carrying SUFeedURL and SUPublicEDKey for a feed and key
// this fork controls — git history has both as they were.
final class UpdateController {
    static let shared = UpdateController()

    private static let releasesURL =
        URL(string: "https://github.com/ryanbarnett-2am/Juicage/releases/latest")!

    #if canImport(Sparkle)
    // startingUpdater: true begins the scheduled background check immediately.
    // Sparkle asks the user, on first run, whether to check automatically — so
    // this doesn't phone home behind anyone's back.
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var usingSparkle: Bool { true }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    // Lets the menu item disable itself while a check is already running.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    #else
    var usingSparkle: Bool { false }
    var canCheckForUpdates: Bool { true }

    func checkForUpdates() {
        NSWorkspace.shared.open(Self.releasesURL)
    }
    #endif
}
