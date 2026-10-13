import SwiftUI
import TabberCore

/// A looping mock of Tabber at work: words typed, a grey suggestion after the caret, Tab taking it
/// one word at a time, then the key above Tab taking the rest.
struct GhostDemo: View {
    @StateObject private var model = GhostDemoModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 0) {
                Text(model.typed)
                    .foregroundStyle(OnboardingTheme.primary)
                    // The caret takes no width, so the suggestion sits exactly where the text continues.
                    .overlay(alignment: .trailing) {
                        Caret(visible: model.caretVisible)
                            .alignmentGuide(.trailing) { $0[.leading] }
                    }
                Text(model.ghost)
                    .foregroundStyle(OnboardingTheme.ghost)
                    .opacity(model.ghostShown ? 1 : 0)
                    .animation(.easeOut(duration: reduceMotion ? 0 : 0.22), value: model.ghostShown)
            }
            .font(.system(size: 21, weight: .regular))
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OnboardingTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(OnboardingTheme.surfaceBorder, lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Example: \(model.typed), suggestion: \(model.ghost)")

            HStack(spacing: 22) {
                KeyLegend(key: "⇥", title: "Next word", pressed: model.pressed == .word)
                KeyLegend(key: KeyGlyphs.key(KeyBinding.keyAboveTab.keyCode), title: "Whole suggestion", pressed: model.pressed == .all)
            }
            .padding(.leading, 2)
        }
        .task { await model.run() }
    }
}

struct KeyLegend: View {
    let key: String
    let title: String
    var pressed = false

    var body: some View {
        HStack(spacing: 9) {
            Keycap(label: key, pressed: pressed, fontSize: 13)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(pressed ? OnboardingTheme.primary : OnboardingTheme.secondary)
                .animation(.easeOut(duration: 0.15), value: pressed)
        }
    }
}

private struct Caret: View {
    let visible: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2, height: 25)
            .offset(x: 0.5)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: visible)
    }
}

@MainActor
private final class GhostDemoModel: ObservableObject {
    enum Key { case word, all }

    @Published var typed = ""
    @Published var ghost = ""
    @Published var ghostShown = false
    @Published var caretVisible = true
    @Published var pressed: Key?

    private struct Sample {
        let typed: String
        /// Suggested words, each with its leading space.
        let suggestion: [String]
        /// How many words Tab takes before the key above Tab takes the rest.
        let tabs: Int
    }

    private let samples = [
        Sample(typed: "Thanks for the notes, I'll", suggestion: [" send", " a", " new", " draft"], tabs: 2),
        Sample(typed: "Could we move our call to", suggestion: [" Thursday", " afternoon?"], tabs: 1),
        Sample(typed: "The first results look", suggestion: [" really", " promising"], tabs: 1),
    ]

    func run() async {
        var index = 0
        while !Task.isCancelled {
            await play(samples[index % samples.count])
            index += 1
        }
    }

    private func play(_ sample: Sample) async {
        typed = ""
        ghost = ""
        ghostShown = false
        caretVisible = true
        await pause(0.5, blinking: true)

        for character in sample.typed {
            guard !Task.isCancelled else { return }
            typed.append(character)
            // Uneven, human typing rhythm: quicker inside words, slower after spaces.
            await sleep(character == " " ? 0.11 : Double.random(in: 0.045...0.08))
        }

        var remaining = sample.suggestion
        ghost = remaining.joined()
        await sleep(0.12)
        ghostShown = true
        await pause(1.0, blinking: true)

        for _ in 0..<sample.tabs {
            await press(.word)
            typed += remaining.removeFirst()
            ghost = remaining.joined()
            await pause(0.8, blinking: true)
        }

        await press(.all)
        typed += remaining.joined()
        ghost = ""
        ghostShown = false
        await pause(2.2, blinking: true)
    }

    private func press(_ key: Key) async {
        pressed = key
        await sleep(0.13)
        pressed = nil
    }

    /// Waits, blinking the caret like a real text field.
    private func pause(_ seconds: Double, blinking: Bool) async {
        let step = 0.5
        var elapsed = 0.0
        while elapsed < seconds, !Task.isCancelled {
            let slice = min(step, seconds - elapsed)
            await sleep(slice)
            elapsed += slice
            if blinking { caretVisible.toggle() }
        }
        caretVisible = true
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
