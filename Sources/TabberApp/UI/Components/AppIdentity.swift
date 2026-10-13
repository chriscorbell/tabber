import AppKit
import SwiftUI

/// Name and icon for an installed app, looked up by bundle identifier.
@MainActor
enum InstalledApp {
    private static var nameCache: [String: String] = [:]
    private static var iconCache: [String: NSImage] = [:]

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String {
        if let cached = nameCache[bundleID] { return cached }
        var name = bundleID
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            name = running
        } else if let url = url(for: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        }
        nameCache[bundleID] = name
        return name
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = url(for: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    private static let commonTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "co", "ai", "me", "edu", "gov", "us", "uk", "de", "fr", "jp", "ca", "au",
    ]

    /// Override keys are bundle identifiers (reverse DNS: `com.apple.Mail`) or domains (`mail.google.com`).
    static func isWebsite(_ key: String) -> Bool {
        if key.contains("*") { return true }
        if url(for: key) != nil { return false }
        let parts = key.split(separator: ".").map(String.init)
        guard let first = parts.first, let last = parts.last, parts.count >= 2 else { return false }
        if commonTLDs.contains(last.lowercased()), !key.contains(where: \.isUppercase) { return true }
        return !commonTLDs.contains(first.lowercased())
    }
}

/// An app's icon, or a globe for websites.
struct AppIconView: View {
    let key: String
    let isWebsite: Bool
    var size: CGFloat = 20

    var body: some View {
        if !isWebsite, let icon = InstalledApp.icon(for: key) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Icon(isWebsite ? .globe : .appWindow, size: size * 0.72)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
