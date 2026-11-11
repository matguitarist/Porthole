import Foundation
import Sparkle

/// Automatic updates with Sparkle. The feed is appcast.xml on the latest GitHub release.
/// Off until Info.plist has a real SUPublicEDKey, and never in test runs.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let ready = !Store.isOverridden && !key.isEmpty && !key.hasPrefix("__") && Bundle.main.bundleURL.pathExtension == "app"
        controller = ready ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// When Sparkle last looked for an update, or nil before the first check.
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
