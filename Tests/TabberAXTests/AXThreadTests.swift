import Foundation
import Testing
@testable import TabberAX

/// Collects values from the AX thread.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    private var threads: [Bool] = []
    func add(_ value: Int) {
        lock.withLock {
            values.append(value)
            threads.append(Thread.isMainThread)
        }
    }
    var snapshot: (values: [Int], onMain: [Bool]) { lock.withLock { (values, threads) } }
}

@Suite struct AXThreadTests {
    @Test func runsBlocksInOrderOffTheMainThread() async throws {
        let thread = AXThread(name: "test.ax")
        let recorder = Recorder()
        for i in 0..<50 { thread.perform { recorder.add(i) } }
        try await waitUntil { recorder.snapshot.values.count == 50 }
        #expect(recorder.snapshot.values == Array(0..<50))
        #expect(!recorder.snapshot.onMain.contains(true))
        thread.perform { thread.stop() }
    }

    @Test func timersFireOnlyWhenArmed() async throws {
        let thread = AXThread(name: "test.ax.timer")
        let recorder = Recorder()
        let timer = thread.makeTimer { recorder.add(1) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.snapshot.values.isEmpty)
        thread.schedule(timer, after: 0.01)
        try await waitUntil { recorder.snapshot.values.count == 1 }
        // Fires once per arming.
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.snapshot.values.count == 1)
        thread.schedule(timer, after: 0.01)
        thread.cancel(timer)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.snapshot.values.count == 1)
        thread.perform { thread.stop() }
    }

    @Test func dropsWorkAfterStop() async throws {
        let thread = AXThread(name: "test.ax.stop")
        let recorder = Recorder()
        thread.perform { thread.stop() }
        try await Task.sleep(for: .milliseconds(50))
        thread.perform { recorder.add(1) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.snapshot.values.isEmpty)
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
