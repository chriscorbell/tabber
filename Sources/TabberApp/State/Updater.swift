import AppKit
import Sparkle

/// Finds, downloads and installs new versions with Sparkle. The feed and the key that signs updates are in
/// Info.plist; `scripts/release.sh` publishes both the update and the feed.
///
/// Tabber lives in the menu bar, so Sparkle's alert for a scheduled check opens behind other apps. While it's up,
/// Tabber shows in the Dock, and the menu bar icon and menu point to the update until the user looks at it.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// A version found by a scheduled check that the user hasn't looked at yet.
    @Published private(set) var pendingVersion: String?
    @Published private(set) var lastCheck: Date?

    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        // Debug builds share settings with the installed app, and an update would replace the build being worked on.
        #if !DEBUG
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        #endif
        lastCheck = controller?.updater.lastUpdateCheckDate
    }

    var isAvailable: Bool { controller != nil }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { lastCheck = updater.lastUpdateCheckDate }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            if !state.userInitiated { pendingVersion = update.displayVersionString }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            pendingVersion = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
