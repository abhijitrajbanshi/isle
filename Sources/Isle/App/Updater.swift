import Foundation
import Observation
import Sparkle

/// Auto-updates via Sparkle.
///
/// The feed is `appcast.xml` on the latest GitHub release (see `SUFeedURL`
/// in Info.plist); every update is verified against `SUPublicEDKey` before
/// it is installed. Sparkle keeps its own settings in UserDefaults; this
/// mirrors them so SwiftUI can bind to them.
@MainActor
@Observable
final class Updater {
    /// Check once a day.
    var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    /// Download and install in the background; applied when Isle quits.
    var automaticallyDownloads: Bool {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }
    /// False while a check is already running.
    private(set) var canCheck = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    init() {
        // Only a bundled app has a feed to check; `swift run` builds don't.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            automaticallyChecks = false
            automaticallyDownloads = false
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        canCheck = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
