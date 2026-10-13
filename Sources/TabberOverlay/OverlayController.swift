import AppKit
import TabberCore

/// Shows the ghost: inline at the caret in the host's font and a translucent shade of its text color,
/// or in a small mirror card near the field when inline drawing would look wrong.
///
/// One panel is created lazily and reused for the life of the controller. Updates while visible are
/// applied in place with no animation, so typing through never flickers.
@MainActor public final class OverlayController {
    public struct Appearance: Equatable, Sendable {
        /// Alpha applied to the host's text color, 0...1.
        public var opacity: Double
        /// Always draw in neutral grey instead of the host's text color.
        public var greyText: Bool
        /// Multiplies the resolved font size. 1 = as reported.
        public var fontScale: Double
        /// Points; positive moves the ghost down.
        public var verticalOffset: Double
        /// Fade in when a ghost first appears (also off when the system asks to reduce motion).
        public var animate: Bool
        /// Always use the mirror card.
        public var forceMirror: Bool

        public init(
            opacity: Double = 0.5,
            greyText: Bool = false,
            fontScale: Double = 1,
            verticalOffset: Double = 0,
            animate: Bool = true,
            forceMirror: Bool = false
        ) {
            self.opacity = opacity
            self.greyText = greyText
            self.fontScale = fontScale
            self.verticalOffset = verticalOffset
            self.animate = animate
            self.forceMirror = forceMirror
        }
    }

    /// How the current ghost is drawn.
    public enum Presentation: Sendable, Equatable {
        case inline
        case mirror
    }

    public private(set) var isVisible = false
    public private(set) var presentation: Presentation?
    /// The ghost being shown replaces text before the caret.
    private var replacementAccent = false
    /// What the last `show` drew: presentation, resolved font, panel frame. Never contains field text.
    public private(set) var debugSummary = ""

    private var panel: GhostPanel?
    private let ghostView = GhostView(frame: .zero)
    private let cardView = MirrorCardView(frame: .zero)
    private var fontKey: FontKey?
    private var measurer = TextMeasurer(font: .systemFont(ofSize: 13))
    /// Line-start x seen per field, for wrapping when the caret's line has soft-wrapped.
    private var lineStarts: [FieldIdentity: (fieldMinX: CGFloat, x: CGFloat)] = [:]
    /// Line-start intervals for apps that report whole-point rects.
    private var roundedLineStarts: [RoundedLineKey: ClosedRange<CGFloat>] = [:]
    private var generation = 0
    private var fadingOut = false

    /// Gap between the text edge and the field's frame.
    private static let fieldInset: CGFloat = 4
    private static let fadeIn: TimeInterval = 0.09
    private static let fadeOut: TimeInterval = 0.06

    public init() {}

    /// Draws `ghost.remainder` at the caret described by `snapshot`. When the snapshot lags behind the
    /// ghost (the user typed through faster than the app published), the drawing is shifted by the
    /// width of the characters already consumed.
    public func show(ghost: Ghost, snapshot: FieldSnapshot, appearance: Appearance) {
        var ghost = ghost
        replacementAccent = false
        if ghost.replacing > 0 {
            // A replacement (typo fix, emoji): show what the word before the caret becomes, not an append.
            ghost.text = " → " + ghost.text
            ghost.consumed = 0
            replacementAccent = true
        }
        let remainder = String(ghost.remainder)
        guard !remainder.allSatisfy(\.isWhitespace) else {
            hide(animated: false)
            return
        }
        let panel = ensurePanel()
        let mode = Self.presentation(for: snapshot, appearance: appearance)

        panel.disableScreenUpdatesUntilFlush()
        let frame: CGRect?
        switch mode {
        case .inline: frame = layoutInline(ghost: ghost, remainder: remainder, snapshot: snapshot, appearance: appearance)
        case .mirror: frame = layoutMirror(remainder: remainder, snapshot: snapshot)
        }
        guard let frame else {
            hide(animated: false)
            return
        }
        ghostView.isHidden = mode != .inline
        cardView.isHidden = mode != .mirror
        if panel.hasShadow != (mode == .mirror) { panel.hasShadow = mode == .mirror }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if mode == .mirror { panel.invalidateShadow() }
        presentation = mode
        present(panel, animate: appearance.animate)
    }

    public func hide(animated: Bool) {
        guard isVisible, let panel else { return }
        isVisible = false
        presentation = nil
        generation += 1
        let token = generation
        if animated, !Self.reduceMotion {
            fadingOut = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeOut
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.fadingOut = false
                    panel.orderOut(nil)
                }
            })
        } else {
            fadingOut = false
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    // MARK: - Presentation

    static func presentation(for snapshot: FieldSnapshot, appearance: Appearance) -> Presentation {
        guard !appearance.forceMirror, let caret = snapshot.caret, caret.quality > .estimated,
              caret.rect.height >= 2, caret.rect.minX.isFinite, caret.rect.minY.isFinite
        else { return .mirror }
        // Drawing over text that follows the caret looks broken; show mid-line suggestions in the card.
        return snapshot.caretAtEndOfLine ? .inline : .mirror
    }

    private func present(_ panel: GhostPanel, animate: Bool) {
        generation += 1   // a pending fade-out's completion no longer orders the panel out
        guard !isVisible else { return }
        isVisible = true
        let wasOnScreen = panel.isVisible
        if fadingOut {
            // Back while still fading out: replace the running animation, no second fade-in.
            fadingOut = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.orderFrontRegardless()
            return
        }
        if animate, !Self.reduceMotion, !wasOnScreen {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeIn
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func ensurePanel() -> GhostPanel {
        if let panel { return panel }
        let panel = GhostPanel()
        let root = OverlayRootView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        for view in [ghostView, cardView] as [NSView] {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            view.isHidden = true
            root.addSubview(view)
        }
        panel.contentView = root
        self.panel = panel
        return panel
    }

    // MARK: - Inline

    /// Lays out the inline ghost and returns the panel frame (AppKit space), or nil when nothing fits.
    private func layoutInline(ghost: Ghost, remainder: String, snapshot: FieldSnapshot, appearance: Appearance) -> CGRect? {
        guard let caret = snapshot.caret?.rect else { return nil }
        let space = ScreenInfo.current()
        let screen = space.screen(containingQuartz: CGPoint(x: caret.minX, y: caret.midY))

        let font = resolvedFont(style: snapshot.style, caretHeight: caret.height, scale: appearance.fontScale)
        let metrics = FontResolver.metrics(of: font)
        let measure = measurer.width

        // The field bounds the text horizontally; ignore a frame that doesn't contain the caret.
        let field = snapshot.fieldFrame.flatMap { f -> CGRect? in
            guard f.width > 8, f.height > 2, caret.minX >= f.minX - 2, caret.minX <= f.maxX + 2 else { return nil }
            return f
        }
        let caretX = refinedCaretX(snapshot: snapshot, caret: caret, field: field, measure: measure)
        let lag = GhostLayout.lagText(ghost: ghost, textBeforeCaret: snapshot.textBeforeCaret)
        let startX = caretX + measure(lag)

        let screenEdge = screen.quartzFrame.maxX - 2
        let rightEdge = min(field.map { $0.maxX - Self.fieldInset } ?? screenEdge, screenEdge)
        let lineStartX = lineStart(for: snapshot, caretX: caretX, field: field, measure: measure)

        let baseline = GhostLayout.baseline(
            caret: caret,
            metrics: metrics,
            verticalOffset: CGFloat(appearance.verticalOffset),
            wholePointRect: GhostLayout.isWholePointRect(caret)
        )
        let input = GhostLayout.LineInput(
            text: remainder,
            startX: startX,
            baseline: baseline,
            rightEdge: rightEdge,
            lineStartX: lineStartX,
            linePitch: GhostLayout.linePitch(caretHeight: caret.height, metrics: metrics),
            bottomLimit: field?.maxY,
            // Wrapped lines would cover whatever follows the caret; only wrap at the end of the text.
            allowWrap: !snapshot.isSingleLine && snapshot.textAfterCaret.allSatisfy(\.isWhitespace)
        )
        let fragments = GhostLayout.lines(input, metrics: metrics, measure: measure)
        guard let bounds = GhostLayout.bounds(of: fragments, metrics: metrics) else { return nil }

        // Window frames land on whole points; keep the fraction inside the view so glyphs stay exact.
        let frame = ScreenSpace.integralFrame(containing: ScreenSpace.appKitRect(fromQuartz: bounds, primaryHeight: space.primaryHeight))
        let lines = fragments.map { f -> GhostView.Line in
            let y = ScreenSpace.appKitY(fromQuartz: f.origin.y, primaryHeight: space.primaryHeight) - frame.minY
            return GhostView.Line(text: f.text, origin: CGPoint(x: f.origin.x - frame.minX, y: GhostLayout.pixelAligned(y, scale: screen.scale)))
        }
        let tint = GhostTint.color(host: snapshot.style?.textColor, opacity: appearance.opacity, grey: appearance.greyText, darkSystem: Self.systemIsDark)
        var color = NSColor(srgbRed: tint.r, green: tint.g, blue: tint.b, alpha: tint.a)
        if replacementAccent {
            // Corrections read as a proposal, not as more text: a calm green that works on light and dark.
            color = NSColor(srgbRed: 0.20, green: 0.66, blue: 0.40, alpha: max(0.75, tint.a))
        }
        ghostView.update(lines: lines, font: font, color: color)
        debugSummary = String(
            format: "inline font=%@ %.2fpt baseline=%.2f startX=%.2f lag=%d lines=%d rightEdge=%.1f lineStart=%.1f color=(%.2f,%.2f,%.2f,%.2f) frame=%@",
            font.fontName, font.pointSize, baseline, startX, lag.count, fragments.count, rightEdge, lineStartX,
            tint.r, tint.g, tint.b, tint.a, NSStringFromRect(frame)
        )
        return frame
    }

    /// The caret x, corrected for apps that floor their rects to whole points (see `refinedLineStart`).
    private func refinedCaretX(snapshot: FieldSnapshot, caret: CGRect, field: CGRect?, measure: (Substring) -> CGFloat) -> CGFloat {
        guard GhostLayout.isWholePointRect(caret), let field,
              GhostLayout.estimatedLineStart(caretX: caret.minX, textBeforeCaret: snapshot.textBeforeCaret, fieldFrame: field, measure: measure) != nil
        else { return caret.minX }
        let line = snapshot.textBeforeCaret.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        let width = measure(line)
        let key = RoundedLineKey(field: snapshot.field, lineY: caret.minY.rounded(), fieldMinX: field.minX.rounded())
        let interval = GhostLayout.refinedLineStart(previous: roundedLineStarts[key], caretX: caret.minX, lineWidth: width)
        if roundedLineStarts.count > 64 { roundedLineStarts.removeAll() }
        roundedLineStarts[key] = interval
        return (interval.lowerBound + interval.upperBound) / 2 + width
    }

    private func lineStart(for snapshot: FieldSnapshot, caretX: CGFloat, field: CGRect?, measure: (Substring) -> CGFloat) -> CGFloat {
        if let estimate = GhostLayout.estimatedLineStart(caretX: caretX, textBeforeCaret: snapshot.textBeforeCaret, fieldFrame: field, measure: measure) {
            if lineStarts.count > 64 { lineStarts.removeAll() }
            lineStarts[snapshot.field] = (field?.minX ?? 0, estimate)
            return estimate
        }
        if let field {
            if let known = lineStarts[snapshot.field], abs(known.fieldMinX - field.minX) < 0.5 { return known.x }
            return field.minX + Self.fieldInset
        }
        return caretX
    }

    private func resolvedFont(style: TextStyle?, caretHeight: CGFloat, scale: Double) -> NSFont {
        let key = FontKey(style: style, caretHeight: caretHeight, scale: scale)
        if key != fontKey {
            fontKey = key
            measurer = TextMeasurer(font: FontResolver.font(for: style, caretHeight: caretHeight, scale: CGFloat(scale)))
        }
        return measurer.font
    }

    // MARK: - Mirror

    private func layoutMirror(remainder: String, snapshot: FieldSnapshot) -> CGRect? {
        let space = ScreenInfo.current()
        let content = cardView.update(context: GhostLayout.mirrorContext(textBeforeCaret: snapshot.textBeforeCaret), ghost: remainder)

        // Below the caret's line when we trust it; an estimated caret only inside a large field.
        var line: CGRect?
        if let caret = snapshot.caret, caret.rect.height >= 2 {
            if caret.quality > .estimated {
                line = caret.rect
            } else if let f = snapshot.fieldFrame, f.height > 80, f.contains(CGPoint(x: caret.rect.midX, y: caret.rect.midY)) {
                line = caret.rect
            } else if snapshot.fieldFrame == nil {
                line = caret.rect
            }
        }
        let field = snapshot.fieldFrame.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        guard let anchor = line ?? field else { return nil }
        let screen = space.screen(containingQuartz: CGPoint(x: anchor.minX, y: anchor.midY))
        let alignX = line.map { $0.minX - content.ghostX } ?? field.map(\.minX)
        guard let quartz = GhostLayout.mirrorCardFrame(size: content.size, line: line, field: field, alignX: alignX, screen: screen.quartzVisibleFrame) else {
            return nil
        }
        // The card's own drawing is pixel-aligned, so a whole-point frame is enough.
        let frame = ScreenSpace.integralFrame(containing: ScreenSpace.appKitRect(fromQuartz: quartz, primaryHeight: space.primaryHeight))
        debugSummary = "mirror anchor=\(line == nil ? "field" : "caret") frame=\(NSStringFromRect(frame))"
        return frame
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static var systemIsDark: Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

private struct RoundedLineKey: Hashable {
    var field: FieldIdentity
    var lineY: CGFloat
    var fieldMinX: CGFloat
}

private struct FontKey: Equatable {
    var style: TextStyle?
    var caretHeight: CGFloat
    var scale: Double
}

/// The screens, in Quartz space, measured against the primary display (the one at AppKit origin zero).
struct ScreenInfo {
    struct Screen {
        var quartzFrame: CGRect
        var quartzVisibleFrame: CGRect
        var scale: CGFloat
    }

    var primaryHeight: CGFloat
    var screens: [Screen]

    @MainActor static func current() -> ScreenInfo {
        let all = NSScreen.screens
        let primary = all.first { $0.frame.origin == .zero } ?? all.first
        let height = primary?.frame.height ?? 0
        return ScreenInfo(primaryHeight: height, screens: all.map {
            Screen(
                quartzFrame: ScreenSpace.quartzRect(fromAppKit: $0.frame, primaryHeight: height),
                quartzVisibleFrame: ScreenSpace.quartzRect(fromAppKit: $0.visibleFrame, primaryHeight: height),
                scale: $0.backingScaleFactor
            )
        })
    }

    /// The screen containing `point`, else the nearest one.
    func screen(containingQuartz point: CGPoint) -> Screen {
        if let hit = screens.first(where: { $0.quartzFrame.contains(point) }) { return hit }
        func distance(_ s: Screen) -> CGFloat {
            let dx = max(s.quartzFrame.minX - point.x, 0, point.x - s.quartzFrame.maxX)
            let dy = max(s.quartzFrame.minY - point.y, 0, point.y - s.quartzFrame.maxY)
            return dx * dx + dy * dy
        }
        return screens.min { distance($0) < distance($1) }
            ?? Screen(quartzFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), quartzVisibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    }
}
