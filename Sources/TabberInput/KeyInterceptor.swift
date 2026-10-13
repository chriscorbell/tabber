import CoreGraphics
import TabberCore

/// Virtual key codes used by the classifier (Carbon `kVK_*` values).
enum KeyCode {
    static let `return`: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let keypadClear: UInt16 = 71
    static let v: UInt16 = 9
    static let help: UInt16 = 114
    static let home: UInt16 = 115
    static let pageUp: UInt16 = 116
    static let forwardDelete: UInt16 = 117
    static let end: UInt16 = 119
    static let pageDown: UInt16 = 121
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1-F12
        105, 107, 113, 106, 64, 79, 80, 90,                     // F13-F20
    ]

    /// Keys that edit or move the caret without typing text.
    static let editing: Set<UInt16> = Set([
        `return`, tab, delete, escape, keypadEnter, keypadClear, help, home, pageUp, forwardDelete,
        end, pageDown, leftArrow, rightArrow, downArrow, upArrow,
    ]).union(functionKeys)
}

extension KeyBinding.Modifiers {
    /// The four modifiers a binding can use. Caps Lock, Fn, numeric pad, and the device-dependent
    /// left/right bits are ignored.
    public init(eventFlags flags: CGEventFlags) {
        var modifiers: KeyBinding.Modifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        self = modifiers
    }
}

extension KeyBinding {
    /// Exact match: same key and exactly the same four modifiers. Bare Tab does not match Shift-Tab or Option-Tab.
    public func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && modifiers == KeyBinding.Modifiers(eventFlags: flags)
    }
}

/// What to do with one event.
public struct KeyDecision: Equatable, Sendable {
    /// Drop the event so the app never sees it.
    public var swallow: Bool
    /// What to report to the coordinator, if anything.
    public var event: KeyEvent?

    public static func pass(_ event: KeyEvent?) -> KeyDecision { KeyDecision(swallow: false, event: event) }
    public static func swallow(_ event: KeyEvent?) -> KeyDecision { KeyDecision(swallow: true, event: event) }
}

/// The tap's decision logic, free of any system calls so it can be unit-tested.
///
/// Fails open: a key is only swallowed when it is bound to an action that is valid right now.
/// An autorepeat follows the fate of the press that started it, so holding a swallowed key never
/// leaks repeats into the app, and holding a key the app got never turns into an accept halfway.
public struct KeyInterceptor: Sendable {
    /// Keys whose keyDown we swallowed and whose keyUp we haven't seen yet.
    public private(set) var held: Set<UInt16> = []

    public init() {}

    public mutating func keyDown(
        keyCode: UInt16,
        flags: CGEventFlags,
        characters: String,
        isRepeat: Bool,
        state: InterceptState
    ) -> KeyDecision {
        let modifiers = KeyBinding.Modifiers(eventFlags: flags)
        let binding = KeyBinding(keyCode: keyCode, modifiers: modifiers)

        if isRepeat {
            guard held.contains(keyCode) else {
                return .pass(Self.passThroughEvent(keyCode: keyCode, modifiers: modifiers, characters: characters))
            }
            // Holding the accept-word key keeps accepting words. Every other held key just stays swallowed.
            if state.ghostVisible, state.acceptWord == binding { return .swallow(.acceptRepeat) }
            return .swallow(nil)
        }

        if let event = Self.action(for: binding, state: state) ?? Self.alternativePick(characters: characters, modifiers: modifiers, state: state) {
            held.insert(keyCode)
            return .swallow(event)
        }
        held.remove(keyCode)
        return .pass(Self.passThroughEvent(keyCode: keyCode, modifiers: modifiers, characters: characters))
    }

    /// Returns true when the keyUp belongs to a keyDown we swallowed.
    public mutating func keyUp(keyCode: UInt16) -> Bool {
        held.remove(keyCode) != nil
    }

    /// A bare digit while numbered alternatives are shown. Reads the typed character, so it works on any layout.
    static func alternativePick(characters: String, modifiers: KeyBinding.Modifiers, state: InterceptState) -> KeyEvent? {
        guard state.alternativesShown > 0, modifiers.isEmpty || modifiers == .shift,
              characters.count == 1, let n = Int(characters), (1...state.alternativesShown).contains(n) else { return nil }
        return .pickAlternative(n)
    }

    /// The action a fresh key press triggers, if it is bound and valid right now.
    static func action(for binding: KeyBinding, state: InterceptState) -> KeyEvent? {
        if let action = state.hotkeys[binding] { return .hotkey(action) }
        guard state.ghostVisible else { return nil }
        if state.acceptWord == binding { return .accept(.word) }
        if state.acceptAll == binding { return .accept(.all) }
        if state.dismissWithEscape, binding == .escape { return .dismiss }
        return nil
    }

    /// How a key the app receives is reported.
    static func passThroughEvent(keyCode: UInt16, modifiers: KeyBinding.Modifiers, characters: String) -> KeyEvent {
        if modifiers.contains(.command) || modifiers.contains(.control) { return .editing }
        if KeyCode.editing.contains(keyCode) { return .editing }
        guard let text = printableText(characters) else { return .editing }
        return .typed(text)
    }

    /// The text a key produced, or nil when it is empty (dead keys), a control character, or one of the
    /// private-use characters AppKit gives function keys (U+F700–U+F8FF).
    static func printableText(_ characters: String) -> String? {
        guard !characters.isEmpty else { return nil }
        for scalar in characters.unicodeScalars {
            if scalar.properties.generalCategory == .control { return nil }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }
}
