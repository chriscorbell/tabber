import SwiftUI
import TabberCore

struct ShortcutsPane: View {
    @EnvironmentObject private var store: SettingsStore

    private enum Action: CaseIterable {
        case acceptWord, acceptAll, force, pause

        var title: String {
            switch self {
            case .acceptWord: "Accept next word"
            case .acceptAll: "Accept whole suggestion"
            case .force: "Suggest now"
            case .pause: "Pause in current app"
            }
        }

        var caption: String? {
            switch self {
            case .acceptWord, .acceptAll: nil
            case .force: "Asks for a suggestion where Tabber normally stays quiet."
            case .pause: "Turns suggestions off in this app for a few minutes."
            }
        }

        var keyPath: WritableKeyPath<TabberSettings, KeyBinding?> {
            switch self {
            case .acceptWord: \.acceptWordKey
            case .acceptAll: \.acceptAllKey
            case .force: \.forceActivateKey
            case .pause: \.pauseInAppKey
            }
        }

        /// Hotkeys work everywhere, so they need a modifier.
        var isHotkey: Bool { self == .force || self == .pause }
    }

    var body: some View {
        Form {
            Section {
                ForEach([Action.acceptWord, .acceptAll], id: \.self, content: row)
                Picker("Esc", selection: $store.settings.escapeBehavior) {
                    ForEach(EscapeBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
            } header: {
                Text("While a suggestion is showing")
            } footer: {
                Text("\(KeyGlyphs.string(KeyBinding(keyCode: 48, modifiers: .option))) always sends a real Tab, even while a suggestion is showing.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                ForEach([Action.force, .pause], id: \.self, content: row)
            } header: {
                Text("Anywhere")
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        let defaults = TabberSettings()
                        for action in Action.allCases {
                            store.settings[keyPath: action.keyPath] = defaults[keyPath: action.keyPath]
                        }
                        store.settings.escapeBehavior = defaults.escapeBehavior
                    }
                    .disabled(isDefault)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: Action) -> some View {
        LabeledContent {
            ShortcutRecorder(binding: $store.settings[dynamicMember: action.keyPath], requiresModifier: action.isHotkey)
        } label: {
            Text(action.title)
            if let conflict = conflict(for: action) {
                Text("Same as \(conflict.title.lowercased())")
                    .foregroundStyle(.orange)
            } else if let caption = action.caption {
                Text(caption)
            }
        }
    }

    private func conflict(for action: Action) -> Action? {
        guard let binding = store.settings[keyPath: action.keyPath] else { return nil }
        return Action.allCases.first { $0 != action && store.settings[keyPath: $0.keyPath] == binding }
    }

    private var isDefault: Bool {
        let defaults = TabberSettings()
        return Action.allCases.allSatisfy { store.settings[keyPath: $0.keyPath] == defaults[keyPath: $0.keyPath] }
            && store.settings.escapeBehavior == defaults.escapeBehavior
    }
}
