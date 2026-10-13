import CoreGraphics
import Foundation

/// Screen geometry convention used everywhere in Tabber's core and AX layers:
/// global "Quartz" coordinates, origin at the top-left of the primary display, y grows downward.
/// This is what the Accessibility API returns. Only the overlay converts to AppKit's bottom-left space.
public typealias ScreenRect = CGRect

/// The app that owns the focused field.
public struct AppIdentity: Hashable, Sendable, Codable {
    public var bundleID: String
    public var name: String
    public var pid: Int32

    public init(bundleID: String, name: String, pid: Int32) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

/// Identifies one text field across reads, so a session survives text changes but resets on a new field.
public struct FieldIdentity: Hashable, Sendable {
    public var pid: Int32
    /// A hash of the AXUIElement (CFHash), stable while the element lives.
    public var elementHash: UInt
    public var role: String

    public init(pid: Int32, elementHash: UInt, role: String) {
        self.pid = pid
        self.elementHash = elementHash
        self.role = role
    }
}

/// How much to trust a caret rectangle.
public enum CaretQuality: Int, Sendable, Comparable {
    /// Estimated from the field frame or similar. Not good enough to draw inline text.
    case estimated = 0
    /// Derived from neighbouring characters or text runs.
    case derived = 1
    /// Reported directly by the app for the caret or the previous character.
    case exact = 2

    public static func < (lhs: CaretQuality, rhs: CaretQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct CaretGeometry: Equatable, Sendable {
    /// The caret box: x is the insertion point, height spans the line's glyphs.
    public var rect: ScreenRect
    public var quality: CaretQuality

    public init(rect: ScreenRect, quality: CaretQuality) {
        self.rect = rect
        self.quality = quality
    }
}

/// Text style at the caret, as reported by the app.
public struct TextStyle: Equatable, Sendable {
    public var fontName: String?
    public var fontFamily: String?
    public var fontSize: CGFloat?
    /// sRGB components 0...1.
    public var textColor: RGBA?
    /// The rendered width of a few characters before the caret, for apps that report a size but no
    /// font family (Chrome). The overlay picks the installed family whose width matches.
    public var widthSample: WidthSample?

    public init(fontName: String? = nil, fontFamily: String? = nil, fontSize: CGFloat? = nil, textColor: RGBA? = nil, widthSample: WidthSample? = nil) {
        self.fontName = fontName
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.textColor = textColor
        self.widthSample = widthSample
    }
}

public struct WidthSample: Equatable, Sendable {
    public var text: String
    public var width: CGFloat
    /// Measured x of characters in `text`, relative to its start, keyed by UTF-16 offset (word starts and the end).
    public var offsets: [Int: CGFloat]
    public init(text: String, width: CGFloat, offsets: [Int: CGFloat] = [:]) {
        self.text = text
        self.width = width
        self.offsets = offsets
    }
}

public struct RGBA: Equatable, Sendable, Codable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Relative luminance (sRGB approximation).
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// Everything Tabber knows about the focused text field at one moment.
public struct FieldSnapshot: Equatable, Sendable {
    public var app: AppIdentity
    public var field: FieldIdentity
    public var role: String
    public var subrole: String?
    public var windowTitle: String?
    /// Page URL for browser and web-view fields, when the app exposes it.
    public var url: URL?
    public var placeholder: String?
    public var label: String?
    /// The element's AXIdentifier or DOM id, when it has one (e.g. "Mail.toField").
    public var identifier: String?

    /// Up to a bounded window of text immediately before the caret.
    public var textBeforeCaret: String
    /// Up to a bounded window of text immediately after the caret.
    public var textAfterCaret: String
    /// True when `textBeforeCaret` was cut and more text exists before it.
    public var beforeIsTruncated: Bool
    /// Length of the current selection in UTF-16 units. Zero means a plain caret.
    public var selectionLength: Int
    /// Caret offset in UTF-16 units from the start of the field's text, when known.
    public var caretOffset: Int?

    public var isSecure: Bool
    public var isEditable: Bool
    public var isSingleLine: Bool
    /// IME composition or the system's own inline prediction is present.
    public var hasMarkedText: Bool

    /// The field's frame on screen.
    public var fieldFrame: ScreenRect?
    public var caret: CaretGeometry?
    public var style: TextStyle?

    public var capturedAt: Date

    public init(
        app: AppIdentity,
        field: FieldIdentity,
        role: String,
        subrole: String? = nil,
        windowTitle: String? = nil,
        url: URL? = nil,
        placeholder: String? = nil,
        label: String? = nil,
        identifier: String? = nil,
        textBeforeCaret: String,
        textAfterCaret: String = "",
        beforeIsTruncated: Bool = false,
        selectionLength: Int = 0,
        caretOffset: Int? = nil,
        isSecure: Bool = false,
        isEditable: Bool = true,
        isSingleLine: Bool = false,
        hasMarkedText: Bool = false,
        fieldFrame: ScreenRect? = nil,
        caret: CaretGeometry? = nil,
        style: TextStyle? = nil,
        capturedAt: Date = Date()
    ) {
        self.app = app
        self.field = field
        self.role = role
        self.subrole = subrole
        self.windowTitle = windowTitle
        self.url = url
        self.placeholder = placeholder
        self.label = label
        self.identifier = identifier
        self.textBeforeCaret = textBeforeCaret
        self.textAfterCaret = textAfterCaret
        self.beforeIsTruncated = beforeIsTruncated
        self.selectionLength = selectionLength
        self.caretOffset = caretOffset
        self.isSecure = isSecure
        self.isEditable = isEditable
        self.isSingleLine = isSingleLine
        self.hasMarkedText = hasMarkedText
        self.fieldFrame = fieldFrame
        self.caret = caret
        self.style = style
        self.capturedAt = capturedAt
    }

    /// The web domain, if any, without a leading "www.".
    public var domain: String? {
        guard let host = url?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The text on the caret's line after the caret.
    public var restOfLine: Substring {
        textAfterCaret.prefix { $0 != "\n" && $0 != "\r" }
    }

    /// True when the caret sits at the end of its line (ignoring trailing spaces).
    public var caretAtEndOfLine: Bool {
        restOfLine.allSatisfy { $0 == " " || $0 == "\t" }
    }
}
