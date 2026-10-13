import CoreFoundation

/// Pure helpers for the text around the caret. All offsets are UTF-16 code units, as AX reports them.
enum TextWindow {
    /// A bounded span of the field's text to fetch around the selection.
    struct Span: Equatable {
        /// First UTF-16 unit to read.
        var start: Int
        /// One past the last unit to read.
        var end: Int
        var selectionStart: Int
        var selectionEnd: Int
        var beforeIsTruncated: Bool

        var length: Int { end - start }
        var range: CFRange { CFRange(location: start, length: length) }
        var beforeRange: CFRange { CFRange(location: start, length: selectionStart - start) }
        var afterRange: CFRange { CFRange(location: selectionEnd, length: end - selectionEnd) }
    }

    /// The span covering up to `before` units before the selection and `after` units after it,
    /// clamped to the text. Apps sometimes report selections past the end of their text; those are clamped too.
    static func span(selection: CFRange, totalLength: Int, before: Int, after: Int) -> Span {
        let total = max(0, totalLength)
        let selectionStart = min(max(0, selection.location), total)
        let selectionEnd = min(max(selectionStart, selection.location + max(0, selection.length)), total)
        let start = max(0, selectionStart - max(0, before))
        let end = min(total, selectionEnd + max(0, after))
        return Span(
            start: start, end: end,
            selectionStart: selectionStart, selectionEnd: selectionEnd,
            beforeIsTruncated: start > 0
        )
    }

    /// Splits text fetched for exactly `span` into the parts before and after the selection.
    /// Returns nil when the fetched text isn't the length the span asked for, which means the app's
    /// offsets don't match its string and the split would be wrong.
    static func split(fetched: String, span: Span) -> (before: String, after: String)? {
        let units = Array(fetched.utf16)
        guard units.count == span.length else { return nil }
        let before = slice(units, from: 0, to: span.selectionStart - span.start)
        let after = slice(units, from: span.selectionEnd - span.start, to: units.count)
        return (before, after)
    }

    /// Splits the field's whole text around the selection, keeping only the bounded windows.
    static func split(
        fullText: String, selection: CFRange, before: Int, after: Int
    ) -> (before: String, after: String, span: Span) {
        let units = Array(fullText.utf16)
        let window = TextWindow.span(selection: selection, totalLength: units.count, before: before, after: after)
        return (
            slice(units, from: window.start, to: window.selectionStart),
            slice(units, from: window.selectionEnd, to: window.end),
            window
        )
    }

    /// The last `limit` UTF-16 units of `text`, and whether anything was cut.
    static func suffix(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        let units = Array(text.utf16)
        guard units.count > limit else { return (text, false) }
        return (slice(units, from: units.count - max(0, limit), to: units.count), true)
    }

    /// The first `limit` UTF-16 units of `text`.
    static func prefix(_ text: String, limit: Int) -> String {
        let units = Array(text.utf16)
        guard units.count > limit else { return text }
        return slice(units, from: 0, to: max(0, limit))
    }

    /// Decodes `units[from..<to]`, nudging the bounds so a surrogate pair is never cut in half.
    static func slice(_ units: [UInt16], from: Int, to: Int) -> String {
        var lower = min(max(0, from), units.count)
        var upper = min(max(lower, to), units.count)
        if lower > 0, lower < units.count, isLowSurrogate(units[lower]), isHighSurrogate(units[lower - 1]) {
            lower += 1
        }
        if upper > lower, upper < units.count, isHighSurrogate(units[upper - 1]), isLowSurrogate(units[upper]) {
            upper -= 1
        }
        guard upper > lower else { return "" }
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    /// Text as Tabber's other layers want it: NBSP (which web editors insert for runs of spaces) becomes a
    /// plain space, and trailing object-replacement characters (attachments, images) are dropped.
    /// Both keep UTF-16 offsets before the end of the string unchanged.
    static func clean(_ text: String) -> String {
        var result = text.contains("\u{00A0}") ? text.replacingOccurrences(of: "\u{00A0}", with: " ") : text
        while result.unicodeScalars.last == "\u{FFFC}" {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    /// UTF-16 length of the last user-perceived character, so a bounds query covers a whole emoji.
    static func lastCharacterLength(_ text: String) -> Int {
        text.last.map { String($0).utf16.count } ?? 0
    }

    static func firstCharacterLength(_ text: String) -> Int {
        text.first.map { String($0).utf16.count } ?? 0
    }

    static func endsWithNewline(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return isNewline(last)
    }

    static func isNewline(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// Chromium's rich-text editors count selection offsets without the newlines between blocks that their value
    /// has. Given the value and the text from the field's start to the caret as text markers see it (also without
    /// those newlines), finds the caret's offset in the value: walk both, skipping newlines only the value has.
    /// The result sits before any newlines that follow; whether the caret is past them only geometry can tell.
    /// Returns nil when the texts differ by more than newlines.
    static func alignCaret(value: [UInt16], markerTextBefore marker: [UInt16]) -> Int? {
        var i = 0
        var j = 0
        while j < marker.count {
            guard i < value.count else { return nil }
            if sameUnit(value[i], marker[j]) {
                i += 1
                j += 1
            } else if isNewlineUnit(value[i]) {
                i += 1
            } else {
                return nil
            }
        }
        return i
    }

    /// The offset just past the run of newlines starting at `index`.
    static func skipNewlines(_ value: [UInt16], from index: Int) -> Int {
        var i = index
        while i < value.count, isNewlineUnit(value[i]) { i += 1 }
        return i
    }

    static func isNewlineUnit(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    /// NBSP and space are the same character for alignment: editors swap them as text is typed.
    private static func sameUnit(_ a: UInt16, _ b: UInt16) -> Bool {
        a == b || ((a == 0x20 || a == 0xA0) && (b == 0x20 || b == 0xA0))
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }
    private static func isLowSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
}
