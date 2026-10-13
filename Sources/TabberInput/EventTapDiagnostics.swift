import AppKit
import CoreGraphics
import Darwin

/// Lists event taps installed by other processes. Active (filtering) taps sit in the path of every
/// keystroke, and a leaked or slow one makes the whole Mac feel sluggish.
public enum EventTapDiagnostics {
    public struct Tap: Sendable, Equatable {
        public var pid: pid_t
        public var processName: String
        /// True for a filtering tap that can delay or drop events; false for listen-only.
        public var filters: Bool
        public var enabled: Bool
        public var location: CGEventTapLocation
        public var eventsOfInterest: CGEventMask
    }

    /// Every event tap on the system except our own process's.
    public static func allTaps() -> [Tap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
        let me = getpid()
        var names: [pid_t: String] = [:]
        return list.prefix(Int(count)).compactMap { info -> Tap? in
            guard info.tappingProcess != me else { return nil }
            let pid = info.tappingProcess
            let name = names[pid] ?? processName(pid)
            names[pid] = name
            return Tap(
                pid: pid,
                processName: name,
                filters: info.options == .defaultTap,
                enabled: info.enabled,
                location: info.tapPoint,
                eventsOfInterest: info.eventsOfInterest
            )
        }
    }

    /// Other processes' filtering (non-listen-only) taps. `isActive` is whether the tap is currently enabled.
    public static func activeTaps() -> [(pid: pid_t, processName: String, isActive: Bool)] {
        allTaps().filter(\.filters).map { (pid: $0.pid, processName: $0.processName, isActive: $0.enabled) }
    }

    static func processName(_ pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 1024)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        return "pid \(pid)"
    }
}
