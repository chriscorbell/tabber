import AppKit
import Combine
import SwiftUI

/// The single Settings window: a native sidebar and the selected pane. Remembers its frame and the
/// last pane.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let router = SettingsRouter()
    private var subscription: AnyCancellable?
    /// Set when a pane opens; the next time the window is key, no text field is focused.
    private var clearFocusPending = true

    init(environment: AppEnvironment) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init(window: window)

        let sidebar = NSHostingController(rootView: SettingsSidebar(router: router).appEnvironment(environment))
        let detail = NSHostingController(rootView: SettingsDetail(router: router).appEnvironment(environment))
        sidebar.sizingOptions = []
        detail.sizingOptions = []

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = false
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 460
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        split.splitView.autosaveName = "TabberSettingsSplit"

        window.contentViewController = split
        window.toolbar = NSToolbar(identifier: "TabberSettings")
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.setContentSize(NSSize(width: 720, height: 520))
        if !window.setFrameUsingName("TabberSettings") {
            window.center()
        }
        window.setFrameAutosaveName("TabberSettings")

        subscription = router.$pane.sink { [weak self] pane in
            self?.window?.title = pane.title
            self?.clearFocusSoon()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(pane: SettingsPane? = nil) {
        if let pane { router.pane = pane }
        clearFocusPending = true
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Focus

    /// SwiftUI focuses the first text field of a pane once it lays out. Opening a pane shouldn't put
    /// the user in a text field, so clear it shortly after, or when the window next becomes key.
    private func clearFocusSoon() {
        clearFocusPending = !(window?.isKeyWindow ?? false)
        clearFocus()
    }

    private func clearFocus() {
        // Twice: SwiftUI may assign focus after its first layout pass.
        for delay in [0.1, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.window?.makeFirstResponder(nil)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard clearFocusPending else { return }
        clearFocusPending = false
        clearFocus()
    }
}
