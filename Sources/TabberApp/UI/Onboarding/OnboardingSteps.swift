import AppKit
import SwiftUI
import TabberCore

// MARK: - Welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Welcome to Tabber",
                subtitle: "Tabber suggests your next words as you type, in any app, using a model that runs entirely on this Mac."
            )
            Spacer(minLength: 28)
            GhostDemo()
            Spacer(minLength: 28)
        }
    }
}

// MARK: - Accessibility

struct AccessibilityStep: View {
    @EnvironmentObject private var state: AppState

    private var granted: Bool { state.permissions.accessibility }
    private let paneName = SystemIntegration.accessibilityPaneName

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            StepHeader(
                title: "Allow \(SystemIntegration.accessibilityPermissionPhrase)",
                subtitle: "Tabber reads the text field you're typing in and types the words you accept. Nothing leaves this Mac."
            )

            PermissionPreview(granted: granted)

            ZStack(alignment: .leading) {
                if granted {
                    HStack(spacing: 8) {
                        Icon(.circleCheck, size: 17)
                            .foregroundStyle(OnboardingTheme.success)
                        Text("Access granted")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Open System Settings", action: SystemIntegration.requestAccessibility)
                            .buttonStyle(OnboardingButtonStyle(kind: .primary))
                        Text("Then turn on Tabber in Privacy & Security > \(paneName).")
                            .font(.system(size: 12.5))
                            .foregroundStyle(OnboardingTheme.tertiary)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: granted)
        }
    }
}

/// A small likeness of the System Settings row the user needs to switch on. The switch flips when
/// access is granted.
private struct PermissionPreview: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            Text("Tabber")
                .font(.system(size: 14, weight: .medium))
            Spacer()
            MiniSwitch(on: granted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OnboardingTheme.surfaceBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(granted ? "Tabber is allowed" : "Tabber is not allowed yet")
    }
}

private struct MiniSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? OnboardingTheme.success : Color.white.opacity(0.16))
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.68), value: on)
    }
}

// MARK: - Model

struct ModelStep: View {
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var store: SettingsStore

    /// The catalog model this step offers: the user's pick, else whatever is selected, else the recommendation.
    private var model: ModelManager.Model {
        let candidates = [store.settings.modelID, models.selectedModelID, models.recommendedModelID()]
        for id in candidates.compactMap({ $0 }) {
            if let model = models.model(id) { return model }
        }
        return models.catalog[0]
    }

    private var installed: Bool { models.installed.contains(model.id) }
    private var progress: Double? { models.downloads[model.id] }

    private var sizeLine: String {
        let size = ModelManager.formatBytes(model.sizeBytes) + (installed ? " on disk." : " download.")
        return models.recommendedModelID() == model.id ? "Recommended for this Mac. \(size)" : size
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            StepHeader(
                title: installed ? "Your model is ready" : "Download a model",
                subtitle: "Suggestions come from a language model that runs on this Mac. What you type never leaves it."
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Icon(.cpu, size: 22, weight: 1.7)
                        .foregroundStyle(OnboardingTheme.secondary)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(model.displayName)
                                .font(.system(size: 16, weight: .semibold))
                            Text(model.tier)
                                .font(.system(size: 12.5))
                                .foregroundStyle(OnboardingTheme.tertiary)
                        }
                        Text(model.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(OnboardingTheme.secondary)
                        Text(sizeLine)
                            .font(.system(size: 12.5))
                            .foregroundStyle(OnboardingTheme.tertiary)
                    }

                    Spacer(minLength: 8)

                    trailing
                }

                if let progress {
                    DownloadProgress(progress: progress, total: model.sizeBytes, tint: .white.opacity(0.9))
                        .padding(.leading, 54)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let error = models.downloadErrors[model.id] {
                    Text(error)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.red.opacity(0.9))
                        .padding(.leading, 54)
                }

                if let notice = model.licenseNotice {
                    Text(notice)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnboardingTheme.tertiary)
                        .tint(OnboardingTheme.secondary)
                        .padding(.leading, 54)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OnboardingTheme.surfaceBorder, lineWidth: 1))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: progress != nil)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: installed)

            HStack(spacing: 14) {
                Menu {
                    ForEach(models.catalog) { option in
                        Button {
                            models.select(option.id)
                        } label: {
                            Text("\(option.displayName), \(option.tier.lowercased()), \(ModelManager.formatBytes(option.sizeBytes))\(models.installed.contains(option.id) ? ", downloaded" : "")")
                        }
                    }
                } label: {
                    Text("Choose a different model")
                }
                .menuStyle(.button)
                .buttonStyle(OnboardingButtonStyle(kind: .quiet))
                .fixedSize()

                if progress != nil {
                    Text("You can continue while it downloads.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(OnboardingTheme.tertiary)
                        .transition(.opacity)
                }
            }
            .padding(.leading, -12)
            .animation(.easeOut(duration: 0.2), value: progress != nil)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if installed {
            HStack(spacing: 6) {
                Icon(.circleCheck, size: 15)
                    .foregroundStyle(OnboardingTheme.success)
                Text("Downloaded")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingTheme.secondary)
            }
            .padding(.top, 2)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if progress != nil {
            Button("Stop") { models.cancelDownload(model.id) }
                .buttonStyle(OnboardingButtonStyle(kind: .secondary))
        } else {
            Button(models.resumable.contains(model.id) ? "Resume" : "Download") { models.download(model.id) }
                .buttonStyle(OnboardingButtonStyle(kind: .primary))
        }
    }
}

// MARK: - Practice

struct PracticeStep: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var models: ModelManager
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(
                title: "Try it",
                subtitle: "Take a suggestion one word at a time, or keep typing to steer it."
            )

            PracticeTextView(text: $text, placeholder: "Type a sentence and press ⇥ to accept a word")
                .frame(height: 132)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OnboardingTheme.surfaceBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 22) {
                KeyLegend(key: "⇥", title: "Next word")
                KeyLegend(key: KeyGlyphs.key(KeyBinding.keyAboveTab.keyCode), title: "Whole suggestion")
                KeyLegend(key: "esc", title: "Dismiss")
            }

            if let note = readinessNote {
                HStack(spacing: 7) {
                    Icon(.circleAlert, size: 14)
                    Text(note)
                        .contentTransition(.numericText())
                }
                .font(.system(size: 12.5))
                .foregroundStyle(OnboardingTheme.tertiary)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: readinessNote)
    }

    /// Why suggestions might not show yet, if there's a reason.
    private var readinessNote: String? {
        if !state.permissions.accessibility {
            return "Suggestions appear once Tabber is allowed in \(SystemIntegration.accessibilityPaneName)."
        }
        if let progress = models.downloads.values.max() {
            return "Suggestions start when the model finishes downloading (\(Int(progress * 100))%)."
        }
        switch state.engineStatus {
        case .ready: return nil
        case .loading: return "Loading the model…"
        case let .failed(message): return message
        case .noModel: return models.selectedModelID == nil ? "Download a model to see suggestions." : nil
        }
    }
}

// MARK: - Extras

struct ExtrasStep: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: SettingsStore
    @State private var predictionsOff = !InlinePredictions.isEnabled
    @State private var predictionsNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(title: "A few extras", subtitle: "All optional. You can change them later in Settings.")

            VStack(spacing: 0) {
                ExtraRow(icon: .scanText, title: "Use text on screen", caption: "Suggestions can match the email or chat you're replying to.") {
                    if state.permissions.screenRecording {
                        HStack(spacing: 6) {
                            Icon(.circleCheck, size: 14)
                                .foregroundStyle(OnboardingTheme.success)
                            Text("Allowed")
                                .font(.system(size: 13))
                                .foregroundStyle(OnboardingTheme.secondary)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else {
                        Button("Allow…") {
                            store.settings.useScreenContext = true
                            SystemIntegration.requestScreenRecording()
                        }
                        .buttonStyle(OnboardingButtonStyle(kind: .secondary))
                        .transition(.opacity)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.permissions.screenRecording)

                Rectangle()
                    .fill(OnboardingTheme.surfaceBorder)
                    .frame(height: 1)
                    .padding(.leading, 48)

                ExtraRow(icon: .keyboard, title: "Turn off macOS inline predictions", caption: predictionsNote ?? "They compete with Tabber for the Tab key.") {
                    Toggle("", isOn: predictionsBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OnboardingTheme.surfaceBorder, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                DarkField(label: "Your name") {
                    TextField("", text: $store.settings.authorName, prompt: Text("Optional").foregroundStyle(OnboardingTheme.tertiary))
                        .textFieldStyle(.plain)
                }
                DarkField(label: "Instructions", alignment: .top) {
                    InstructionsEditor(text: $store.settings.customInstructions, minHeight: 40)
                        .frame(height: 52)
                        .padding(.horizontal, -5)
                }
            }
        }
    }

    private var predictionsBinding: Binding<Bool> {
        Binding {
            predictionsOff
        } set: { off in
            if InlinePredictions.setEnabled(!off) {
                predictionsOff = off
                predictionsNote = nil
            } else {
                SystemIntegration.openKeyboardSettings()
                predictionsNote = "Turn off \"Show inline predictive text\" in Keyboard > Text Input."
            }
        }
    }
}

private struct ExtraRow<Trailing: View>: View {
    let icon: LucideIcon
    let title: String
    let caption: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Icon(icon, size: 18, weight: 1.8)
                .foregroundStyle(OnboardingTheme.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Text(caption)
                    .font(.system(size: 12.5))
                    .foregroundStyle(OnboardingTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A labelled input on the dark surface, label to the left.
private struct DarkField<Content: View>: View {
    let label: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: 0) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(OnboardingTheme.secondary)
                .frame(width: 96, alignment: .leading)
                .padding(.top, alignment == .top ? 8 : 0)
            content
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OnboardingTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(OnboardingTheme.surfaceBorder, lineWidth: 1))
        }
    }
}

// MARK: - Done

struct DoneStep: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var iconShown = false
    @State private var menuShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            StepHeader(
                title: "Tabber lives in your menu bar",
                subtitle: "Click its icon to pause suggestions, turn them off for one app, or open Settings."
            )

            // A likeness of the menu bar's right end with Tabber's menu open.
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Spacer()
                    Icon(.tabberMark, size: 17, weight: 2.1)
                        .foregroundStyle(OnboardingTheme.primary)
                        .frame(width: 34, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(menuShown ? 0.16 : 0))
                        )
                        .scaleEffect(iconShown ? 1 : 0.5)
                        .opacity(iconShown ? 1 : 0)
                        .padding(.trailing, 10)
                }
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OnboardingTheme.surface)
                )

                MenuLikeness(status: statusTitle)
                    .padding(.trailing, 6)
                    .scaleEffect(menuShown ? 1 : 0.94, anchor: .topTrailing)
                    .opacity(menuShown ? 1 : 0)
                    .offset(y: menuShown ? 0 : -6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tabber's icon at the right end of the menu bar, with its menu open")
        }
        .onAppear {
            let spring = Animation.spring(response: 0.5, dampingFraction: 0.7)
            withAnimation(reduceMotion ? .default : spring.delay(0.15)) { iconShown = true }
            withAnimation(reduceMotion ? .default : .spring(response: 0.42, dampingFraction: 0.82).delay(0.65)) { menuShown = true }
        }
    }

    private var statusTitle: String {
        if case let .ready(name) = state.engineStatus { return "\(name) is ready" }
        return "Tabber"
    }
}

private struct MenuLikeness: View {
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(status)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(OnboardingTheme.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            row("Suggestions", checked: true)
            row("Pause for 10 Minutes")
            Rectangle().fill(OnboardingTheme.surfaceBorder).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 4)
            row("Disable in Mail")
            row("Settings…", shortcut: "⌘,")
        }
        .padding(.vertical, 6)
        .frame(width: 232)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.145))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func row(_ title: String, checked: Bool = false, shortcut: String? = nil) -> some View {
        HStack(spacing: 6) {
            Icon(.check, size: 11, weight: 2.6)
                .opacity(checked ? 1 : 0)
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut).foregroundStyle(OnboardingTheme.tertiary)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(OnboardingTheme.primary)
        .padding(.horizontal, 10)
        .frame(height: 22)
    }
}
