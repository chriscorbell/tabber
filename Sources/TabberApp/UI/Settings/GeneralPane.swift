import SwiftUI
import TabberCore

struct GeneralPane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var state: AppState

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var inlinePredictionsOff = !InlinePredictions.isEnabled
    @State private var inlinePredictionsNote: String?

    var body: some View {
        Form {
            if !state.permissions.accessibility {
                Section {
                    PermissionRow(
                        title: "Tabber needs \(SystemIntegration.accessibilityPermissionPhrase)",
                        caption: "Without it, Tabber can't see what you type or insert suggestions.",
                        granted: false,
                        action: SystemIntegration.requestAccessibility
                    )
                }
                .livePermissions()
            }

            Section {
                Toggle("Show suggestions", isOn: $store.settings.enabled)

                Picker(selection: $store.settings.length) {
                    ForEach(CompletionLength.allCases, id: \.self) { length in
                        Text(length.title).tag(length)
                    }
                } label: {
                    Text("Suggestion length")
                    Text(wordRange(store.settings.length))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: store.settings.length)
                }
                .pickerStyle(.menu)

                Toggle(isOn: $store.settings.allowMidLine) {
                    Text("Suggest in the middle of a line")
                    Text("Also suggest when there's text after the cursor.")
                }
            }

            Section("Accepting") {
                Toggle(isOn: $store.settings.autocorrect) {
                    Text("Suggest fixes for typos")
                    Text("After a misspelled word, the suggestion is the corrected word. Tab applies it.")
                }
                Toggle(isOn: $store.settings.emojiSuggestions) {
                    Text("Suggest emoji")
                    Text("Type a colon and a name, like :joy, or a face like :)")
                }
                Toggle(isOn: $store.settings.showAlternatives) {
                    Text("Offer other words after a pause")
                    Text("When you stop at a suggestion, a numbered list of alternatives appears below it. Press the number to use one.")
                }
                Toggle("Add a space after an accepted word", isOn: $store.settings.includeTrailingSpace)
                Toggle(isOn: $store.settings.includeTrailingPunctuation) {
                    Text("Include punctuation")
                    Text("Accepting the last word of a sentence also takes its period or comma.")
                }
            }

            Section("Appearance") {
                LabeledContent("Suggestion opacity") {
                    Slider(value: $store.settings.ghostOpacity, in: 0.2...0.9)
                        .frame(maxWidth: 200)
                }
                GhostPreview(opacity: store.settings.ghostOpacity)
                Toggle("Animate suggestions", isOn: $store.settings.animateSuggestions)
                Toggle(isOn: $store.settings.showMenuBarIcon) {
                    Text("Show in menu bar")
                    if !store.settings.showMenuBarIcon {
                        Text("Open Tabber again from your Applications folder to get back to Settings.")
                    }
                }
            }

            Section("On battery") {
                Toggle(isOn: $store.settings.onDemandOnBattery) {
                    Text("Only suggest when asked")
                    Text(forceShortcutCaption)
                }
                Toggle("Shorter suggestions", isOn: $store.settings.shorterOnBattery)
            }

            Section("System") {
                Toggle(isOn: loginBinding) {
                    Text("Open at login")
                    if let loginError { Text(loginError) }
                }
                Toggle(isOn: inlinePredictionsBinding) {
                    Text("Turn off macOS inline predictions")
                    Text(inlinePredictionsNote ?? "They compete with Tabber for the Tab key.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            inlinePredictionsOff = !InlinePredictions.isEnabled
        }
    }

    private func wordRange(_ length: CompletionLength) -> String {
        let range = length.wordRange
        return "About \(range.lowerBound) to \(range.upperBound) words"
    }

    private var forceShortcutCaption: String {
        if let key = store.settings.forceActivateKey {
            return "Press \(KeyGlyphs.string(key)) for a suggestion."
        }
        return "Set a shortcut for forcing a suggestion in Shortcuts."
    }

    private var loginBinding: Binding<Bool> {
        Binding {
            launchAtLogin
        } set: { enabled in
            do {
                try LoginItem.setEnabled(enabled)
                loginError = LoginItem.needsApproval ? "Approve Tabber in System Settings > General > Login Items." : nil
            } catch {
                loginError = "Couldn't change the login item. Move Tabber to Applications and try again."
            }
            launchAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
        }
    }

    private var inlinePredictionsBinding: Binding<Bool> {
        Binding {
            inlinePredictionsOff
        } set: { off in
            if InlinePredictions.setEnabled(!off) {
                inlinePredictionsOff = off
                inlinePredictionsNote = "Apps pick this up the next time they open."
            } else {
                SystemIntegration.openKeyboardSettings()
                inlinePredictionsNote = "Turn off \"Show inline predictive text\" under Text Input > Edit."
            }
        }
    }
}

/// A line of sample text with a suggestion at the chosen opacity.
private struct GhostPreview: View {
    let opacity: Double

    var body: some View {
        HStack(spacing: 0) {
            Text("Thanks for the update, I'll")
                .foregroundStyle(.primary)
            Text(" send the draft tonight")
                .foregroundStyle(.primary.opacity(opacity))
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of suggestion opacity")
    }
}
