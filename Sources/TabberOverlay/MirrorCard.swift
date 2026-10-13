import AppKit
import CoreText

/// The fallback presentation: a small, quiet card with the tail of the line and the suggestion,
/// used when the caret position isn't good enough to draw inline, or the caret is mid-line.
/// A solid rounded rect (no vibrancy, which turns muddy over white pages) that follows light and dark mode.
final class MirrorCardView: NSView {
    static let font = NSFont.systemFont(ofSize: 13)
    static let paddingX: CGFloat = 9
    static let paddingY: CGFloat = 5
    static let cornerRadius: CGFloat = 7
    static let maxWidth: CGFloat = 460

    private let background = NSView()
    private let text = MirrorTextView()

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 0.5
        background.autoresizingMask = [.width, .height]
        text.autoresizingMask = [.width, .height]
        addSubview(background)
        addSubview(text)
        setAccessibilityElement(false)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        text.needsDisplay = true
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func updateColors() {
        let dark = Self.isDark(effectiveAppearance)
        background.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 0.985, alpha: 0.98)).cgColor
        background.layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.13 : 0.12).cgColor
    }

    /// Sets the content and returns the card's size and where the suggestion starts inside it.
    func update(context: String, ghost: String) -> (size: CGSize, ghostX: CGFloat) {
        let measurer = TextMeasurer(font: Self.font)
        let maxText = Self.maxWidth - Self.paddingX * 2
        var shownContext = context
        var shownGhost = GhostLayout.sanitized(ghost)

        var ghostWidth = measurer.width(Substring(shownGhost))
        if ghostWidth > maxText * 0.8 {
            // The suggestion alone nearly fills the card: keep its start, drop the context.
            let ellipsis = "…"
            let room = maxText - measurer.width(Substring(ellipsis))
            if ghostWidth > maxText {
                shownGhost = String(GhostLayout.characterPrefix(of: Substring(shownGhost), width: room, measure: measurer.width)) + ellipsis
                ghostWidth = measurer.width(Substring(shownGhost))
            }
            shownContext = ""
        }
        var contextWidth = measurer.width(Substring(shownContext))
        if contextWidth + ghostWidth > maxText {
            // Truncate the context from the left until both fit.
            var tail = Substring(shownContext.hasPrefix("…") ? String(shownContext.dropFirst()) : shownContext)
            while !tail.isEmpty, measurer.width(Substring("…" + tail)) + ghostWidth > maxText {
                tail = tail.dropFirst()
            }
            shownContext = tail.isEmpty ? "" : "…" + tail
            contextWidth = measurer.width(Substring(shownContext))
        }

        let metrics = FontResolver.metrics(of: Self.font)
        let height = ceil(metrics.lineHeight + Self.paddingY * 2)
        let width = ceil(contextWidth + ghostWidth + Self.paddingX * 2)
        text.update(context: shownContext, ghost: shownGhost, contextWidth: contextWidth, baseline: Self.paddingY + metrics.descent)
        return (CGSize(width: width, height: height), Self.paddingX + contextWidth)
    }
}

/// Draws the card's single line. Colors are resolved at draw time so they follow light and dark mode.
private final class MirrorTextView: NSView {
    private var context = ""
    private var ghost = ""
    private var contextWidth: CGFloat = 0
    private var baseline: CGFloat = 0

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    func update(context: String, ghost: String, contextWidth: CGFloat, baseline: CGFloat) {
        guard context != self.context || ghost != self.ghost || baseline != self.baseline else { return }
        self.context = context
        self.ghost = ghost
        self.contextWidth = contextWidth
        self.baseline = baseline
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let font = MirrorCardView.font
        let dark = MirrorCardView.isDark(effectiveAppearance)
        let primary = NSColor(white: dark ? 0.93 : 0.1, alpha: 1).cgColor
        let tint = NSColor(white: dark ? 0.93 : 0.1, alpha: dark ? 0.45 : 0.42).cgColor
        let scale = window?.backingScaleFactor ?? 2
        let y = GhostLayout.pixelAligned(baseline, scale: scale)
        ctx.textMatrix = .identity
        if !context.isEmpty {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: context, attributes: [.font: font, colorKey: primary]))
            ctx.textPosition = CGPoint(x: MirrorCardView.paddingX, y: y)
            CTLineDraw(line, ctx)
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: ghost, attributes: [.font: font, colorKey: tint]))
        ctx.textPosition = CGPoint(x: MirrorCardView.paddingX + contextWidth, y: y)
        CTLineDraw(line, ctx)
    }
}
