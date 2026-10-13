import AppKit
import CoreText

/// Draws the ghost's lines with CoreText at explicit baselines, so glyphs land where the host's would.
final class GhostView: NSView {
    struct Line: Equatable {
        var text: String
        /// Left end of the baseline in this view's coordinates (bottom-left origin).
        var origin: CGPoint
    }

    private var lines: [Line] = []
    private var font: NSFont = .systemFont(ofSize: 13)
    private var color: NSColor = .gray
    private var ctLines: [CTLine] = []

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = .clear
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(lines: [Line], font: NSFont, color: NSColor) {
        let restyle = font != self.font || color != self.color
        if restyle || lines.map(\.text) != self.lines.map(\.text) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            ]
            ctLines = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0.text, attributes: attributes)) }
        }
        guard restyle || lines != self.lines else { return }
        self.lines = lines
        self.font = font
        self.color = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(true)
        ctx.setShouldSubpixelQuantizeFonts(true)
        ctx.textMatrix = .identity
        for (line, ct) in zip(lines, ctLines) {
            ctx.textPosition = line.origin
            CTLineDraw(ct, ctx)
        }
    }
}
