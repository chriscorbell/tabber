import Foundation

/// Live runtime state shared by the coordinator and the UI. Main actor only.
@MainActor
public final class AppState: ObservableObject {
    public enum EngineStatus: Equatable {
        case noModel
        /// Loading the named model.
        case loading(String)
        /// The named model is loaded and serving suggestions.
        case ready(String)
        /// Loading or running failed, with a message for the user.
        case failed(String)
    }

    public struct Permissions: Equatable {
        public var accessibility = false
        public var screenRecording = false

        public init(accessibility: Bool = false, screenRecording: Bool = false) {
            self.accessibility = accessibility
            self.screenRecording = screenRecording
        }
    }

    @Published public var engineStatus: EngineStatus = .noModel

    /// The app the user is typing in (never Tabber itself).
    @Published public var focusedAppName: String?
    @Published public var focusedBundleID: String?
    /// The website's domain when the focused app is a browser.
    @Published public var focusedDomain: String?

    /// Global temporary pause. Suggestions are paused while this is in the future.
    @Published public var pausedUntil: Date?
    /// Per-app temporary pauses, keyed by bundle identifier.
    @Published public var pausedApps: [String: Date] = [:]

    @Published public var secureInputActive = false
    /// Refreshed by `PermissionsMonitor`.
    @Published public var permissions = Permissions()
    @Published public var lastLatencyMs: Double?

    /// True while a shortcut recorder in Settings is listening for keys. The coordinator should stop
    /// swallowing hotkeys meanwhile, so the recorder can see them.
    @Published public var isRecordingShortcut = false

    /// True while the onboarding window is open, so the coordinator can serve suggestions in its
    /// practice field even if it normally ignores Tabber's own windows.
    @Published public var isOnboardingVisible = false

    public init() {}

    public func isPaused(now: Date = Date()) -> Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > now
    }

    public func isPaused(bundleID: String, now: Date = Date()) -> Bool {
        guard let until = pausedApps[bundleID] else { return false }
        return until > now
    }

    public func pause(for duration: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(duration)
    }

    public func resume() {
        pausedUntil = nil
    }

    public func resume(bundleID: String) {
        pausedApps[bundleID] = nil
    }
}
