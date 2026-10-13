import CoreGraphics
import Foundation
import TabberCore

// Pure geometry and text layout for the ghost. No AppKit, so every rule here is unit-testable.
// All rects and points are in global Quartz space (top-left origin of the primary display, y down)
// unless a name says AppKit.

/// Vertical metrics of a font at a given size. `descent` is positive (distance below the baseline).
struct FontMetrics: Equatable, Sendable {
    var pointSize: CGFloat
    var ascent: CGFloat
    var descent: CGFloat
    var leading: CGFloat

    var glyphHeight: CGFloat { ascent + descent }
    var lineHeight: CGFloat { ascent + descent + leading }

    /// The same font at another size (metrics scale linearly).
    func scaled(to size: CGFloat) -> FontMetrics {
        guard pointSize > 0 else { return self }
        let k = size / pointSize
        return FontMetrics(pointSize: size, ascent: ascent * k, descent: descent * k, leading: leading * k)
    }
}

/// One line of ghost text: where its baseline starts and what it says.
struct LineFragment: Equatable, Sendable {
    var text: String
    /// Left end of the baseline, Quartz space.
    var origin: CGPoint
    var width: CGFloat
}

enum ScreenSpace {
    /// Quartz (top-left of the primary display, y down) to AppKit (bottom-left of the primary display, y up).
    /// `primaryHeight` is the height of the screen whose AppKit origin is zero, never the union of all screens.
    static func appKitRect(fromQuartz r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The conversion is its own inverse.
    static func quartzRect(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func appKitY(fromQuartz y: CGFloat, primaryHeight: CGFloat) -> CGFloat { primaryHeight - y }

    /// Window frames land on whole points. Expands `rect` outward to integral points.
    static func integralFrame(containing rect: CGRect) -> CGRect {
        let minX = floor(rect.minX), minY = floor(rect.minY)
        return CGRect(x: minX, y: minY, width: ceil(rect.maxX) - minX, height: ceil(rect.maxY) - minY)
    }
}

enum GhostLayout {
    /// Caret heights relative to the font's line height that we accept as "the reported size is right".
    static let plausibleCaretRatio: ClosedRange<CGFloat> = 0.75...1.6
    static let fontSizeRange: ClosedRange<CGFloat> = 8...72
    static let defaultFontSize: CGFloat = 13
    static let maxLines = 3

    // MARK: Font size

    /// Picks the point size to draw at.
    ///
    /// Apps often report a missing or wrong size (CSS px at a zoomed page, a default style, a fake run).
    /// The caret box is the best ground truth: when the reported size makes a line much shorter or taller
    /// than the caret, derive the size so the font's line height matches the caret.
    /// - Parameter unitLineHeight: the font's ascent + descent + leading at 1 pt.
    static func fontSize(reported: CGFloat?, caretHeight: CGFloat?, unitLineHeight: CGFloat) -> CGFloat {
        let reported = reported.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let caret = caretHeight.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
        let size: CGFloat
        switch (reported, caret) {
        case let (r?, c?) where unitLineHeight > 0:
            let ratio = c / (r * unitLineHeight)
            size = plausibleCaretRatio.contains(ratio) ? r : c / unitLineHeight
        case let (r?, _):
            size = r
        case let (nil, c?) where unitLineHeight > 0:
            size = c / unitLineHeight
        default:
            size = defaultFontSize
        }
        return clamp(size, fontSizeRange)
    }

    // MARK: Baseline

    /// The baseline y for text on the caret's line. Positive `verticalOffset` moves the text down.
    ///
    /// Measured in TextEdit (TextKit) and Safari (WebKit textareas and contenteditable, including CSS
    /// line-height 1.8): the caret box's bottom sits at the glyphs' descent line and any extra line height
    /// is above the glyphs. So the baseline is one descent above the caret's bottom. When the caret is
    /// shorter than the font's glyph box (rounded metrics), the glyph box is centred on it instead.
    ///
    /// WebKit floors both the y and the height of the rects it reports, so the true bottom is up to 2 pt
    /// lower (0.25–1.4 pt measured). `wholePointRect` rects get half a point back.
    static func baseline(caret: CGRect, metrics: FontMetrics, verticalOffset: CGFloat = 0, wholePointRect: Bool = false) -> CGFloat {
        let extra = caret.height - metrics.glyphHeight
        var y = extra >= 0
            ? caret.maxY - metrics.descent
            : caret.minY + extra / 2 + metrics.ascent
        if wholePointRect, extra >= 0 { y += 0.5 }
        return y + verticalOffset
    }

    /// Snaps a y coordinate to the device pixel grid, the way native text baselines sit.
    static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }

    /// Distance between wrapped ghost lines: the font's line height, kept within 1.0–1.25 caret heights.
    static func linePitch(caretHeight: CGFloat, metrics: FontMetrics) -> CGFloat {
        guard caretHeight > 1 else { return metrics.lineHeight }
        return clamp(metrics.lineHeight, caretHeight...(caretHeight * 1.25))
    }

    // MARK: Type-through

    /// How many characters of `ghost.text` the field already shows before the caret, when it is behind
    /// `ghost.consumed` (the user typed through faster than the app published). Nil when the snapshot
    /// doesn't contain the ghost's anchor at all.
    static func publishedPrefix(of ghost: Ghost, in textBeforeCaret: String) -> Int? {
        let anchorTail = String(ghost.anchor.suffix(64))
        let chars = Array(ghost.text)
        let consumed = min(max(ghost.consumed, 0), chars.count)
        for m in stride(from: consumed, through: 0, by: -1) {
            if textBeforeCaret.hasSuffix(anchorTail + String(chars[0..<m])) { return m }
        }
        return nil
    }

    /// The characters typed through but not yet in the snapshot. The drawing shifts right by their width.
    static func lagText(ghost: Ghost, textBeforeCaret: String) -> Substring {
        let consumed = min(max(ghost.consumed, 0), ghost.text.count)
        guard consumed > 0, let m = publishedPrefix(of: ghost, in: textBeforeCaret), m < consumed else { return "" }
        let start = ghost.text.index(ghost.text.startIndex, offsetBy: m)
        let end = ghost.text.index(ghost.text.startIndex, offsetBy: consumed)
        return ghost.text[start..<end]
    }

    // MARK: Line starts

    /// Where lines start in this field, estimated as the caret x minus the width of the caret line's text.
    /// Nil when the result is implausible: the line soft-wrapped, contains tabs, or isn't left-aligned.
    static func estimatedLineStart(
        caretX: CGFloat,
        textBeforeCaret: String,
        fieldFrame: CGRect?,
        measure: (Substring) -> CGFloat
    ) -> CGFloat? {
        let line = textBeforeCaret.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        guard !line.contains("\t") else { return nil }
        let start = caretX - measure(line)
        guard let field = fieldFrame, field.width > 0 else { return nil }
        let maxPadding = min(field.width * 0.4, 200)
        guard start >= field.minX - 2, start <= field.minX + maxPadding else { return nil }
        return start
    }

    // MARK: Rounded carets

    /// Some apps (WebKit) floor the rects they report to whole points, so the true caret x is anywhere in
    /// `[x, x + 1)`. The line's start is then in `[x - width, x + 1 - width)`, where `width` is the measured
    /// width of the line's text before the caret. Intersecting that interval across reads pins the start
    /// down as the user types, and the caret x follows as `start + width`.
    static func refinedLineStart(previous: ClosedRange<CGFloat>?, caretX: CGFloat, lineWidth: CGFloat) -> ClosedRange<CGFloat> {
        let observed = (caretX - lineWidth)...(caretX + 1 - lineWidth)
        guard let previous, previous.overlaps(observed) else { return observed }
        return previous.clamped(to: observed)
    }

    static func isWholePoint(_ value: CGFloat) -> Bool {
        abs(value - value.rounded()) < 0.001
    }

    /// A caret whose x, y and height are all whole points: an app that rounds its rects (WebKit).
    /// TextKit reports exact, fractional x positions, so it doesn't match after the first character.
    static func isWholePointRect(_ rect: CGRect) -> Bool {
        isWholePoint(rect.minX) && isWholePoint(rect.minY) && isWholePoint(rect.height)
    }

    // MARK: Wrapping

    struct LineInput {
        /// The text to draw (the ghost's remainder).
        var text: String
        /// First line starts here (caret x plus any type-through shift).
        var startX: CGFloat
        /// Baseline of the first line.
        var baseline: CGFloat
        /// Text must end before this x.
        var rightEdge: CGFloat
        /// Continuation lines start here.
        var lineStartX: CGFloat
        var linePitch: CGFloat
        var maxLines: Int = GhostLayout.maxLines
        /// Continuation lines whose descent would go below this y are dropped (the field's bottom).
        var bottomLimit: CGFloat? = nil
        /// False for single-line fields: draw what fits on the caret line only.
        var allowWrap: Bool = true
    }

    /// Lays the ghost out from the caret to the right edge, then wraps at word boundaries onto following
    /// lines. Trailing spaces hang past the edge like in a text system; text beyond `maxLines` is dropped.
    static func lines(_ input: LineInput, metrics: FontMetrics, measure: (Substring) -> CGFloat) -> [LineFragment] {
        let text = sanitized(input.text)
        guard !text.isEmpty else { return [] }

        var fragments: [LineFragment] = []
        var rest = Substring(text)
        var x = input.startX
        var baseline = input.baseline
        var lineIndex = 0

        while !rest.isEmpty, lineIndex < max(input.maxLines, 1) {
            if lineIndex > 0 {
                if let limit = input.bottomLimit, baseline + metrics.descent > limit + 1 { break }
            }
            let available = input.rightEdge - x
            let isLastLine = !input.allowWrap || lineIndex == max(input.maxLines, 1) - 1
            var take = fittingPrefix(of: rest, width: available, measure: measure)

            if take.isEmpty {
                // Nothing fits at a word boundary. On the caret line the word wraps to the next line, as the
                // app's text system would. A word wider than a whole line is cut at a character.
                let freshLine = lineIndex > 0 || x <= input.lineStartX + 0.5
                if freshLine || isLastLine {
                    take = characterPrefix(of: rest, width: available, measure: measure)
                    if take.isEmpty { break }
                }
            }

            if !take.isEmpty {
                let visible = take.trimmingTrailingSpaces()
                if !visible.isEmpty {
                    fragments.append(LineFragment(
                        text: String(visible),
                        origin: CGPoint(x: x, y: baseline),
                        width: measure(visible)
                    ))
                }
                rest = rest.dropFirst(take.count)
            }
            if isLastLine { break }
            // The next line starts at the field's text edge, without the spaces the break consumed.
            rest = rest.drop { $0 == " " }
            x = input.lineStartX
            baseline += input.linePitch
            lineIndex += 1
        }
        return fragments
    }

    /// The longest prefix ending at a word boundary whose visible part (without trailing spaces) fits.
    /// If all of `text` fits, returns all of it.
    static func fittingPrefix(of text: Substring, width: CGFloat, measure: (Substring) -> CGFloat) -> Substring {
        if measure(text.trimmingTrailingSpaces()) <= width { return text }
        var best: Substring = ""
        var index = text.startIndex
        while index < text.endIndex {
            // Advance to the end of the next run of spaces: a break opportunity.
            guard let space = text[index...].firstIndex(of: " ") else { break }
            var end = space
            while end < text.endIndex, text[end] == " " { end = text.index(after: end) }
            let candidate = text[text.startIndex..<end]
            if measure(candidate.trimmingTrailingSpaces()) <= width {
                best = candidate
                index = end
            } else {
                break
            }
        }
        return best
    }

    /// The longest prefix that fits, cut at any character.
    static func characterPrefix(of text: Substring, width: CGFloat, measure: (Substring) -> CGFloat) -> Substring {
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            if measure(text[text.startIndex..<next]) > width { break }
            end = next
        }
        return text[text.startIndex..<end]
    }

    /// Ghost text is drawn as one run: no tabs or line breaks.
    static func sanitized(_ text: String) -> String {
        guard text.contains(where: { $0.isNewline || $0 == "\t" }) else { return text }
        return String(text.map { $0.isNewline || $0 == "\t" ? " " : $0 })
    }

    /// The box the fragments' glyphs occupy, with room for overhangs.
    static func bounds(of fragments: [LineFragment], metrics: FontMetrics) -> CGRect? {
        guard !fragments.isEmpty else { return nil }
        let padX = ceil(metrics.pointSize * 0.3) + 2
        let padY = ceil(metrics.leading) + 2
        return fragments.map { f in
            CGRect(
                x: f.origin.x - padX,
                y: f.origin.y - metrics.ascent - padY,
                width: f.width + padX * 2,
                height: metrics.glyphHeight + padY * 2
            )
        }.reduce(CGRect.null) { $0.union($1) }
    }

    // MARK: Mirror card

    /// The tail of the caret's line shown before the ghost in the mirror card.
    static func mirrorContext(textBeforeCaret: String, maxCharacters: Int = 30) -> String {
        let line = textBeforeCaret.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        let flat = sanitized(String(line))
        guard flat.count > maxCharacters else { return flat }
        var tail = flat.suffix(maxCharacters)
        // Start at a word when one begins soon, so the card doesn't open on half a word.
        if let space = tail.prefix(12).firstIndex(of: " ") {
            tail = tail[tail.index(after: space)...]
        }
        return "…" + tail
    }

    /// Where the mirror card goes (its Quartz frame).
    ///
    /// Below `line` when given (the caret's line), else below `field`, flipping above when there's no room,
    /// then clamped to `screen` (the visible frame of the screen it belongs to).
    /// - Parameter alignX: the x the card's left edge would ideally have.
    static func mirrorCardFrame(size: CGSize, line: CGRect?, field: CGRect?, alignX: CGFloat?, screen: CGRect, gap: CGFloat = 6) -> CGRect? {
        guard let anchor = line ?? field else { return nil }
        var y = anchor.maxY + gap
        if y + size.height > screen.maxY - 2 {
            y = anchor.minY - gap - size.height
            if y < screen.minY + 2 {
                // No room above or below (a field that fills the screen): sit inside its bottom edge.
                y = min(anchor.maxY, screen.maxY) - gap - size.height
            }
        }
        var x = alignX ?? anchor.minX
        x = min(x, screen.maxX - size.width - 4)
        x = max(x, screen.minX + 4)
        y = clamp(y, (screen.minY + 2)...max(screen.minY + 2, screen.maxY - size.height - 2))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

extension Substring {
    func trimmingTrailingSpaces() -> Substring {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            guard self[prev] == " " else { break }
            end = prev
        }
        return self[startIndex..<end]
    }
}

/// The ghost's color: a translucent shade of the host's text color, or a neutral grey that reads on
/// light and dark backgrounds when the host color is unknown, nearly invisible, or grey was requested.
///
/// In dark mode, apps such as TextEdit and Mail render documents with their colors inverted for a dark
/// background (dark text drawn light, a dark page drawn light), but Accessibility still reports the
/// stored colors. A translucent shade of the reported color would vanish whenever that happens. So in
/// dark mode the ghost is the opaque blend of the text color with the background its luminance implies
/// (white behind dark text, black behind light text): identical to the translucent look on that
/// background, and still a readable mid tone when the app has inverted it.
enum GhostTint {
    static let neutralGrey = RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.75)

    static func color(host: RGBA?, opacity: Double, grey: Bool, darkSystem: Bool = false) -> RGBA {
        guard !grey, let host, host.a >= 0.3 else { return neutralGrey }
        let alpha = min(max(opacity, 0.05), 1) * min(host.a, 1)
        guard darkSystem else { return RGBA(r: host.r, g: host.g, b: host.b, a: alpha) }
        let background: Double = host.luminance < 0.5 ? 1 : 0
        func blend(_ c: Double) -> Double { c * alpha + background * (1 - alpha) }
        return RGBA(r: blend(host.r), g: blend(host.g), b: blend(host.b), a: 1)
    }
}
