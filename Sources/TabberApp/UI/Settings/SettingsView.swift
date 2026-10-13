import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, context, personalization, apps, model, statistics, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .context: "Context"
        case .personalization: "Personalization"
        case .apps: "Apps & Websites"
        case .model: "Model"
        case .statistics: "Statistics"
        case .about: "About"
        }
    }

    var icon: LucideIcon {
        switch self {
        case .general: .slidersHorizontal
        case .shortcuts: .keyboard
        case .context: .scanText
        case .personalization: .fingerprint
        case .apps: .appWindow
        case .model: .cpu
        case .statistics: .chartColumn
        case .about: .info
        }
    }
}

/// Which pane is showing. Remembered across launches.
@MainActor
final class SettingsRouter: ObservableObject {
    private static let key = "settings.pane"

    @Published var pane: SettingsPane {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: Self.key) }
    }

    init() {
        pane = UserDefaults.standard.string(forKey: Self.key).flatMap(SettingsPane.init(rawValue:)) ?? .general
    }
}

/// The sidebar list of panes. Hosted in an AppKit split view so its width is under our control.
struct SettingsSidebar: View {
    @ObservedObject var router: SettingsRouter

    var body: some View {
        List(SettingsPane.allCases, selection: selection) { pane in
            Label {
                Text(pane.title)
            } icon: {
                Icon(pane.icon, size: 15, weight: 1.9)
            }
            .tag(pane)
            .padding(.vertical, 1)
        }
        .listStyle(.sidebar)
    }

    /// The list never deselects; clicking empty space keeps the current pane.
    private var selection: Binding<SettingsPane?> {
        Binding(get: { router.pane }, set: { if let pane = $0 { router.pane = pane } })
    }
}

struct SettingsDetail: View {
    @ObservedObject var router: SettingsRouter

    var body: some View {
        detail
            .id(router.pane)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.16), value: router.pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        switch router.pane {
        case .general: GeneralPane()
        case .shortcuts: ShortcutsPane()
        case .context: ContextPane()
        case .personalization: PersonalizationPane()
        case .apps: AppsPane()
        case .model: ModelPane()
        case .statistics: StatisticsPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Shared pieces

/// A row that shows a permission's state and a button to grant it.
struct PermissionRow: View {
    let title: String
    let caption: String?
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                HStack(spacing: 5) {
                    Icon(.circleCheck, size: 14)
                        .foregroundStyle(.green)
                    Text("Allowed")
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Button("Allow…", action: action)
                    .transition(.opacity)
            }
        } label: {
            Text(title)
            if let caption { Text(caption) }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: granted)
    }
}
