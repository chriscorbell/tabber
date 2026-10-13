import AppKit
import ApplicationServices
import CoreGraphics

/// Keeps `AppState.permissions` current. Polls slowly by default, and every second while a window
/// that shows live permission status is open.
@MainActor
public final class PermissionsMonitor {
    private let state: AppState
    private var timer: Timer?
    private var fastRequests = 0
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "app.tabber.permissions", qos: .utility)

    private static let slowInterval: TimeInterval = 5
    private static let fastInterval: TimeInterval = 1

    public init(state: AppState) {
        self.state = state
    }

    public func start() {
        refresh()
        schedule()
        // Posted by the system whenever the Accessibility trust list changes.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
        observers.removeAll()
    }

    /// Call `beginFastPolling()` when a live status view appears and `endFastPolling()` when it goes.
    public func beginFastPolling() {
        fastRequests += 1
        if fastRequests == 1 { schedule() }
        refresh()
    }

    public func endFastPolling() {
        fastRequests = max(0, fastRequests - 1)
        if fastRequests == 0 { schedule() }
    }

    public func refresh() {
        queue.async { [weak self] in
            let current = AppState.Permissions(
                accessibility: AXIsProcessTrusted(),
                screenRecording: CGPreflightScreenCaptureAccess()
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state.permissions != current else { return }
                    self.state.permissions = current
                }
            }
        }
    }

    private func schedule() {
        timer?.invalidate()
        let interval = fastRequests > 0 ? Self.fastInterval : Self.slowInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
