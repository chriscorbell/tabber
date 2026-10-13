import AppKit
import TabberInput
import Carbon.HIToolbox
import Combine
import TabberCore

/// The status item and its menu. The menu is rebuilt each time it opens, so it always reflects the
/// focused app and current state.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let env: AppEnvironment
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var subscriptions: Set<AnyCancellable> = []
    private var pauseTimer: Timer?

    private static let pauseDuration: TimeInterval = 10 * 60

    init(environment: AppEnvironment) {
        env = environment
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.autosaveName = "TabberStatusItem"
        item.button?.image = StatusIcon.image(progress: nil)
        item.button?.setAccessibilityTitle("Tabber")
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        env.settings.$settings
            .map(\.showMenuBarIcon)
            .removeDuplicates()
            .sink { [weak self] visible in self?.item.isVisible = visible }
            .store(in: &subscriptions)

        Publishers.CombineLatest3(env.settings.$settings.map(\.enabled).removeDuplicates(), env.state.$pausedUntil, env.models.$downloads)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, pausedUntil, _ in
                self?.schedulePauseRefresh(pausedUntil)
                self?.updateIcon()
            }
            .store(in: &subscriptions)
    }

    /// Opens the menu as if clicked.
    func openMenu() {
        item.button?.performClick(nil)
    }

    // MARK: Icon

    private func updateIcon() {
        guard let button = item.button else { return }
        let progress = env.models.downloads.values.max()
        button.image = StatusIcon.image(progress: progress)
        button.appearsDisabled = !env.settings.settings.enabled || env.state.isPaused()
        button.toolTip = statusLine
    }

    /// Redraws the icon when a pause runs out.
    private func schedulePauseRefresh(_ until: Date?) {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard let until, until > Date() else { return }
        let timer = Timer(fire: until.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = env.settings
        let state = env.state

        menu.addItem(.sectionHeader(title: statusLine))
        if settings.settings.enabled, let until = state.pausedUntil, until > Date() {
            menu.addItem(info("Paused until \(until.formatted(date: .omitted, time: .shortened))"))
        }
        menu.addItem(info("Words saved today: \(env.stats.wordsToday.formatted())"))
        if state.secureInputActive || IsSecureEventInputEnabled() {
            let culprit = KeyboardMonitor.secureInputProcessID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
            let warning = info(culprit.map { "\($0) turned on Secure Input" } ?? "Secure Input is on", icon: .triangleAlert)
            warning.toolTip = "While Secure Input is on, macOS hides keystrokes from other apps, so Tabber pauses. It's usually a password field or a password manager; quitting that app, or locking and unlocking the Mac, turns it off."
            menu.addItem(warning)
        }
        for leak in Self.leakedKeyboardHooks() {
            let warning = info("Mac feeling slow? \(leak.name) has \(leak.count) keyboard hooks", icon: .triangleAlert)
            warning.toolTip = "Every keystroke passes through each of these hooks. Restarting \(leak.name) usually clears them."
            menu.addItem(warning)
        }

        menu.addItem(.separator())
        menu.addItem(action("Suggestions", checked: settings.settings.enabled) {
            settings.settings.enabled.toggle()
        })
        if state.isPaused() {
            menu.addItem(action("Resume Now") { state.resume() })
        } else {
            menu.addItem(action("Pause for 10 Minutes") { state.pause(for: Self.pauseDuration) })
        }

        if let bundleID = state.focusedBundleID, bundleID != Bundle.main.bundleIdentifier {
            let name = state.focusedAppName ?? InstalledApp.name(for: bundleID)
            menu.addItem(.separator())
            if state.isPaused(bundleID: bundleID) {
                menu.addItem(action("Resume in \(name)") { state.resume(bundleID: bundleID) })
            }
            let appEnabled = settings.isAppEnabled(bundleID)
            menu.addItem(action(appEnabled ? "Disable in \(name)" : "Enable in \(name)") {
                settings.setAppEnabled(bundleID, !appEnabled)
            })
            if let domain = state.focusedDomain, !domain.isEmpty {
                let domainEnabled = settings.domainEnabled(domain) ?? true
                menu.addItem(action(domainEnabled ? "Disable on \(domain)" : "Enable on \(domain)") {
                    settings.setDomainEnabled(domain, !domainEnabled)
                })
            }
            menu.addItem(action("Tab Accepts in \(name)", checked: settings.tabAccepts(in: bundleID)) {
                settings.setTabAccepts(bundleID, !settings.tabAccepts(in: bundleID))
            })
        }

        menu.addItem(.separator())
        let actions = env.actions
        menu.addItem(action("Settings…", key: ",") { actions.showSettings(nil) })
        menu.addItem(action("Show Onboarding…") { actions.showOnboarding() })
        menu.addItem(action("About Tabber") { actions.showSettings(.about) })
        menu.addItem(.separator())
        menu.addItem(action("Quit Tabber", key: "q") { actions.quit() })
    }

    private var statusLine: String {
        let models = env.models
        if let (id, progress) = models.downloads.max(by: { $0.value < $1.value }) {
            return "Downloading \(models.displayName(for: id)), \(Int(progress * 100))%"
        }
        if !env.settings.settings.enabled { return "Suggestions are off" }
        switch env.state.engineStatus {
        case .noModel: return models.selectedModelID == nil ? "No model installed" : "Model not loaded"
        case let .loading(name): return "Loading \(name)…"
        case let .ready(name): return "\(name) is ready"
        case .failed: return "The model couldn't load"
        }
    }

    /// Processes holding several filtering event taps: usually a bug that slows every keystroke on the Mac.
    static func leakedKeyboardHooks(threshold: Int = 4) -> [(name: String, count: Int)] {
        let keyboard = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let taps = EventTapDiagnostics.allTaps().filter { $0.filters && $0.enabled && $0.eventsOfInterest & keyboard != 0 }
        let byProcess = Dictionary(grouping: taps, by: \.pid)
        return byProcess.values.filter { $0.count >= threshold }.map { (name: $0[0].processName, count: $0.count) }.sorted { $0.count > $1.count }
    }

    private func info(_ title: String, icon: LucideIcon? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let icon { item.image = icon.image(size: 14) }
        return item
    }

    private func action(_ title: String, key: String = "", checked: Bool? = nil, _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, handler: handler)
        if let checked { item.state = checked ? .on : .off }
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        MainActor.assumeIsolated { handler() }
    }
}
