import AppKit

/// Entry point for the app target: `TabberAppMain.run()` from `main.swift`.
public enum TabberAppMain {
    @MainActor private static var delegate: AppDelegate?

    /// Starts a menu bar app (no Dock icon) and never returns.
    public static func run() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            Self.delegate = delegate
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
