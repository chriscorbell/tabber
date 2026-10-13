import Foundation
import SwiftUI
import TabberCore

/// Lists the model catalog, tracks which models are on disk, downloads and deletes them, and resolves
/// the model the engine should load.
///
/// Any other `*.gguf` file the user puts in `modelsDirectory` shows up as a custom model with the id
/// `custom:<file name>`.
@MainActor
public final class ModelManager: ObservableObject {
    public struct Model: Identifiable, Equatable, Sendable {
        public struct License: Equatable, Sendable {
            public let name: String
            public let url: URL
            /// Shown next to the model where its terms ask for it. Markdown, may contain a link.
            public let notice: String?
        }

        public let id: String
        public let displayName: String
        /// One word users can compare: Tiny, Fast, Balanced, Quality, Best.
        public let tier: String
        public let summary: String
        public let family: String
        public let fileName: String
        /// Hugging Face `resolve` URL.
        public let url: URL
        public let sizeBytes: Int64
        public let minRAMGB: Int
        public let notes: String?
        public let license: License

        public var licenseNotice: LocalizedStringKey? { license.notice.map { LocalizedStringKey($0) } }
    }

    public static let customPrefix = "custom:"

    @Published public private(set) var catalog: [Model] = Model.catalog
    /// Ids of catalog models with a complete file on disk.
    @Published public private(set) var installed: Set<String> = []
    /// Download progress, 0...1, for models being downloaded.
    @Published public private(set) var downloads: [String: Double] = [:]
    /// File names of other `.gguf` files in the models folder.
    @Published public private(set) var customModels: [String] = []
    /// The last download error per model, for display.
    @Published public private(set) var downloadErrors: [String: String] = [:]
    /// Models with a stopped download that `download` can resume.
    @Published public private(set) var resumable: Set<String> = []

    /// `~/Library/Application Support/Tabber/Models`
    public let modelsDirectory: URL

    private let settings: SettingsStore
    private let resumeDirectory: URL
    private let io = DispatchQueue(label: "app.tabber.models", qos: .utility)
    private let downloader = ModelDownloader()
    private var watcher: DispatchSourceFileSystemObject?
    private var rescanPending = false
    /// Models whose current download resumed from saved data; a failure restarts them from scratch once.
    private var resumedDownloads: Set<String> = []

    public nonisolated static var defaultModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabber/Models", isDirectory: true)
    }

    public nonisolated static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    public init(settings: SettingsStore, modelsDirectory: URL = ModelManager.defaultModelsDirectory) {
        self.settings = settings
        self.modelsDirectory = modelsDirectory
        resumeDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabber/Downloads", isDirectory: true)

        let fm = FileManager.default
        try? fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)

        // One small directory listing at launch, so the selected model is known before the engine starts.
        apply(Self.scan(modelsDirectory, catalog: catalog))
        resumable = Set(catalog.map(\.id).filter { fm.fileExists(atPath: resumeDirectory.appendingPathComponent("\($0).resume").path) })
        downloader.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        watchDirectory()
    }

    // MARK: - Selection

    /// The catalog model recommended for this Mac, by physical memory.
    public func recommendedModelID() -> String {
        Self.physicalMemoryGB >= 15.5 ? "gemma-4-e2b" : "qwen3-1.7b-base"
    }

    /// The model the engine should load: the user's choice if it's on disk, else the recommended model,
    /// else the best other installed model that fits in memory, else a custom model.
    public var selectedModelID: String? {
        if let chosen = settings.settings.modelID, isAvailable(chosen) { return chosen }
        let recommended = recommendedModelID()
        if installed.contains(recommended) { return recommended }
        let ram = Self.physicalMemoryGB + 0.5
        let fitting = catalog
            .filter { installed.contains($0.id) && Double($0.minRAMGB) <= ram }
            .max { $0.sizeBytes < $1.sizeBytes }
        if let fitting { return fitting.id }
        if let any = catalog.first(where: { installed.contains($0.id) }) { return any.id }
        return customModels.first.map { Self.customPrefix + $0 }
    }

    public var selectedModelPath: URL? {
        selectedModelID.flatMap(path(for:))
    }

    /// The file of an installed catalog model or a custom model.
    public func path(for id: String) -> URL? {
        if let file = Self.customFileName(id) {
            return customModels.contains(file) ? modelsDirectory.appendingPathComponent(file) : nil
        }
        guard installed.contains(id), let model = model(id) else { return nil }
        return modelsDirectory.appendingPathComponent(model.fileName)
    }

    public func isAvailable(_ id: String) -> Bool {
        path(for: id) != nil
    }

    public func model(_ id: String) -> Model? {
        catalog.first { $0.id == id }
    }

    public func displayName(for id: String) -> String {
        if let file = Self.customFileName(id) {
            return (file as NSString).deletingPathExtension
        }
        return model(id)?.displayName ?? id
    }

    public func select(_ id: String) {
        settings.settings.modelID = id
    }

    static func customFileName(_ id: String) -> String? {
        id.hasPrefix(customPrefix) ? String(id.dropFirst(customPrefix.count)) : nil
    }

    // MARK: - Downloads

    /// Whether the models volume has room for the model plus some headroom.
    public func hasEnoughSpace(for model: Model) -> Bool {
        guard let free = try? modelsDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        else { return true }
        return free > model.sizeBytes + 512 * 1_048_576
    }

    /// Starts or resumes a download. Progress appears in `downloads`; the file is validated and moved
    /// into the models folder when complete.
    public func download(_ id: String) {
        guard let model = model(id), !installed.contains(id), downloads[id] == nil else { return }
        guard hasEnoughSpace(for: model) else {
            downloadErrors[id] = "Not enough free disk space. \(Self.formatBytes(model.sizeBytes)) needed."
            return
        }
        downloadErrors[id] = nil
        downloads[id] = 0
        resumable.remove(id)
        let resumeURL = resumeDataURL(id)
        let resumeData = try? Data(contentsOf: resumeURL)
        if resumeData != nil { resumedDownloads.insert(id) } else { resumedDownloads.remove(id) }
        downloader.start(.init(
            id: id,
            url: model.url,
            expectedSize: model.sizeBytes,
            destination: modelsDirectory.appendingPathComponent(model.fileName)
        ), resumeData: resumeData)
    }

    /// Stops a download, keeping what was downloaded so `download` can resume it.
    public func cancelDownload(_ id: String) {
        downloader.cancel(id, keepResumeData: true)
        downloads[id] = nil
    }

    /// Deletes a model's file, or stops its download and discards the partial data.
    public func delete(_ id: String) {
        downloader.cancel(id, keepResumeData: false)
        downloads[id] = nil
        downloadErrors[id] = nil
        resumable.remove(id)
        let resume = resumeDataURL(id)
        let file: URL? = path(for: id)
        if settings.settings.modelID == id { settings.settings.modelID = nil }
        io.async { [weak self] in
            if let file { try? FileManager.default.removeItem(at: file) }
            Self.discardResumeData(at: resume)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.rescan() } }
        }
    }

    /// Removes saved resume data and the partial file it points at.
    private nonisolated static func discardResumeData(at url: URL) {
        if let data = try? Data(contentsOf: url), let file = partialFile(inResumeData: data) {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// The temporary file a URLSession resume blob refers to. The blob is a property list, either a
    /// plain dictionary or a keyed archive whose strings sit in `$objects`.
    nonisolated static func partialFile(inResumeData data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        if let path = plist["NSURLSessionResumeInfoLocalPath"] as? String { return URL(fileURLWithPath: path) }
        if let name = plist["NSURLSessionResumeInfoTempFileName"] as? String { return temp.appendingPathComponent(name) }
        let strings = (plist["$objects"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let name = strings.first(where: { $0.hasPrefix("CFNetworkDownload_") && $0.hasSuffix(".tmp") && !$0.contains("/") }) else { return nil }
        return temp.appendingPathComponent(name)
    }

    private func handle(_ event: ModelDownloader.Event) {
        switch event {
        case let .progress(id, fraction):
            if downloads[id] != nil { downloads[id] = fraction }
        case let .resumeData(id, data):
            let url = resumeDataURL(id)
            if downloads[id] == nil { resumable.insert(id) }
            io.async { try? data.write(to: url, options: .atomic) }
        case let .finished(id, outcome):
            downloads[id] = nil
            switch outcome {
            case .completed:
                resumable.remove(id)
                let url = resumeDataURL(id)
                io.async { try? FileManager.default.removeItem(at: url) }
                rescan()
            case .cancelled:
                break
            case let .failed(message):
                if resumedDownloads.remove(id) != nil {
                    // Saved data can go stale (temporary file purged); start over once.
                    let url = resumeDataURL(id)
                    try? FileManager.default.removeItem(at: url)
                    download(id)
                } else {
                    downloadErrors[id] = message
                }
            }
        }
    }

    private func resumeDataURL(_ id: String) -> URL {
        resumeDirectory.appendingPathComponent("\(id).resume")
    }

    // MARK: - Scanning the folder

    private struct ScanResult: Equatable {
        var installed: Set<String>
        var custom: [String]
    }

    private nonisolated static func scan(_ directory: URL, catalog: [Model]) -> ScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var installed = Set<String>()
        var custom: [String] = []
        let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.fileName.lowercased(), $0) })
        for file in files where file.pathExtension.lowercased() == "gguf" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let name = file.lastPathComponent
            if let model = byName[name.lowercased()] {
                if Int64(values.fileSize ?? 0) == model.sizeBytes { installed.insert(model.id) }
            } else {
                custom.append(name)
            }
        }
        custom.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return ScanResult(installed: installed, custom: custom)
    }

    private func apply(_ result: ScanResult) {
        if installed != result.installed { installed = result.installed }
        if customModels != result.custom { customModels = result.custom }
    }

    /// Re-reads the models folder off the main thread.
    public func rescan() {
        let directory = modelsDirectory
        let catalog = catalog
        io.async { [weak self] in
            let result = Self.scan(directory, catalog: catalog)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(result) } }
        }
    }

    private func watchDirectory() {
        let fd = open(modelsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: io)
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleRescan() } }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleRescan() {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.rescanPending = false
                self?.rescan()
            }
        }
    }

    // MARK: - Formatting

    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
