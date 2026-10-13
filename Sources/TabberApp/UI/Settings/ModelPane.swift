import AppKit
import SwiftUI

struct ModelPane: View {
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appActions) private var actions
    @State private var confirmingDelete: String?

    var body: some View {
        Form {
            Section {
                EngineStatusRow()
            }

            Section {
                ForEach(models.catalog) { model in
                    CatalogModelRow(model: model, selected: selectedID == model.id, confirmDelete: { confirmingDelete = model.id })
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Larger models write better suggestions but use more memory and battery. All run on this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                ForEach(models.customModels, id: \.self) { file in
                    CustomModelRow(file: file, selected: selectedID == ModelManager.customPrefix + file, confirmDelete: { confirmingDelete = ModelManager.customPrefix + file })
                }
                HStack {
                    Text(models.customModels.isEmpty ? "Put any .gguf base model in the models folder to use it here." : "Base models work best. Chat-tuned models tend to answer instead of continuing your text.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([models.modelsDirectory])
                    }
                }
            } header: {
                Text("Your models")
            }
        }
        .formStyle(.grouped)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: models.downloads.keys.sorted())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: models.installed)
        .confirmationDialog(
            "Delete \(confirmingDelete.map(models.displayName(for:)) ?? "this model")?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            presenting: confirmingDelete
        ) { id in
            Button("Delete", role: .destructive) { models.delete(id) }
        } message: { id in
            if models.resumable.contains(id) {
                Text("The partly downloaded file is removed.")
            } else if let model = models.model(id) {
                Text("This frees \(ModelManager.formatBytes(model.sizeBytes)). You can download it again later.")
            } else {
                Text("The file is removed from the models folder.")
            }
        }
    }

    private var selectedID: String? { models.selectedModelID }
}

private struct EngineStatusRow: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.appActions) private var actions

    var body: some View {
        LabeledContent {
            switch state.engineStatus {
            case .failed:
                Button("Try Again", action: actions.reloadEngine)
            case .loading:
                ProgressView().controlSize(.small)
            default:
                if let latency = state.lastLatencyMs {
                    Text("Last suggestion in \(Int(latency.rounded())) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
            }
            if case let .failed(message) = state.engineStatus {
                Text(message)
            }
        }
    }

    private var title: String {
        switch state.engineStatus {
        case .noModel: "No model loaded"
        case let .loading(name): "Loading \(name)…"
        case let .ready(name): "\(name) is ready"
        case .failed: "The model couldn't load"
        }
    }

    private var color: Color {
        switch state.engineStatus {
        case .noModel: .secondary
        case .loading: .orange
        case .ready: .green
        case .failed: .red
        }
    }
}

private struct CatalogModelRow: View {
    let model: ModelManager.Model
    let selected: Bool
    let confirmDelete: () -> Void

    @EnvironmentObject private var models: ModelManager

    private var installed: Bool { models.installed.contains(model.id) }
    private var progress: Double? { models.downloads[model.id] }
    private var recommended: Bool { models.recommendedModelID() == model.id }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SelectionMark(selected: selected, available: installed) {
                models.select(model.id)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .fontWeight(.medium)
                    Text(model.tier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                }
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let progress {
                    DownloadProgress(progress: progress, total: model.sizeBytes)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let error = models.downloadErrors[model.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let notice = model.licenseNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if installed { models.select(model.id) } }
    }

    @ViewBuilder
    private var trailing: some View {
        if progress != nil {
            Button("Stop") { models.cancelDownload(model.id) }
        } else if installed {
            HStack(spacing: 10) {
                Text(ModelManager.formatBytes(model.sizeBytes))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button(action: confirmDelete) {
                    Icon(.trash2, size: 14)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete \(model.displayName)")
                .accessibilityLabel("Delete \(model.displayName)")
            }
        } else if models.resumable.contains(model.id) {
            HStack(spacing: 10) {
                Button("Resume") { models.download(model.id) }
                Button(action: confirmDelete) {
                    Icon(.trash2, size: 14)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Discard the partial download")
                .accessibilityLabel("Discard the partial download")
            }
        } else {
            Button {
                models.download(model.id)
            } label: {
                Text("Download \(ModelManager.formatBytes(model.sizeBytes))")
                    .monospacedDigit()
            }
        }
    }
}

private struct CustomModelRow: View {
    let file: String
    let selected: Bool
    let confirmDelete: () -> Void

    @EnvironmentObject private var models: ModelManager

    var body: some View {
        HStack(spacing: 10) {
            SelectionMark(selected: selected, available: true) {
                models.select(ModelManager.customPrefix + file)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text((file as NSString).deletingPathExtension)
                    .fontWeight(.medium)
                Text(file)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: confirmDelete) {
                Icon(.trash2, size: 14)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete")
            .accessibilityLabel("Delete \(file)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { models.select(ModelManager.customPrefix + file) }
    }
}

/// A radio-style mark: filled when selected, empty when installed, hidden when not on disk.
private struct SelectionMark: View {
    let selected: Bool
    let available: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(available ? 0.25 : 0.1), lineWidth: 1)
                Circle()
                    .fill(Color.accentColor)
                    .scaleEffect(selected ? 1 : 0.01)
                    .opacity(selected ? 1 : 0)
                Icon(.check, size: 10, weight: 3.2)
                    .foregroundStyle(.white)
                    .opacity(selected ? 1 : 0)
            }
            .frame(width: 16, height: 16)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: selected)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(selected ? "Selected" : "Use this model")
    }
}

/// A slim bar with downloaded and total size.
struct DownloadProgress: View {
    let progress: Double
    let total: Int64
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * progress))
                        .animation(.easeOut(duration: 0.25), value: progress)
                }
            }
            .frame(height: 4)
            Text("\(ModelManager.formatBytes(Int64(Double(total) * progress))) of \(ModelManager.formatBytes(total))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}
