import AppKit
import SwiftUI
import TabberCore

/// A small numbered list of other likely words, shown below the caret. Pressing the number picks one.
@MainActor
public final class AlternativesController {
    private var panel: GhostPanel?
    private var host: NSHostingView<AlternativesCard>?
    public private(set) var isVisible = false

    public init() {}

    /// Shows `words` (display strings) under the caret line of `snapshot`.
    public func show(_ words: [String], snapshot: FieldSnapshot) {
        guard !words.isEmpty, let caret = snapshot.caret?.rect else { return hide() }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let card = AlternativesCard(words: Array(words.prefix(3)), dark: Self.isDark)
        let panel = self.panel ?? {
            let p = GhostPanel()
            p.hasShadow = true
            self.panel = p
            return p
        }()
        let host = self.host ?? NSHostingView(rootView: card)
        host.rootView = card
        if self.host == nil {
            self.host = host
            panel.contentView = host
        }
        let size = host.fittingSize
        // Just below the caret's line, starting at the caret.
        let caretInAppKit = ScreenSpace.appKitRect(fromQuartz: caret, primaryHeight: primaryHeight)
        var origin = CGPoint(x: caretInAppKit.minX - 8, y: caretInAppKit.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caretInAppKit.origin) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            if origin.y < visible.minY + 4 { origin.y = caretInAppKit.maxY + 6 }
        }
        panel.setFrame(CGRect(origin: origin, size: size).integral, display: true)
        if !isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                panel.animator().alphaValue = 1
            }
        }
        isVisible = true
    }

    public func hide() {
        guard isVisible else { return }
        isVisible = false
        panel?.orderOut(nil)
    }

    private static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

struct AlternativesCard: View {
    var words: [String]
    var dark: Bool

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    Text(word)
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dark ? Color(white: 0.16) : Color(white: 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .environment(\.colorScheme, dark ? .dark : .light)
        .fixedSize()
    }
}
