import Combine
import Foundation
import TabberCore

/// Owns `TabberSettings` and persists it as JSON in UserDefaults. Changes are saved shortly after
/// they happen, and on `flush()`.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()
    public static let defaultsKey = "settings.v1"

    @Published public var settings: TabberSettings

    private let defaults: UserDefaults
    private var saveSubscription: AnyCancellable?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = Self.load(from: defaults)
        saveSubscription = $settings
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.write($0) }
    }

    /// Writes the current settings immediately.
    public func flush() {
        write(settings)
    }

    private func write(_ value: TabberSettings) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Decodes stored settings. Keys that no longer decode (renamed or retyped fields) fall back to
    /// their defaults instead of resetting everything, and new fields get their defaults.
    static func load(from defaults: UserDefaults) -> TabberSettings {
        guard let data = defaults.data(forKey: defaultsKey) else { return TabberSettings() }
        let decoder = JSONDecoder()
        if let settings = try? decoder.decode(TabberSettings.self, from: data) { return settings }

        guard
            let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let baseData = try? JSONEncoder().encode(TabberSettings()),
            var merged = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any]
        else { return TabberSettings() }

        func decodes(_ object: [String: Any]) -> TabberSettings? {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? decoder.decode(TabberSettings.self, from: data)
        }

        for (key, value) in stored {
            var candidate = merged
            candidate[key] = value
            if decodes(candidate) != nil { merged = candidate }
        }
        return decodes(merged) ?? TabberSettings()
    }
}

// MARK: - Per-app and per-website overrides

extension SettingsStore {
    /// Apps where Tabber stays off unless the user enables it: terminals and code editors, where Tab
    /// already means something and prose suggestions rarely help.
    public static let defaultDisabledBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.jetbrains.CLion",
        "com.jetbrains.rider",
        "com.google.android.studio",
        "com.1password.1password",
        "com.apple.keychainaccess",
        // Fields here are names, searches and commands, not prose.
        "com.apple.finder",
        "com.apple.iCal",
        "com.apple.Preview",
        "com.apple.systempreferences",
        "com.figma.Desktop",
        "com.runningwithcrayons.Alfred",
    ]

    /// Websites where Tabber stays off unless the user enables them: web search and design tools.
    /// "google.*" is google.com, google.de… only; Gmail and Docs (mail.google.com, docs.google.com) stay on.
    public static let defaultDisabledDomains: [String] = ["google.*", "bing.com", "duckduckgo.com", "kagi.com", "figma.com"]

    static func isDisabledByDefault(domain: String) -> Bool {
        let d = domain.lowercased()
        return defaultDisabledDomains.contains { pattern in
            pattern.hasSuffix(".*") ? d.hasPrefix(String(pattern.dropLast())) : (d == pattern || d.hasSuffix("." + pattern))
        }
    }

    public func override(for key: String) -> AppOverride {
        settings.overrides[key] ?? AppOverride()
    }

    /// Edits the override stored under a bundle identifier or domain, dropping it once it's empty.
    public func updateOverride(_ key: String, _ body: (inout AppOverride) -> Void) {
        var value = settings.overrides[key] ?? AppOverride()
        body(&value)
        settings.overrides[key] = value.isEmpty ? nil : value
    }

    /// Adds an empty entry so the app or website shows up in the Apps list.
    /// Stored as an explicit `enabled` value because empty overrides aren't persisted.
    public func addOverride(_ key: String) {
        guard settings.overrides[key] == nil else { return }
        var value = AppOverride()
        value.enabled = Self.defaultDisabledBundleIDs.contains(key) ? false : true
        settings.overrides[key] = value
    }

    public func removeOverride(_ key: String) {
        settings.overrides[key] = nil
    }

    /// Whether suggestions are on for an app (and website, when given), before temporary pauses.
    public func isEnabled(bundleID: String, domain: String?) -> Bool {
        guard settings.enabled else { return false }
        let merged = settings.override(bundleID: bundleID, domain: domain)
        if let enabled = merged.enabled { return enabled }
        if let domain, Self.isDisabledByDefault(domain: domain) { return false }
        return !Self.defaultDisabledBundleIDs.contains(bundleID)
    }

    public func isAppEnabled(_ bundleID: String) -> Bool {
        override(for: bundleID).enabled ?? !Self.defaultDisabledBundleIDs.contains(bundleID)
    }

    public func setAppEnabled(_ bundleID: String, _ enabled: Bool) {
        let byDefault = !Self.defaultDisabledBundleIDs.contains(bundleID)
        updateOverride(bundleID) { $0.enabled = enabled == byDefault ? nil : enabled }
    }

    /// Whether a domain's own override turns suggestions off (or on).
    public func domainEnabled(_ domain: String) -> Bool? {
        TabberSettings.matchDomain(domain, in: settings.overrides)?.enabled
    }

    public func setDomainEnabled(_ domain: String, _ enabled: Bool) {
        guard enabled else {
            updateOverride(domain) { $0.enabled = false }
            return
        }
        updateOverride(domain) { $0.enabled = nil }
        // A wildcard entry may still turn it off; an exact entry wins over wildcards.
        if domainEnabled(domain) == false {
            updateOverride(domain) { $0.enabled = true }
        }
    }

    public func tabAccepts(in bundleID: String) -> Bool {
        override(for: bundleID).tabAccepts ?? true
    }

    public func setTabAccepts(_ bundleID: String, _ accepts: Bool) {
        updateOverride(bundleID) { $0.tabAccepts = accepts ? nil : false }
    }
}
