import Foundation

/// A keyboard shortcut: a virtual key code plus modifiers.
public struct KeyBinding: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Tab.
    public static let tab = KeyBinding(keyCode: 48)
    /// The key above Tab (` on ANSI, § on ISO, ^ on German).
    public static let keyAboveTab = KeyBinding(keyCode: 50)
    public static let escape = KeyBinding(keyCode: 53)
    /// Control-` : force a suggestion where Tabber normally stays quiet.
    public static let forceActivate = KeyBinding(keyCode: 50, modifiers: .control)
    /// Control-Option-Command-` : pause in the current app.
    public static let pauseInApp = KeyBinding(keyCode: 50, modifiers: [.control, .option, .command])
}

public enum EscapeBehavior: String, Codable, CaseIterable, Sendable {
    /// Esc hides the suggestion until you type again; a second Esc reaches the app.
    case dismiss
    /// Esc is never intercepted.
    case passThrough

    public var title: String {
        switch self {
        case .dismiss: "Hide the suggestion"
        case .passThrough: "Do nothing (always send Esc to the app)"
        }
    }
}

public enum InsertionMethod: String, Codable, CaseIterable, Sendable {
    /// Synthesized key events carrying Unicode text. Works almost everywhere.
    case keystrokes
    /// Paste through the clipboard, restoring it afterwards.
    case paste
    /// One key event per character. Slow but the most compatible.
    case characterByCharacter

    public var title: String {
        switch self {
        case .keystrokes: "Typing (default)"
        case .paste: "Paste"
        case .characterByCharacter: "Character by character"
        }
    }
}

/// Per-app or per-website settings. `nil` means "use the global setting".
public struct AppOverride: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var tabAccepts: Bool?
    public var allowMidLine: Bool?
    public var instructions: String?
    /// Show suggestions in a floating mirror instead of inline.
    public var forceMirror: Bool?
    public var fontScale: Double?
    public var verticalOffset: Double?
    public var greyText: Bool?
    public var insertion: InsertionMethod?
    public var ignoreSizeThresholds: Bool?

    public init() {}

    public var isEmpty: Bool { self == AppOverride() }
}

public struct TabberSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var modelID: String?
    public var length: CompletionLength = .medium
    public var allowMidLine = false
    public var includeTrailingSpace = false
    public var includeTrailingPunctuation = true

    public var acceptWordKey: KeyBinding? = .tab
    public var acceptAllKey: KeyBinding? = .keyAboveTab
    public var forceActivateKey: KeyBinding? = .forceActivate
    public var pauseInAppKey: KeyBinding? = .pauseInApp
    public var toggleGloballyKey: KeyBinding?
    public var escapeBehavior: EscapeBehavior = .dismiss

    /// Suggest emoji for ":shortcodes" and emoticons like ":)".
    public var emojiSuggestions = true
    /// After a misspelled word, offer the fix as the suggestion (Tab applies it).
    public var autocorrect = true
    /// After a pause with a suggestion showing, list other likely words; a digit picks one.
    public var showAlternatives = false
    public var alternativesDelay: Double = 2.0
    public var useScreenContext = true
    public var useClipboardContext = false
    public var customInstructions = ""
    public var authorName = ""

    /// How strongly suggestions lean toward words you use often. 0 turns it off.
    public var personalization: Double = 0.5
    public var recordWriting = false

    /// Ghost text opacity relative to the app's text color.
    public var ghostOpacity: Double = 0.5
    public var animateSuggestions = true
    public var showMenuBarIcon = true

    /// On battery: only show suggestions when asked with the force shortcut.
    public var onDemandOnBattery = false
    public var shorterOnBattery = true

    /// Keyed by bundle identifier, or by domain (`example.com`, `*.example.com`).
    public var overrides: [String: AppOverride] = [:]
    /// Apps where Tabber is off by default (code editors, terminals...). Users can still enable them.
    public var hasCompletedOnboarding = false

    public init() {}

    /// Settings for a given app and optional domain: domain overrides win over app overrides.
    public func override(bundleID: String, domain: String?) -> AppOverride {
        var merged = overrides[bundleID] ?? AppOverride()
        if let domain, let d = Self.matchDomain(domain, in: overrides) {
            if let v = d.enabled { merged.enabled = v }
            if let v = d.allowMidLine { merged.allowMidLine = v }
            if let v = d.instructions { merged.instructions = v }
        }
        return merged
    }

    /// Matches `mail.google.com` against keys like `mail.google.com`, `*.google.com`, `google.*`.
    public static func matchDomain(_ domain: String, in overrides: [String: AppOverride]) -> AppOverride? {
        if let exact = overrides[domain] { return exact }
        let parts = domain.split(separator: ".")
        for i in 1..<max(parts.count, 1) {
            let suffix = parts[i...].joined(separator: ".")
            if let o = overrides["*.\(suffix)"] { return o }
        }
        if let first = parts.first, let o = overrides["\(first).*"] { return o }
        return nil
    }
}
