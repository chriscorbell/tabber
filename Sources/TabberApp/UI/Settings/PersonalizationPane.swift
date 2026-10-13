import SwiftUI

struct PersonalizationPane: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var confirmingDelete = false
    @State private var deleted = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.settings.recordWriting) {
                    Text("Learn from my writing")
                    Text("Keeps what you type where Tabber is active, so suggestions use your words. It stays on this Mac.")
                }
            }

            Section {
                LabeledContent {
                    VStack(spacing: 3) {
                        Slider(value: $store.settings.personalization, in: 0...1)
                        HStack {
                            Text("Off")
                            Spacer()
                            Text("Strong")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 220)
                } label: {
                    Text("Word choice")
                    Text("How strongly suggestions lean toward words you use often.")
                }
            }
            .disabled(!store.settings.recordWriting)

            Section {
                LabeledContent {
                    Button("Delete…", role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Text("Recorded writing")
                    Text(deleted ? "Deleted." : "Everything Tabber has kept from your typing.")
                        .contentTransition(.opacity)
                }
                .animation(.easeOut(duration: 0.2), value: deleted)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete everything Tabber has recorded?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                NotificationCenter.default.post(name: .tabberDeleteHistory, object: nil)
                deleted = true
            }
        } message: {
            Text("Suggestions will no longer lean toward your past writing. This can't be undone.")
        }
    }
}
