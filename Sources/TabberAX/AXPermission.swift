import ApplicationServices

/// Accessibility (AX) trust for this process.
public enum AXPermission {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security > Accessibility.
    public static func requestTrust() {
        // The literal value of kAXTrustedCheckOptionPrompt; using it avoids touching the unmanaged global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
