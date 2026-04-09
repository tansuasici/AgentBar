import Foundation

#if canImport(Sparkle)
import Sparkle

/// Wraps Sparkle's SPUStandardUpdaterController for in-app auto-updates.
/// Disabled gracefully when Sparkle is unavailable (debug builds, Homebrew installs).
@MainActor
final class SparkleUpdater {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

#else

/// Stub when Sparkle is not available.
@MainActor
final class SparkleUpdater {
    var canCheckForUpdates: Bool { false }
    var automaticallyChecksForUpdates: Bool {
        get { false }
        set { }
    }
    func checkForUpdates() { }
}

#endif
