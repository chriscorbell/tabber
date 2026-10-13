import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os
import TabberCore

/// Types text at the caret of the focused app with synthetic events.
///
/// Calls return immediately; insertions run in order on a private serial queue. Every event is
/// marked with `SyntheticEvent.marker` and carries explicit flags, so a modifier the user is still
/// holding never merges into it.
public final class TextInserter: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        /// Virtual key code of the events that carry Unicode text. Apps take the text from the event's
        /// Unicode string, but some also look at the key: web pages see these as `code: "KeyA"`.
        /// 0 (A) is the safe default. When an app ignores the string, the worst case is a stray "a".
        /// Avoid 49 (pages see a Space press), 52 (the U.S. layout maps it to Enter, which could send a
        /// message), and unassigned codes like 102 or 127 (Chrome drops the event).
        public var unicodeKeyCode: CGKeyCode = 0
        /// UTF-16 units per Unicode event (the system delivers at most 20).
        public var maxUnitsPerEvent = SyntheticText.maxUnitsPerEvent
        /// Pause between Unicode events in `.keystrokes` mode.
        public var chunkInterval: TimeInterval = 0.001
        /// Pause between characters in `.characterByCharacter` mode.
        public var characterInterval: TimeInterval = 0.002
        /// How long the pasted text stays on the clipboard before the user's contents come back.
        public var pasteRestoreDelay: TimeInterval = 0.3
        /// Minimum gap between two pastes, so the app reads the previous text before it is replaced
        /// (holding Tab with the paste method).
        public var minimumPasteInterval: TimeInterval = 0.08
        /// Where events enter the system. The annotated session tap skips every session-level tap
        /// (including ours) and goes straight to the focused app.
        public var postLocation: CGEventTapLocation = .cgAnnotatedSessionEventTap

        public init() {}
    }

    private let queue = DispatchQueue(label: "app.tabber.TextInserter", qos: .userInteractive)
    private let lockedOptions: OSAllocatedUnfairLock<Options>
    private let pasteKeyCode = OSAllocatedUnfairLock<CGKeyCode>(initialState: CGKeyCode(KeyCode.v))
    private var layoutObserver: NSObjectProtocol?

    // Queue only.
    private var source: CGEventSource?
    private var pendingRestore: PendingRestore?
    private var lastPaste: DispatchTime?

    private struct PendingRestore {
        var snapshot: PasteboardSnapshot
        var changeCount: Int
        var work: DispatchWorkItem
    }

    public init(options: Options = Options()) {
        lockedOptions = OSAllocatedUnfairLock(initialState: options)
        DispatchQueue.main.async { [weak self] in self?.refreshPasteKey() }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPasteKey()
        }
    }

    deinit {
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
    }

    public var options: Options {
        get { lockedOptions.withLock { $0 } }
        set { lockedOptions.withLock { $0 = newValue } }
    }

    /// Types `text` at the caret. Returns immediately; insertions happen in call order.
    public func insert(_ text: String, method: InsertionMethod) {
        guard !text.isEmpty else { return }
        queue.async { [self] in
            switch method {
            case .keystrokes: type(text, perGrapheme: false)
            case .characterByCharacter: type(text, perGrapheme: true)
            case .paste: paste(text)
            }
        }
    }

    /// Deletes `count` characters before the caret with Backspace presses, then types `text`.
    /// Used for replacements such as emoji shortcodes (":joy" → "😂").
    public func replace(deleting count: Int, with text: String, method: InsertionMethod) {
        queue.async { [self] in
            for _ in 0..<max(0, count) {
                press(keyCode: CGKeyCode(KeyCode.delete), flags: [])
            }
            guard !text.isEmpty else { return }
            switch method {
            case .keystrokes: type(text, perGrapheme: false)
            case .characterByCharacter: type(text, perGrapheme: true)
            case .paste: paste(text)
            }
        }
    }

    /// Sends a real Tab press to the app, in order with insertions.
    public func passThroughTab() {
        queue.async { [self] in
            press(keyCode: CGKeyCode(KeyCode.tab), flags: [])
        }
    }

    /// Gives a swallowed key back to the app: posts the same key with the same modifiers, in order with insertions.
    public func passThrough(_ binding: KeyBinding) {
        var flags: CGEventFlags = []
        if binding.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if binding.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if binding.modifiers.contains(.control) { flags.insert(.maskControl) }
        if binding.modifiers.contains(.shift) { flags.insert(.maskShift) }
        queue.async { [self] in
            press(keyCode: CGKeyCode(binding.keyCode), flags: flags)
        }
    }

    /// Blocks until everything queued so far has been posted. A pending clipboard restore is not waited for.
    public func waitUntilIdle() {
        queue.sync {}
    }

    public enum ClipboardAccess: Sendable, Equatable {
        /// Reads are allowed without asking.
        case allowed
        /// The system asks the user on the next read (never asked yet, or set to "Ask").
        case ask
        /// Reads are refused. `.paste` falls back to `.keystrokes` rather than lose the user's clipboard.
        case denied
    }

    /// Whether `.paste` can save and restore the clipboard. On macOS 15.4+ reading the general
    /// pasteboard needs the user's permission (System Settings > Privacy > Paste from Other Apps).
    public static var clipboardAccess: ClipboardAccess {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return .allowed
            case .alwaysDeny: return .denied
            default: return .ask
            }
        }
        return .allowed
    }

    // MARK: - Keystrokes

    private func type(_ text: String, perGrapheme: Bool) {
        let options = options
        let interval = perGrapheme ? options.characterInterval : options.chunkInterval
        var first = true
        for segment in SyntheticText.segments(text) {
            let pieces: [String?]
            switch segment {
            case .newline: pieces = [nil]
            case .text(let string):
                pieces = perGrapheme
                    ? SyntheticText.graphemes(string, maxUnits: options.maxUnitsPerEvent)
                    : SyntheticText.chunks(string, maxUnits: options.maxUnitsPerEvent)
            }
            for piece in pieces {
                if !first, interval > 0 { Thread.sleep(forTimeInterval: interval) }
                first = false
                if let piece {
                    press(keyCode: options.unicodeKeyCode, flags: [], unicode: Array(piece.utf16), location: options.postLocation)
                } else {
                    press(keyCode: CGKeyCode(KeyCode.return), flags: [], location: options.postLocation)
                }
            }
        }
    }

    // MARK: - Paste

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        guard Self.clipboardAccess != .denied else {
            type(text, perGrapheme: false)
            return
        }

        // A paste right after another reuses the snapshot taken before the first one, unless the
        // user copied something in between.
        let saved: PasteboardSnapshot
        if let pending = pendingRestore, pasteboard.changeCount == pending.changeCount {
            pending.work.cancel()
            saved = pending.snapshot
        } else {
            pendingRestore?.work.cancel()
            let snapshot = PasteboardSnapshot.capture(pasteboard)
            // Items with types but no readable data mean the read was refused; don't clobber the clipboard.
            let typed = (pasteboard.pasteboardItems ?? []).filter { !$0.types.isEmpty }.count
            guard snapshot.items.filter({ !$0.entries.isEmpty }).count == typed else {
                pendingRestore = nil
                type(text, perGrapheme: false)
                return
            }
            saved = snapshot
        }

        let options = options
        if let lastPaste {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastPaste.uptimeNanoseconds) / 1e9
            if elapsed < options.minimumPasteInterval { Thread.sleep(forTimeInterval: options.minimumPasteInterval - elapsed) }
        }
        let ours = PasteboardMarker.writeTransient(text, to: pasteboard)
        press(keyCode: pasteKeyCode.withLock { $0 }, flags: .maskCommand, location: options.postLocation)
        lastPaste = .now()

        let work = DispatchWorkItem { [weak self] in
            if pasteboard.changeCount == ours { saved.restore(to: pasteboard) }
            self?.pendingRestore = nil
        }
        pendingRestore = PendingRestore(snapshot: saved, changeCount: ours, work: work)
        queue.asyncAfter(deadline: .now() + options.pasteRestoreDelay, execute: work)
    }

    private func refreshPasteKey() {
        let keyCode = KeyboardLayout.keyCodeForCommand("v") ?? CGKeyCode(KeyCode.v)
        pasteKeyCode.withLock { $0 = keyCode }
    }

    // MARK: - Events

    private func eventSource() -> CGEventSource? {
        if let source { return source }
        let created = CGEventSource(stateID: .privateState)
        created?.userData = SyntheticEvent.marker
        // Never hold back the user's own keystrokes after we post.
        created?.localEventsSuppressionInterval = 0
        source = created
        return created
    }

    /// Posts a keyDown/keyUp pair with exactly `flags`.
    private func press(keyCode: CGKeyCode, flags: CGEventFlags, unicode: [UniChar]? = nil, location: CGEventTapLocation? = nil) {
        let location = location ?? options.postLocation
        let source = eventSource()
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            if let unicode { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
            event.flags = flags
            SyntheticEvent.mark(event)
            event.post(tap: location)
        }
    }
}
