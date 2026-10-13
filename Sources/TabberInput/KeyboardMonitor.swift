import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

public enum KeyboardMonitorError: Error, Equatable {
    /// The system refused the event tap. Usually Accessibility permission is missing.
    case tapCreationFailed
}

/// A session-level event tap on its own thread that owns the accept, dismiss, and hotkey keys.
///
/// The tap callback never blocks, never calls Accessibility, and never waits on the main thread: it
/// decides from an in-memory `InterceptState` and returns. Events are reported to `onEvent` with
/// `DispatchQueue.main.async`. Events Tabber posts itself (marked with `SyntheticEvent.marker`) pass
/// straight through.
public final class KeyboardMonitor: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: InterceptState())
    private let handler = OSAllocatedUnfairLock<(@MainActor (KeyEvent) -> Void)?>(uncheckedState: nil)
    private let lifecycle = NSLock()

    // Tap thread only.
    private var interceptor = KeyInterceptor()
    private var tap: CFMachPort?

    // Guarded by `lifecycle`.
    private var runLoop: CFRunLoop?
    private var stopped: DispatchSemaphore?

    public init() {}

    /// Called on the main queue for every classified event, in order.
    public var onEvent: (@MainActor (KeyEvent) -> Void)? {
        get { handler.withLockUnchecked { $0 } }
        set { handler.withLockUnchecked { $0 = newValue } }
    }

    /// Installs the tap. Throws when the system refuses it (no Accessibility permission). Calling it
    /// again while running does nothing.
    public func start() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard runLoop == nil else { return }

        let ready = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let created = RunLoopBox()
        let thread = Thread { [self] in
            guard let port = makeTap() else {
                ready.signal()
                stopped.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, source, .commonModes)
            tap = port
            interceptor = KeyInterceptor()
            CGEvent.tapEnable(tap: port, enable: true)
            created.loop = loop
            ready.signal()

            CFRunLoopRun()

            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(port)
            tap = nil
            stopped.signal()
        }
        thread.name = "Tabber.KeyboardMonitor"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        guard let loop = created.loop else { throw KeyboardMonitorError.tapCreationFailed }
        runLoop = loop
        self.stopped = stopped
    }

    /// Removes the tap and ends its thread.
    public func stop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard let loop = runLoop else { return }
        // Stop from inside the loop, so it works even if the thread hasn't entered CFRunLoopRun yet.
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
        CFRunLoopWakeUp(loop)
        _ = stopped?.wait(timeout: .now() + 1)
        runLoop = nil
        stopped = nil
    }

    public var isRunning: Bool {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        return runLoop != nil
    }

    /// Cheap and thread-safe. Takes effect for the next event.
    public func update(_ state: InterceptState) {
        self.state.withLock { $0 = state }
    }

    /// When Secure Event Input is on (a password field anywhere, some terminals), the session tap
    /// receives no key events at all.
    public static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// The process holding Secure Event Input, if the system reports it.
    public static var secureInputProcessID: pid_t? {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (info["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
    }

    // MARK: - Tap

    private func makeTap() -> CFMachPort? {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardMonitorCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if SyntheticEvent.isSynthetic(event) { return Unmanaged.passUnretained(event) }
            let decision = interceptor.keyDown(
                keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags,
                characters: Self.characters(of: event),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                state: state.withLock { $0 }
            )
            if let reported = decision.event { deliver(reported) }
            return decision.swallow ? nil : Unmanaged.passUnretained(event)

        case .keyUp:
            if SyntheticEvent.isSynthetic(event) { return Unmanaged.passUnretained(event) }
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            return interceptor.keyUp(keyCode: keyCode) ? nil : Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            deliver(.pointerDown)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func deliver(_ event: KeyEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.onEvent else { return }
            MainActor.assumeIsolated { handler(event) }
        }
    }

    private static func characters(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }
}

/// Hands the tap thread's run loop back to `start()`. Written before `ready.signal()`, read after `ready.wait()`.
private final class RunLoopBox: @unchecked Sendable {
    var loop: CFRunLoop?
}

private func keyboardMonitorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
