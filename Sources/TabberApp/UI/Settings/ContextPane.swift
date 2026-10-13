import SwiftUI

struct ContextPane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.settings.useScreenContext) {
                    Text("Use text on screen")
                    Text("Reads text near the field you're typing in, such as the email you're replying to. Recognized on this Mac and never saved.")
                }
                PermissionRow(
                    title: "Screen Recording",
                    caption: state.permissions.screenRecording ? nil : "Needed to read text on screen.",
                    granted: state.permissions.screenRecording,
                    action: SystemIntegration.requestScreenRecording
                )
                .disabled(!store.settings.useScreenContext)
            }
            .livePermissions()

            Section {
                Toggle(isOn: $store.settings.useClipboardContext) {
                    Text("Use recently copied text")
                    Text("Text you copied in the last few minutes. Passwords and other concealed items are skipped.")
                }
            }

            Section {
                TextField("Your name", text: $store.settings.authorName, prompt: Text("Optional"))
            } footer: {
                Text("Helps with sign-offs and with telling your messages apart from others' on screen.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                InstructionsEditor(text: $store.settings.customInstructions)
            } header: {
                Text("Custom instructions")
            } footer: {
                Text("A few sentences work best. Longer instructions dilute the model's focus.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

/// A multi-line editor with a placeholder, sized for a few sentences.
struct InstructionsEditor: View {
    @Binding var text: String
    var placeholder = "I write in British English. Keep a friendly, direct tone."
    var minHeight: CGFloat = 76

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .accessibilityLabel("Custom instructions")
        }
        .font(.system(size: 13))
        .frame(minHeight: minHeight)
    }
}
