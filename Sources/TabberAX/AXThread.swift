import CoreFoundation
import Foundation

/// A background thread running its own CFRunLoop. AXObserver sources and the tracker's timers live on it,
/// and all AX IPC happens here so a slow app can never stall the main thread.
final class AXThread: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var isStopped = false

    init(name: String) {
        self.name = name
    }

    var cfRunLoop: CFRunLoop {
        startIfNeeded()
        return lock.withLock { runLoop! }
    }

    var isCurrent: Bool {
        lock.withLock { runLoop.map { CFEqual($0, CFRunLoopGetCurrent()) } ?? false }
    }

    /// Runs `block` on the AX thread, in order with everything else scheduled there. Dropped after `stop()`.
    func perform(_ block: @escaping () -> Void) {
        guard !lock.withLock({ isStopped }) else { return }
        let loop = cfRunLoop
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            autoreleasepool { block() }
        }
        CFRunLoopWakeUp(loop)
    }

    /// A timer on the AX thread that fires only when `schedule(_:after:)` arms it.
    func makeTimer(_ handler: @escaping () -> Void) -> CFRunLoopTimer {
        // Repeating with a huge interval: a non-repeating CF timer invalidates itself after firing and
        // can't be re-armed with CFRunLoopTimerSetNextFireDate.
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, .greatestFiniteMagnitude, 1e9, 0, 0) { _ in
            autoreleasepool { handler() }
        }!
        CFRunLoopAddTimer(cfRunLoop, timer, .defaultMode)
        return timer
    }

    func schedule(_ timer: CFRunLoopTimer, after delay: TimeInterval) {
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + max(0, delay))
    }

    func cancel(_ timer: CFRunLoopTimer) {
        CFRunLoopTimerSetNextFireDate(timer, .greatestFiniteMagnitude)
    }

    /// Ends the thread for good. Call it from a block on the thread, after the work that must still run.
    func stop() {
        lock.withLock {
            isStopped = true
            if let runLoop { CFRunLoopStop(runLoop) }
            runLoop = nil
            thread = nil
        }
    }

    private func startIfNeeded() {
        lock.lock()
        guard runLoop == nil else { lock.unlock(); return }
        let ready = DispatchSemaphore(value: 0)
        let box = RunLoopBox()
        let thread = Thread {
            box.loop = CFRunLoopGetCurrent()
            // A source that never fires keeps CFRunLoopRun from returning while nothing else is scheduled.
            let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, .greatestFiniteMagnitude, 1e9, 0, 0) { _ in }
            CFRunLoopAddTimer(box.loop, keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = box.loop
        self.thread = thread
        lock.unlock()
    }

    private final class RunLoopBox: @unchecked Sendable {
        var loop: CFRunLoop!
    }
}
