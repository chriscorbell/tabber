import ApplicationServices
import Foundation
import os

/// Chromium and Electron only build their full accessibility tree (including character bounds) while an assistive
/// client asks for it. Electron listens for `AXManualAccessibility`. Chromium browsers respond to
/// `AXEnhancedUserInterface` (what VoiceOver sets), which is only the fallback because it can slow window animations.
///
/// Other tools on the Mac switch these flags off again (on one test machine, every activation of Chrome cleared
/// `AXEnhancedUserInterface` within 50 ms), so the flag is re-checked after activation and whenever a read of a web
/// field can only estimate the caret. A check is one read while the flag is still on.
final class WebAccessibilityEnabler {
    enum Kind: Equatable {
        case electron
        case chromiumBrowser
        case other
    }

    /// Bundle ID prefixes of Chromium-based browsers (prefixes, so beta/canary/dev channels match too).
    static let chromiumBundlePrefixes = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
        "net.imput.helium",
        // Firefox and its forks aren't Chromium, but they also expose their content only when
        // AXEnhancedUserInterface is set, which is what this kind turns on.
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
    ]

    private struct ProcessState {
        var kind: Kind
        var element: AXUIElement
        /// Which flag worked for this process, once known.
        var flag: String?
        var lastCheck: TimeInterval = -.infinity
    }

    private let client: AXClient
    private var kindsByPath: [String: Kind] = [:]
    private var processes: [pid_t: ProcessState] = [:]
    private let log = Logger(subsystem: "app.tabber.Tabber", category: "ax")

    init(client: AXClient) {
        self.client = client
    }

    /// Pure classification, with the file system passed in so it can be tested.
    static func classify(bundleID: String?, bundlePath: String?, fileExists: (String) -> Bool) -> Kind {
        if let path = bundlePath {
            if fileExists(path + "/Contents/Frameworks/Electron Framework.framework") { return .electron }
        }
        if let id = bundleID, chromiumBundlePrefixes.contains(where: { id.hasPrefix($0) }) { return .chromiumBrowser }
        // Other Chromium forks ship "<App Name> Framework.framework" with the renderer helpers inside.
        if let path = bundlePath {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if fileExists(path + "/Contents/Frameworks/\(name) Framework.framework/Helpers") { return .chromiumBrowser }
        }
        return .other
    }

    /// Call on every activation. Returns the app's kind so the caller can schedule follow-up checks.
    @discardableResult
    func prepare(pid: pid_t, bundleID: String?, bundleURL: URL?, appElement: AXUIElement) -> Kind {
        let path = bundleURL?.path
        let kind: Kind
        if let path, let cached = kindsByPath[path] {
            kind = cached
        } else {
            kind = Self.classify(bundleID: bundleID, bundlePath: path) { FileManager.default.fileExists(atPath: $0) }
            if let path { kindsByPath[path] = kind }
        }
        guard kind != .other else { return kind }
        if processes[pid] == nil { processes[pid] = ProcessState(kind: kind, element: appElement) }
        ensureEnabled(pid: pid, minimumInterval: 0)
        return kind
    }

    func kind(of pid: pid_t) -> Kind {
        processes[pid]?.kind ?? .other
    }

    /// Turns the flag back on if it is off. Returns true when it had to.
    @discardableResult
    func ensureEnabled(pid: pid_t, minimumInterval: TimeInterval) -> Bool {
        guard var state = processes[pid] else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - state.lastCheck >= minimumInterval else { return false }
        state.lastCheck = now
        defer { processes[pid] = state }

        let candidates: [String]
        if let flag = state.flag {
            candidates = [flag]
        } else {
            candidates = state.kind == .electron
                ? [AXName.manualAccessibility]
                : [AXName.manualAccessibility, AXName.enhancedUserInterface]
        }
        for flag in candidates {
            if AXCast.bool(client.copy(state.element, flag)) == true {
                state.flag = flag
                return false
            }
            // Chrome reports an error from this setter even when it applies the value, so read it back.
            client.set(state.element, flag, kCFBooleanTrue)
            if AXCast.bool(client.copy(state.element, flag)) == true || state.kind == .electron {
                state.flag = flag
                log.debug("enabled \(flag, privacy: .public) for pid \(pid)")
                return true
            }
        }
        return false
    }

    func forget(pid: pid_t) {
        processes[pid] = nil
    }
}
