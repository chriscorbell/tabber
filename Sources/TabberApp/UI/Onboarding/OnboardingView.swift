import SwiftUI

enum OnboardingTheme {
    static let background = Color(red: 0.074, green: 0.074, blue: 0.082)
    static let surface = Color.white.opacity(0.045)
    static let surfaceBorder = Color.white.opacity(0.08)
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    static let ghost = Color.white.opacity(0.32)
    static let success = Color(red: 0.36, green: 0.84, blue: 0.56)

    static let stepSpring = Animation.spring(response: 0.5, dampingFraction: 0.86)
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, accessibility, model, practice, extras, done
}

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var models: ModelManager
    @Environment(\.appActions) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: OnboardingStep = Self.initialStep
    @State private var forward = true

    private static var initialStep: OnboardingStep {
        #if DEBUG
        // `-TabberOnboardingStep 3` opens a step directly, for working on the UI.
        if let step = OnboardingStep(rawValue: UserDefaults.standard.integer(forKey: "TabberOnboardingStep")) { return step }
        #endif
        return .welcome
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                content(step)
                    .id(step)
                    .transition(transition)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 48)
            .padding(.top, 56)
            .clipped()

            footer
                .padding(.horizontal, 32)
                .padding(.bottom, 26)
        }
        .frame(width: 640, height: 480)
        .background(OnboardingTheme.background)
        .foregroundStyle(OnboardingTheme.primary)
        .livePermissions()
    }

    @ViewBuilder
    private func content(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome: WelcomeStep()
        case .accessibility: AccessibilityStep()
        case .model: ModelStep()
        case .practice: PracticeStep()
        case .extras: ExtrasStep()
        case .done: DoneStep()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            StepIndicator(count: OnboardingStep.allCases.count, current: step.rawValue)
            Spacer()
            Button("Back") { go(by: -1) }
                .buttonStyle(OnboardingButtonStyle(kind: .quiet))
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Get Started") { go(by: 1) }
                .buttonStyle(OnboardingButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        case .done:
            Button("Finish", action: actions.finishOnboarding)
                .buttonStyle(OnboardingButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        case .practice, .extras:
            // No Return shortcut: these steps have text fields.
            Button("Continue") { go(by: 1) }
                .buttonStyle(OnboardingButtonStyle(kind: .primary))
        case .accessibility, .model:
            // Quiet until the step's own action is done, so the in-page button leads.
            Button("Continue") { go(by: 1) }
                .buttonStyle(OnboardingButtonStyle(kind: stepComplete ? .primary : .secondary))
                .keyboardShortcut(stepComplete ? .defaultAction : nil)
                .animation(.easeOut(duration: 0.2), value: stepComplete)
        }
    }

    private var stepComplete: Bool {
        switch step {
        case .accessibility: state.permissions.accessibility
        case .model: models.selectedModelID != nil || !models.downloads.isEmpty
        default: true
        }
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let distance: CGFloat = 26
        return .asymmetric(
            insertion: .modifier(
                active: SlideFade(x: forward ? distance : -distance, opacity: 0, blur: 5),
                identity: SlideFade(x: 0, opacity: 1, blur: 0)
            ),
            removal: .modifier(
                active: SlideFade(x: forward ? -distance : distance, opacity: 0, blur: 5),
                identity: SlideFade(x: 0, opacity: 1, blur: 0)
            )
        )
    }

    private func go(by delta: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        // Set the direction first so the outgoing step uses it for its removal transition.
        forward = delta > 0
        DispatchQueue.main.async {
            withAnimation(OnboardingTheme.stepSpring) { step = next }
        }
    }
}

private struct SlideFade: ViewModifier {
    let x: CGFloat
    let opacity: Double
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .opacity(opacity)
            .blur(radius: blur)
    }
}

/// Dots for each step; the current one stretches into a pill.
private struct StepIndicator: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == current ? 0.9 : (index < current ? 0.42 : 0.14)))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

struct OnboardingButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, kind == .quiet ? 12 : 16)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            )
            .foregroundStyle(foreground)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        switch kind {
        case .primary: Color.white.opacity(pressed ? 0.82 : 0.94)
        case .secondary: Color.white.opacity(pressed ? 0.16 : 0.1)
        case .quiet: Color.white.opacity(pressed ? 0.08 : 0)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color(red: 0.07, green: 0.07, blue: 0.08)
        case .secondary: OnboardingTheme.primary
        case .quiet: OnboardingTheme.secondary
        }
    }
}

/// Title and one supporting line, shared by every step.
struct StepHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(OnboardingTheme.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .lineSpacing(2.5)
                    .foregroundStyle(OnboardingTheme.secondary)
                    .frame(maxWidth: 460, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
