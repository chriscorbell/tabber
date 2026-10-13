import CoreGraphics

/// Pure geometry for caret candidates. Every rect is in global Quartz coordinates (top-left origin, y down).
enum CaretMath {
    /// How far outside the field frame a caret may sit. Fields often report a frame slightly smaller than
    /// their text (padding, scrolled content, focus rings).
    static let fieldSlack: CGFloat = 60
    static let maxCaretHeight: CGFloat = 200

    /// A rect from AX is usable when it is finite, has a plausible line height, and sits on or near the field.
    static func isPlausible(_ rect: CGRect, field: CGRect?, slack: CGFloat = fieldSlack) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
            return false
        }
        guard rect.height >= 1, rect.height < maxCaretHeight, rect.width >= 0 else { return false }
        // "Don't know" often comes back as a rect at the origin. Real text can't be there: the menu bar is.
        if rect.origin == .zero { return false }
        guard let field, isUsableFrame(field) else { return true }
        // Chromium answers some queries with the element's whole frame. A caret can't fill a multi-line field.
        if field.height > 48, rect.height > field.height * 0.8 { return false }
        let area = field.insetBy(dx: -slack, dy: -slack)
        return area.contains(CGPoint(x: rect.minX, y: rect.midY))
    }

    /// Some apps report text bounds with a bottom-left origin, or in backing pixels. When the raw rect doesn't
    /// sit on the field, try those readings and keep one only if it lands squarely on the field.
    static func repaired(_ rect: CGRect, field: CGRect?, primaryScreenHeight: CGFloat?, scale: CGFloat?) -> CGRect? {
        guard let field, isUsableFrame(field), rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        var candidates: [CGRect] = []
        if let height = primaryScreenHeight, height > 0 {
            candidates.append(CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height))
        }
        if let scale, scale > 1 {
            candidates.append(CGRect(
                x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale
            ))
        }
        return candidates.first { isPlausible($0, field: field, slack: 8) }
    }

    /// Bounds for one character can be a whole line in some apps; then its edge isn't the caret.
    static func isCharacterSized(_ rect: CGRect) -> Bool {
        rect.width <= max(rect.height * 3, 48)
    }

    /// The caret just after a character: its trailing edge (the left edge for right-to-left text).
    static func caret(after character: CGRect, rightToLeft: Bool) -> CGRect {
        CGRect(x: rightToLeft ? character.minX : character.maxX, y: character.minY, width: 0, height: character.height)
    }

    /// The caret just before a character: its leading edge.
    static func caret(before character: CGRect, rightToLeft: Bool) -> CGRect {
        CGRect(x: rightToLeft ? character.maxX : character.minX, y: character.minY, width: 0, height: character.height)
    }

    /// A zero-length bounds query: the x is the caret even when the app reports some width.
    static func caret(collapsed rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
    }

    /// Zero-length bounds come back one line too high in TextKit. Two facts expose that: a caret after a newline
    /// sits below the newline's line, and a caret never sits entirely above its field. When either is violated,
    /// move the caret down to where it must be.
    ///
    /// Only a newline with width says where its line is: TextKit draws it from the end of the text to the right
    /// edge of the line it ends. Chromium reports a zero-width newline at the start of the next line instead.
    static func correctedCollapsed(_ rect: CGRect, field: CGRect?, previousNewline: CGRect?) -> (rect: CGRect, corrected: Bool) {
        let caret = caret(collapsed: rect)
        if let newline = previousNewline, newline.height >= 1, newline.width > 0.5, newline.minY.isFinite,
           caret.minY < newline.maxY - 0.5 {
            return (CGRect(x: caret.minX, y: newline.maxY, width: 0, height: caret.height), true)
        }
        if let field, isUsableFrame(field), caret.maxY <= field.minY + 0.5 {
            let moved = caret.offsetBy(dx: 0, dy: caret.height)
            if moved.maxY <= field.maxY + 0.5 { return (moved, true) }
        }
        return (caret, false)
    }

    /// Taller than one line of chat-sized text, shorter than two.
    static let singleLineRunHeight: CGFloat = 26

    /// The caret at the trailing edge of a text run's frame, when the text before the caret ends with the run and
    /// the run is one line. A wrapped run's frame spans its widest line, so its edge isn't the caret.
    static func caret(atEndOfRun run: CGRect, runText: String, textBefore: String) -> CGRect? {
        let runText = runText.hasSuffix("\n") ? String(runText.dropLast()) : runText
        guard !runText.isEmpty, textBefore.hasSuffix(runText), !textBeforeIsRightToLeft(runText),
              run.width > 0, run.height >= 8, run.height < singleLineRunHeight else { return nil }
        return CGRect(x: run.maxX, y: run.minY, width: 0, height: run.height)
    }

    /// A guess from the field frame alone: the first line, just inside the leading edge.
    static func estimatedCaret(field: CGRect, isSingleLine: Bool, lineHeight: CGFloat?) -> CGRect {
        let inset: CGFloat = 4
        let height = min(max(lineHeight ?? 17, 8), max(field.height - 2, 8))
        let y = isSingleLine ? field.midY - height / 2 : field.minY + inset
        return CGRect(x: field.minX + inset, y: y, width: 0, height: height)
    }

    /// For web fields without a role that says so: a field less than ~2.2 lines tall is single-line.
    static func looksSingleLine(fieldHeight: CGFloat, caretHeight: CGFloat) -> Bool {
        caretHeight > 0 && fieldHeight < caretHeight * 2.2
    }

    static func isUsableFrame(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    /// Strong right-to-left scripts: Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, their presentation
    /// forms, and the RTL supplementary blocks.
    static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }

    /// Direction of the text just before the caret: decided by the nearest letter on the caret's line.
    static func textBeforeIsRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars.reversed().prefix(64) {
            if TextWindow.isNewline(scalar) { return false }
            if scalar.properties.isAlphabetic { return isRightToLeft(scalar) }
        }
        return false
    }
}

/// Display facts from CoreGraphics, which unlike NSScreen is safe off the main thread.
enum DisplayInfo {
    static var primaryHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    /// Backing scale of the display under `point`.
    static func scale(at point: CGPoint) -> CGFloat? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0,
              let mode = CGDisplayCopyDisplayMode(display) else { return nil }
        let points = CGDisplayBounds(display).width
        return points > 0 ? CGFloat(mode.pixelWidth) / points : nil
    }
}
