import SwiftUI

/// A small physical-looking key. Works in light and dark appearances.
struct Keycap: View {
    let label: String
    var pressed = false
    var fontSize: CGFloat = 13

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: fontSize * 0.46, style: .continuous)
        let depth: CGFloat = fontSize * 0.14
        Text(label)
            .font(.system(size: isSmallMark ? fontSize * 1.35 : fontSize, weight: isSmallMark ? .semibold : .medium, design: isSmallMark ? .monospaced : .rounded))
            // Marks like ` and ^ sit at the top of the line; pull them to the middle of the key.
            .baselineOffset(isSmallMark ? -fontSize * 0.36 : 0)
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, label.count > 1 ? fontSize * 0.55 : 0)
            .frame(minWidth: fontSize * 2, minHeight: fontSize * 1.85)
            .background {
                shape.fill(face)
                    .overlay(shape.strokeBorder(edge, lineWidth: 1))
                    .overlay(alignment: .top) {
                        // Top highlight, the light catching the key's edge.
                        shape.strokeBorder(
                            LinearGradient(colors: [highlight, .clear], startPoint: .top, endPoint: .center),
                            lineWidth: 1
                        )
                    }
            }
            .background {
                shape.fill(base).offset(y: pressed ? 0 : depth)
            }
            .overlay {
                shape.strokeBorder(Color.accentColor.opacity(pressed ? 0.9 : 0), lineWidth: 1.5)
            }
            .offset(y: pressed ? depth : 0)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
            .padding(.bottom, depth)
            .accessibilityLabel(label)
    }

    private var isSmallMark: Bool {
        KeyGlyphs.isSmallMark(label) && label != "§"
    }

    private var face: Color { colorScheme == .dark ? .white.opacity(0.11) : .white }
    private var base: Color { colorScheme == .dark ? .black.opacity(0.55) : .black.opacity(0.14) }
    private var edge: Color { colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.12) }
    private var highlight: Color { colorScheme == .dark ? .white.opacity(0.14) : .white }
}
