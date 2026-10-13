import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let settings = SettingsStore.shared
    private let stats = StatsStore()
    private lazy var models = ModelManager(settings: settings)
    private lazy var permissions = PermissionsMonitor(state: state)
    private let actions = AppActions()

    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var coordinator: AppCoordinator?

    private var environment: AppEnvironment {
        AppEnvironment(state: state, settings: settings, models: models, stats: stats, permissions: permissions, actions: actions)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        permissions.start()

        actions.showSettings = { [weak self] pane in self?.showSettings(pane) }
        actions.showOnboarding = { [weak self] in self?.showOnboarding() }
        actions.reloadEngine = { [weak self] in self?.coordinator?.reloadEngine() }
        actions.finishOnboarding = { [weak self] in self?.finishOnboarding() }

        let environment = environment
        menuBar = MenuBarController(environment: environment)
        settingsWindow = SettingsWindowController(environment: environment)

        let coordinator = AppCoordinator(state: state, settings: settings, models: models, stats: stats)
        self.coordinator = coordinator
        coordinator.start()

        if !settings.settings.hasCompletedOnboarding {
            showOnboarding()
        }
        #if DEBUG
        // `-TabberSettingsPane model` opens Settings on a pane, for working on the UI.
        if let pane = UserDefaults.standard.string(forKey: "TabberSettingsPane").flatMap(SettingsPane.init(rawValue:)) {
            showSettings(pane)
        }
        // `-TabberOpenMenu YES` opens the menu bar menu shortly after launch.
        if UserDefaults.standard.bool(forKey: "TabberOpenMenu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.menuBar?.openMenu() }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        permissions.stop()
        settings.flush()
    }

    /// Opening Tabber again (from Finder or Spotlight) shows Settings. This is the way back when the
    /// menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if onboardingWindow != nil {
                showOnboarding()
            } else {
                showSettings(nil)
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Windows

    @objc func showSettingsWindow(_ sender: Any?) {
        showSettings(nil)
    }

    @objc func showAboutPane(_ sender: Any?) {
        showSettings(.about)
    }

    private func showSettings(_ pane: SettingsPane?) {
        settingsWindow?.show(pane: pane)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let controller = OnboardingWindowController(environment: environment)
            controller.onClose = { [weak self] in
                self?.onboardingWindow = nil
                self?.state.isOnboardingVisible = false
            }
            onboardingWindow = controller
        }
        state.isOnboardingVisible = true
        onboardingWindow?.show()
    }

    private func finishOnboarding() {
        settings.settings.hasCompletedOnboarding = true
        settings.flush()
        onboardingWindow?.close()
    }
}
