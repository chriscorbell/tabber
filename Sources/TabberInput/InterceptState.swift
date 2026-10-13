import TabberCore

/// Shortcuts that work whether or not a suggestion is visible.
public enum HotkeyAction: Sendable, Hashable {
    case forceActivate
    case pauseInApp
    case toggleGlobally
}

/// Everything the event tap needs to decide whether to swallow a key. The coordinator pushes a new
/// value with `KeyboardMonitor.update(_:)` whenever a ghost appears or disappears or settings change.
public struct InterceptState: Sendable, Equatable {
    /// A ready suggestion is on screen. Accept and dismiss keys are only swallowed while this is true.
    public var ghostVisible: Bool
    public var acceptWord: KeyBinding?
    public var acceptAll: KeyBinding?
    /// Swallow a bare Esc while a ghost is visible.
    public var dismissWithEscape: Bool
    /// Always swallowed, ghost or not.
    public var hotkeys: [KeyBinding: HotkeyAction]
    /// How many numbered alternatives are on screen. Bare digit keys 1...n are swallowed to pick one.
    public var alternativesShown: Int = 0

    public init(
        ghostVisible: Bool = false,
        acceptWord: KeyBinding? = nil,
        acceptAll: KeyBinding? = nil,
        dismissWithEscape: Bool = false,
        hotkeys: [KeyBinding: HotkeyAction] = [:]
    ) {
        self.ghostVisible = ghostVisible
        self.acceptWord = acceptWord
        self.acceptAll = acceptAll
        self.dismissWithEscape = dismissWithEscape
        self.hotkeys = hotkeys
    }

    /// The bindings from user settings.
    public init(settings: TabberSettings, ghostVisible: Bool) {
        var hotkeys: [KeyBinding: HotkeyAction] = [:]
        if let key = settings.forceActivateKey { hotkeys[key] = .forceActivate }
        if let key = settings.pauseInAppKey { hotkeys[key] = .pauseInApp }
        self.init(
            ghostVisible: ghostVisible,
            acceptWord: settings.acceptWordKey,
            acceptAll: settings.acceptAllKey,
            dismissWithEscape: settings.escapeBehavior == .dismiss,
            hotkeys: hotkeys
        )
    }
}

/// What the event tap saw, reported to the coordinator on the main queue.
public enum KeyEvent: Sendable, Equatable {
    /// Printable text the user typed. Passed through to the app.
    case typed(String)
    /// Backspace, delete, Return, arrows, navigation, Cmd/Ctrl shortcuts... Passed through.
    case editing
    /// A swallowed accept key.
    case accept(AcceptKind)
    /// An autorepeat of the held accept-word key. Swallowed; never given back to the app.
    case acceptRepeat
    /// A swallowed Esc.
    case dismiss
    /// A swallowed hotkey.
    case hotkey(HotkeyAction)
    /// A swallowed digit picking alternative number n (1-based).
    case pickAlternative(Int)
    /// Any mouse button went down. Passed through.
    case pointerDown
}
