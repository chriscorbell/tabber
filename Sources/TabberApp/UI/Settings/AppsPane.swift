import AppKit
import SwiftUI
import TabberCore
import UniformTypeIdentifiers

struct AppsPane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var state: AppState
    /// The app or website being edited; nil shows the list.
    @State private var selected: String?
    @State private var addingWebsite = false

    var body: some View {
        ZStack {
            if let key = selected, store.settings.overrides[key] != nil {
                OverrideDetail(key: key, back: { selected = nil }) {
                    selected = nil
                    store.removeOverride(key)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: selected)
        .sheet(isPresented: $addingWebsite) {
            AddWebsiteSheet(suggestion: state.focusedDomain) { domain in
                store.addOverride(domain)
                selected = domain
            }
        }
    }

    private var list: some View {
            Form {
                Section {
                    if keys.isEmpty {
                        VStack(spacing: 4) {
                            Text("No apps or websites yet")
                                .fontWeight(.medium)
                            Text("Add one to turn suggestions off there, stop Tab from accepting, or give it its own instructions.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    ForEach(keys, id: \.self) { key in
                        Button {
                            selected = key
                        } label: {
                            HStack {
                                OverrideRow(key: key)
                                Spacer()
                                Icon(.chevronRight, size: 13)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove") { store.removeOverride(key) }
                        }
                    }
                } footer: {
                    HStack(spacing: 8) {
                        Spacer()
                        Menu("Add App") { addAppMenu }
                            .fixedSize()
                        Button("Add Website…") { addingWebsite = true }
                    }
                }
            }
            .formStyle(.grouped)
            .animation(.default, value: keys)
    }

    private var keys: [String] {
        store.settings.overrides.keys.sorted { title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending }
    }

    private func title(for key: String) -> String {
        InstalledApp.isWebsite(key) ? key : InstalledApp.name(for: key)
    }

    @ViewBuilder
    private var addAppMenu: some View {
        let running = runningApps
        if let focused = state.focusedBundleID, store.settings.overrides[focused] == nil, focused != Bundle.main.bundleIdentifier {
            Button(state.focusedAppName ?? InstalledApp.name(for: focused)) { add(focused) }
            Divider()
        }
        ForEach(running, id: \.self) { bundleID in
            Button(InstalledApp.name(for: bundleID)) { add(bundleID) }
        }
        if !running.isEmpty { Divider() }
        Button("Choose from Applications…", action: chooseApps)
    }

    private var runningApps: [String] {
        let own = Bundle.main.bundleIdentifier
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != own && $0 != state.focusedBundleID && store.settings.overrides[$0] == nil }
        return Array(Set(ids)).sorted { InstalledApp.name(for: $0).localizedStandardCompare(InstalledApp.name(for: $1)) == .orderedAscending }
    }

    private func add(_ bundleID: String) {
        store.addOverride(bundleID)
        selected = bundleID
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        ids.forEach(store.addOverride)
        if ids.count == 1 { selected = ids[0] }
    }
}

private struct OverrideRow: View {
    let key: String
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        let website = InstalledApp.isWebsite(key)
        HStack(spacing: 10) {
            AppIconView(key: key, isWebsite: website, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(website ? key : InstalledApp.name(for: key))
                if let summary = summary(store.override(for: key)) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func summary(_ o: AppOverride) -> String? {
        var parts: [String] = []
        if o.enabled == false { parts.append("Off") }
        if o.tabAccepts == false { parts.append("Tab off") }
        if o.allowMidLine == true { parts.append("Mid-line on") }
        if o.allowMidLine == false { parts.append("Mid-line off") }
        if let instructions = o.instructions, !instructions.isEmpty { parts.append("Instructions") }
        if o.forceMirror == true { parts.append("Mirror") }
        if o.greyText == true { parts.append("Grey text") }
        if let scale = o.fontScale, scale != 1 { parts.append("Font \(Int((scale * 100).rounded()))%") }
        if let offset = o.verticalOffset, offset != 0 { parts.append("Offset \(offset.formatted(.number.precision(.fractionLength(0...1)))) pt") }
        if let insertion = o.insertion { parts.append(insertion.title) }
        if o.ignoreSizeThresholds == true { parts.append("Small fields") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private struct OverrideDetail: View {
    let key: String
    let back: () -> Void
    let remove: () -> Void

    @EnvironmentObject private var store: SettingsStore

    private var isWebsite: Bool { InstalledApp.isWebsite(key) }
    private var name: String { isWebsite ? key : InstalledApp.name(for: key) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppIconView(key: key, isWebsite: isWebsite, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline)
                        Text(isWebsite ? "Website" : key)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Remove", role: .destructive, action: remove)
                }
                .padding(.vertical, 2)
            } header: {
                Button(action: back) {
                    HStack(spacing: 3) {
                        Icon(.chevronLeft, size: 13, weight: 2.4)
                        Text("Apps & Websites")
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to all apps and websites")
            }

            Section {
                Toggle("Show suggestions", isOn: bool(\.enabled, default: !SettingsStore.defaultDisabledBundleIDs.contains(key)))
                if !isWebsite {
                    Toggle(isOn: bool(\.tabAccepts, default: true)) {
                        Text("Tab accepts suggestions")
                        Text("Turn off where Tab moves between fields. The whole-suggestion key still works.")
                    }
                }
                Toggle("Suggest in the middle of a line", isOn: bool(\.allowMidLine, default: store.settings.allowMidLine))
            }

            Section {
                InstructionsEditor(text: text(\.instructions), placeholder: "Keep replies short and casual here.", minHeight: 56)
            } header: {
                Text("Instructions")
            } footer: {
                Text("Added after your custom instructions.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isWebsite {
                Section("Display") {
                    Toggle(isOn: bool(\.forceMirror, default: false)) {
                        Text("Show suggestions in a floating mirror")
                        Text("For apps where suggestions don't line up with your text.")
                    }
                    Toggle(isOn: bool(\.greyText, default: false)) {
                        Text("Grey suggestion text")
                        Text("For apps that report the wrong text color.")
                    }
                    LabeledContent("Font size") {
                        HStack(spacing: 10) {
                            Slider(value: number(\.fontScale, default: 1, step: 0.05), in: 0.7...1.5)
                                .frame(maxWidth: 170)
                            Text("\(Int((store.override(for: key).fontScale ?? 1) * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    LabeledContent("Vertical offset") {
                        HStack(spacing: 10) {
                            Slider(value: number(\.verticalOffset, default: 0, step: 0.5), in: -8...8)
                                .frame(maxWidth: 170)
                            Text("\((store.override(for: key).verticalOffset ?? 0).formatted(.number.precision(.fractionLength(0...1)))) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }

                Section("Compatibility") {
                    Picker("Insert text by", selection: insertion) {
                        Text("Default").tag(InsertionMethod?.none)
                        Divider()
                        ForEach(InsertionMethod.allCases, id: \.self) { method in
                            Text(method.title).tag(InsertionMethod?.some(method))
                        }
                    }
                    Toggle(isOn: bool(\.ignoreSizeThresholds, default: false)) {
                        Text("Suggest in small fields")
                        Text("Search boxes and single-line fields, which Tabber normally skips.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // Writes explicit values so the entry stays in the list even when they match the defaults.
    private func bool(_ keyPath: WritableKeyPath<AppOverride, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding {
            store.override(for: key)[keyPath: keyPath] ?? value
        } set: {
            store.settings.overrides[key, default: AppOverride()][keyPath: keyPath] = $0
        }
    }

    /// Snaps to `step` without the tick marks a stepped Slider draws.
    private func number(_ keyPath: WritableKeyPath<AppOverride, Double?>, default value: Double, step: Double) -> Binding<Double> {
        Binding {
            store.override(for: key)[keyPath: keyPath] ?? value
        } set: {
            store.settings.overrides[key, default: AppOverride()][keyPath: keyPath] = ($0 / step).rounded() * step
        }
    }

    private func text(_ keyPath: WritableKeyPath<AppOverride, String?>) -> Binding<String> {
        Binding {
            store.override(for: key)[keyPath: keyPath] ?? ""
        } set: {
            store.settings.overrides[key, default: AppOverride()][keyPath: keyPath] = $0.isEmpty ? nil : $0
        }
    }

    private var insertion: Binding<InsertionMethod?> {
        Binding {
            store.override(for: key).insertion
        } set: {
            store.settings.overrides[key, default: AppOverride()].insertion = $0
        }
    }
}

private struct AddWebsiteSheet: View {
    let suggestion: String?
    let add: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Website")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Domain", text: $domain, prompt: Text("mail.google.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Text("Use *.example.com for every subdomain, or example.* for any ending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalized == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { domain = suggestion ?? "" }
    }

    /// Accepts pasted URLs: drops the scheme, path and port.
    private var normalized: String? {
        var value = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.*")
        guard value.contains("."), value.unicodeScalars.allSatisfy(allowed.contains), !value.hasPrefix("."), !value.hasSuffix(".") else { return nil }
        return value
    }

    private func submit() {
        guard let normalized else { return }
        add(normalized)
        dismiss()
    }
}
