import Carbon.HIToolbox
import CoreGraphics
import CoreText
import Foundation
import TabberCore

/// What one capture did, for probes and diagnostics.
public struct ScreenCaptureReport: Sendable {
    public var windowID: UInt32
    /// The captured window, in global Quartz points.
    public var windowFrame: CGRect
    /// The part of the window that was read, in global Quartz points.
    public var region: CGRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Window lookup plus ScreenCaptureKit capture.
    public var captureDuration: TimeInterval
    public var recognitionDuration: TimeInterval
    /// Everything the recognizer returned, before cleaning, with boxes in window-local points.
    public var recognizedLines: [RecognizedLine]
    /// The assembled, redacted text (empty when nothing useful was found).
    public var text: String
}

/// Text recognized on screen around the focused field, mostly above it: the email being replied to, the chat
/// being answered, the page being written about.
///
/// It captures only the focused field's window (never the whole screen, never other apps' windows, never Tabber's
/// own overlay), crops to the area around the field, runs on-device text recognition and keeps nothing but the
/// resulting text. Screenshots are never stored.
///
/// Calls never wait for a capture. The first call for a field starts one in the background and returns nil (or
/// waits at most `coldWait`); later calls return the cached text immediately. While the user stays in one field
/// the text is held stable (see `ScreenTextStability`), because it is part of the prompt preamble the engine
/// keeps in its KV cache.
public final class ScreenContextProvider: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Character budget for the returned text. Matches `PromptBuilder.Limits.screenTextChars`.
        public var characterBudget = 1800
        public var minimumConfidence: Float = 0.4
        /// Keep the text in use for at least this long unless the window's content clearly changed.
        public var minimumHold: TimeInterval = 20
        /// Below this word-set similarity a fresh capture replaces the text at once.
        public var changeThreshold: Double = 0.7
        /// After `minimumHold`, a smaller change replaces the text only if it brings this many new words.
        public var minimumNewWords = 4
        /// Minimum spacing of background re-captures for one field. Doubles while nothing changes.
        public var recaptureInterval: TimeInterval = 4
        public var maxRecaptureInterval: TimeInterval = 8
        /// A field not asked about for this long starts over: its old text is dropped instead of being served stale.
        public var sessionTimeout: TimeInterval = 60
        /// How long the first call for a field may wait for its first capture. Zero returns at once.
        public var coldWait: TimeInterval = 0
        /// Points above the field to read.
        public var heightAbove: CGFloat = 900
        /// Points below the field to read (skipped for tall fields).
        public var heightBelow: CGFloat = 120
        public var maxPixelWidth = 2000
        /// Recognized lines shorter than this many points are dropped.
        public var minimumTextHeight: CGFloat = 6
        public var redactSecrets = true
        /// Apps never captured. Defaults to common password managers.
        public var excludedBundleIDs: Set<String> = ScreenContextProvider.defaultExcludedBundleIDs
        public var maxCachedFields = 12

        public init() {}
    }

    public static let defaultExcludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword4",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.Dashlane",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop",
    ]

    public let configuration: Configuration

    private struct Key: Hashable {
        var field: FieldIdentity
    }

    private struct Entry {
        /// Text in use; nil until the first capture lands. Empty when the capture found nothing.
        var text: String?
        var adoptedAt = Date.distantPast
        var schedule: CaptureSchedule
        var inFlight = false
        var lastUsed: Date
        var windowTitle: String?
        var windowID: CGWindowID?
        /// Captures started at or after this time replace the text whenever it differs (the title changed, so
        /// the content probably did too).
        var forceAdoptAfter: Date?
        var generation: Int
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var generation = 0
    private var inFlightTasks: [Key: Task<Void, Never>] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Permission

    /// Whether Screen Recording is granted. Never shows a prompt.
    public static var isPermitted: Bool { PermissionCache.shared.screenCapture }

    /// Shows the system Screen Recording prompt (once per app; afterwards the user must use System Settings).
    /// Returns the current grant.
    @discardableResult
    public static func requestPermission() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        PermissionCache.shared.invalidate()
        return granted
    }

    // MARK: - Public API

    /// Recognized text near the field (mostly above it), or nil when there is none yet, capture isn't allowed for
    /// this field, or Screen Recording isn't granted.
    public func screenText(for snapshot: FieldSnapshot) async -> String? {
        guard isEligible(snapshot) else { return nil }
        let (cached, task) = touch(snapshot, now: Date())
        if cached == nil, let task, configuration.coldWait > 0 {
            await Self.wait(for: task, upTo: configuration.coldWait)
            return lock.withLock { entries[Key(field: snapshot.field)]?.text }.flatMap(Self.nonEmpty)
        }
        return cached.flatMap(Self.nonEmpty)
    }

    /// Starts a capture for the field if one is due, without waiting. Call on focus changes so the first
    /// completion already has screen text.
    public func prefetch(for snapshot: FieldSnapshot) {
        guard isEligible(snapshot) else { return }
        _ = touch(snapshot, now: Date())
    }

    /// Prepares the text recognizer so the first real capture is fast. Call once at launch, in the background.
    ///
    /// The first recognition by each build of an app, on each OS build, compiles Vision's models into the app's
    /// caches folder (`~/Library/Caches/<app>/com.apple.e5rt.e5bundlecache`). That took 25 to 80 seconds in testing;
    /// afterwards a fresh process recognizes a capture in about 0.3 s. Captures never block callers either way, but
    /// until the compile finishes there is no screen text. Recognizes a rendered page of sample text, so detection,
    /// recognition and language correction all get compiled.
    public static func warmUp() async {
        guard let image = sampleTextImage() else { return }
        let size = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        _ = try? await TextRecognizer.recognize(image, region: size)
    }

    /// A page of several text lines. A single short line loads only part of the models; a page loads all of them.
    private static func sampleTextImage() -> CGImage? {
        let width = 1600, height = 900
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
        let sample = "Thanks for the update, I'll send the revised plan by Friday at 3:30 (about 42% done)."
        guard let text = CFAttributedStringCreate(nil, sample as CFString, attributes) else { return nil }
        let line = CTLineCreateWithAttributedString(text)
        var y = height - 80
        while y > 40 {
            context.textPosition = CGPoint(x: 40, y: CGFloat(y))
            CTLineDraw(line, context)
            y -= 70
        }
        return context.makeImage()
    }

    /// Forgets all cached text.
    public func reset() {
        lock.withLock {
            entries.removeAll()
            inFlightTasks.removeAll()
            generation += 1
        }
    }

    /// Captures and recognizes right now, bypassing and not touching the cache. For probes and diagnostics.
    public func captureNow(for snapshot: FieldSnapshot) async -> ScreenCaptureReport? {
        guard isEligible(snapshot) else { return nil }
        return try? await capture(snapshot)
    }

    /// Whether this field may be captured at all.
    public func isEligible(_ snapshot: FieldSnapshot) -> Bool {
        guard !snapshot.isSecure,
              !configuration.excludedBundleIDs.contains(snapshot.app.bundleID),
              snapshot.app.pid != ProcessInfo.processInfo.processIdentifier,
              snapshot.fieldFrame != nil || snapshot.caret != nil,
              !IsSecureEventInputEnabled(),
              Self.isPermitted
        else { return false }
        return true
    }

    // MARK: - Cache and scheduling

    /// Records use of the field, starts a background capture when one is due, and returns the cached text.
    private func touch(_ snapshot: FieldSnapshot, now: Date) -> (String?, Task<Void, Never>?) {
        let key = Key(field: snapshot.field)
        let frame = snapshot.fieldFrame ?? snapshot.caret?.rect
        return lock.withLock {
            var entry = entries[key] ?? Entry(
                schedule: CaptureSchedule(
                    baseInterval: configuration.recaptureInterval,
                    maxInterval: configuration.maxRecaptureInterval
                ),
                lastUsed: now,
                windowTitle: snapshot.windowTitle,
                generation: generation
            )
            if now.timeIntervalSince(entry.lastUsed) > configuration.sessionTimeout {
                // A new visit to an old field: don't serve what was on screen minutes ago.
                entry.text = nil
                entry.schedule = CaptureSchedule(
                    baseInterval: configuration.recaptureInterval,
                    maxInterval: configuration.maxRecaptureInterval
                )
            }
            if entry.windowTitle != snapshot.windowTitle {
                // Same field, new document or conversation (most apps title windows after it). Keep serving the
                // old text until the new capture lands, then adopt the new text even if it is similar.
                entry.windowTitle = snapshot.windowTitle
                entry.schedule = CaptureSchedule(
                    baseInterval: configuration.recaptureInterval,
                    maxInterval: configuration.maxRecaptureInterval
                )
                entry.forceAdoptAfter = now
            }
            entry.lastUsed = now

            var task: Task<Void, Never>?
            if !entry.inFlight, entry.schedule.isDue(now: now, frame: frame) {
                entry.inFlight = true
                entry.schedule.started(now: now, frame: frame)
                let started = now
                let gen = entry.generation
                let t = Task<Void, Never>.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    await self.refresh(key: key, snapshot: snapshot, started: started, generation: gen)
                }
                inFlightTasks[key] = t
                task = t
            } else {
                task = inFlightTasks[key]
            }
            entries[key] = entry
            evict(keeping: key)
            return (entry.text, task)
        }
    }

    private func refresh(key: Key, snapshot: FieldSnapshot, started: Date, generation gen: Int) async {
        let report = try? await capture(snapshot)
        let now = Date()
        let stability = ScreenTextStability(
            minimumHold: configuration.minimumHold,
            changeThreshold: configuration.changeThreshold,
            minimumNewWords: configuration.minimumNewWords
        )
        lock.withLock {
            guard var entry = entries[key], entry.generation == gen else { return }
            inFlightTasks[key] = nil
            entry.inFlight = false
            var changed = false
            if let report {
                let windowChanged = entry.windowID != nil && entry.windowID != report.windowID
                let forced = windowChanged || (entry.forceAdoptAfter.map { started >= $0 } ?? false)
                let replace = forced
                    ? entry.text != report.text
                    : stability.shouldReplace(
                        current: entry.text,
                        age: now.timeIntervalSince(entry.adoptedAt),
                        with: report.text
                    )
                if forced { entry.forceAdoptAfter = nil }
                if replace {
                    entry.text = report.text
                    entry.adoptedAt = now
                    changed = true
                }
                entry.windowID = report.windowID
            }
            entry.schedule.finished(changed: changed)
            entries[key] = entry
        }
    }

    private func evict(keeping key: Key) {
        guard entries.count > configuration.maxCachedFields else { return }
        let victims = entries
            .filter { $0.key != key && !$0.value.inFlight }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
            .prefix(entries.count - configuration.maxCachedFields)
        for (k, _) in victims { entries[k] = nil }
    }

    private static func wait(for task: Task<Void, Never>, upTo seconds: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    // MARK: - Capture

    private func capture(_ snapshot: FieldSnapshot) async throws -> ScreenCaptureReport {
        guard let field = snapshot.fieldFrame ?? snapshot.caret?.rect else { throw CaptureError.nothingToRead }
        let point: CGPoint = snapshot.caret.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
            ?? CGPoint(x: field.midX, y: field.midY)

        let t0 = Date()
        guard let window = WindowLocator.window(pid: snapshot.app.pid, field: field, point: point) else {
            throw CaptureError.noWindow
        }
        var options = CaptureRegion.Options()
        options.heightAbove = configuration.heightAbove
        options.heightBelow = configuration.heightBelow
        options.maxPixelWidth = configuration.maxPixelWidth
        let shot = try await WindowCapturer.capture(window, field: field, options: options)
        let t1 = Date()

        let lines = try await TextRecognizer.recognize(shot.image, region: shot.region.rect)
        let t2 = Date()

        var assembly = ScreenTextAssembler.Options()
        assembly.minimumConfidence = configuration.minimumConfidence
        assembly.characterBudget = configuration.characterBudget
        assembly.minimumLineHeight = configuration.minimumTextHeight
        let localField = field.offsetBy(dx: -shot.window.frame.minX, dy: -shot.window.frame.minY)
        var text = ScreenTextAssembler.assemble(
            lines,
            field: localField,
            fieldText: snapshot.textBeforeCaret + " " + snapshot.textAfterCaret,
            alsoKnown: [snapshot.windowTitle, snapshot.url?.absoluteString].compactMap { $0 },
            options: assembly
        )
        if configuration.redactSecrets { text = SecretRedactor.redact(text) }

        return ScreenCaptureReport(
            windowID: shot.window.id,
            windowFrame: shot.window.frame,
            region: shot.region.rect.offsetBy(dx: shot.window.frame.minX, dy: shot.window.frame.minY),
            pixelWidth: shot.image.width,
            pixelHeight: shot.image.height,
            captureDuration: t1.timeIntervalSince(t0),
            recognitionDuration: t2.timeIntervalSince(t1),
            recognizedLines: lines,
            text: text
        )
    }
}

/// `CGPreflightScreenCaptureAccess` is an IPC round trip and is checked on every call, possibly from the main
/// thread. The first check is synchronous; after that the cached answer is returned at once and refreshed in the
/// background every couple of seconds.
private final class PermissionCache: @unchecked Sendable {
    static let shared = PermissionCache()
    private let lock = NSLock()
    private var value: Bool?
    private var checkedAt = Date.distantPast
    private var refreshing = false

    var screenCapture: Bool {
        let (cached, stale) = lock.withLock { () -> (Bool?, Bool) in
            let stale = Date().timeIntervalSince(checkedAt) > 2 && !refreshing
            if stale, value != nil { refreshing = true }
            return (value, stale)
        }
        guard let cached else {
            let granted = CGPreflightScreenCaptureAccess()
            lock.withLock { value = granted; checkedAt = Date() }
            return granted
        }
        if stale {
            DispatchQueue.global(qos: .utility).async { [self] in
                let granted = CGPreflightScreenCaptureAccess()
                lock.withLock { value = granted; checkedAt = Date(); refreshing = false }
            }
        }
        return cached
    }

    func invalidate() {
        lock.withLock { value = nil; checkedAt = .distantPast }
    }
}
