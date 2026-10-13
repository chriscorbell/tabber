import SwiftUI

/// Actions the UI can trigger that live outside SwiftUI: windows, the engine, quitting.
@MainActor
final class AppActions {
    var showSettings: (SettingsPane?) -> Void = { _ in }
    var showOnboarding: () -> Void = {}
    var reloadEngine: () -> Void = {}
    var finishOnboarding: () -> Void = {}
    var quit: () -> Void = { NSApp.terminate(nil) }

    init() {}
}

/// Everything a window's SwiftUI tree needs.
@MainActor
struct AppEnvironment {
    let state: AppState
    let settings: SettingsStore
    let models: ModelManager
    let stats: StatsStore
    let permissions: PermissionsMonitor
    let actions: AppActions
}

private struct AppActionsKey: EnvironmentKey {
    static var defaultValue: AppActions { MainActor.assumeIsolated { AppActions() } }
}

private struct PermissionsMonitorKey: EnvironmentKey {
    static var defaultValue: PermissionsMonitor? { nil }
}

extension EnvironmentValues {
    var appActions: AppActions {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }

    var permissionsMonitor: PermissionsMonitor? {
        get { self[PermissionsMonitorKey.self] }
        set { self[PermissionsMonitorKey.self] = newValue }
    }
}

extension View {
    func appEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environmentObject(environment.state)
            .environmentObject(environment.settings)
            .environmentObject(environment.models)
            .environmentObject(environment.stats)
            .environment(\.appActions, environment.actions)
            .environment(\.permissionsMonitor, environment.permissions)
    }

    /// Polls permissions every second while this view is on screen.
    func livePermissions() -> some View {
        modifier(LivePermissionsModifier())
    }
}

private struct LivePermissionsModifier: ViewModifier {
    @Environment(\.permissionsMonitor) private var monitor

    func body(content: Content) -> some View {
        content
            .onAppear { monitor?.beginFastPolling() }
            .onDisappear { monitor?.endFastPolling() }
    }
}

extension Notification.Name {
    /// Posted when the user asks to delete recorded writing. The coordinator deletes the history.
    public static let tabberDeleteHistory = Notification.Name("TabberDeleteHistory")
}
