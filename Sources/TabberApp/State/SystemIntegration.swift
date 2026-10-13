import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement

/// Small wrappers around system settings and permission prompts.
@MainActor
enum SystemIntegration {
    /// macOS 27 renamed the Accessibility privacy pane.
    static var accessibilityPaneName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "Device Control and Data Access"
            : "Accessibility"
    }

    /// "Accessibility access", or the macOS 27 pane name, which already ends in "Access".
    static var accessibilityPermissionPhrase: String {
        let name = accessibilityPaneName
        return name.hasSuffix("Access") ? name : "\(name) access"
    }

    /// Shows the system prompt (which also adds Tabber to the list) and opens the privacy pane.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    /// Asks once with the system prompt, then opens the Screen Recording pane.
    static func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        openPrivacyPane("Privacy_ScreenCapture")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func openPrivacyPane(_ anchor: String) {
        open("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// macOS's own inline predictive text (Keyboard > Text Input > "Show inline predictive text").
/// It competes with Tabber for the Tab key and draws its own grey text at the caret.
@MainActor
enum InlinePredictions {
    /// The global preference behind the System Settings switch. Unset means on.
    private static let key = "NSAutomaticInlinePredictionEnabled" as CFString

    static var isEnabled: Bool {
        if let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool {
            return value
        }
        return NSSpellChecker.isAutomaticInlinePredictionEnabled
    }

    /// Writes the global preference (same as `defaults write -g`). Returns false if the write didn't
    /// stick, in which case the caller should send the user to Keyboard settings.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        // Removing the key restores the system default (on).
        let value: CFPropertyList? = enabled ? nil : kCFBooleanFalse
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return false }
        // AppKit listens for this to pick up the change in running apps.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("NSAutomaticInlinePredictionEnabledChanged"), object: nil, userInfo: nil, deliverImmediately: true
        )
        let stored = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
        return enabled ? stored != false : stored == false
    }
}

/// Launch at login through the main app's login item.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
