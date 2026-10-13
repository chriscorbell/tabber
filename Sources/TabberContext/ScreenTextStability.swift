import CoreGraphics
import Foundation

public enum TextSimilarity {
    /// Lowercased words of two or more letters or digits.
    public static func words(_ text: String) -> Set<String> {
        var out = Set<String>()
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                if current.count >= 2 { out.insert(current) }
                current = ""
            }
        }
        if current.count >= 2 { out.insert(current) }
        return out
    }

    /// Jaccard similarity of two word sets: 1 when identical (or both empty), 0 when disjoint.
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let union = a.union(b).count
        return union == 0 ? 1 : Double(a.intersection(b).count) / Double(union)
    }

    public static func jaccard(_ a: String, _ b: String) -> Double {
        jaccard(words(a), words(b))
    }
}

/// Decides whether a fresh capture replaces the screen text already in use for a field.
///
/// The screen text sits in the prompt preamble, which the engine keeps in its KV cache. Swapping it costs a
/// re-evaluation of the whole preamble, so OCR jitter and ticking clocks must not swap it. Rules:
/// - a clear change (word-set similarity below `changeThreshold`: scrolled, switched conversation) swaps at once;
/// - after `minimumHold`, a smaller change swaps only if it brings at least `minimumNewWords` new words (a new chat
///   message does, a clock going from 7:45 to 7:46 doesn't);
/// - anything else keeps the current text.
public struct ScreenTextStability: Sendable, Equatable {
    public var minimumHold: TimeInterval
    public var changeThreshold: Double
    public var minimumNewWords: Int

    public init(minimumHold: TimeInterval = 20, changeThreshold: Double = 0.7, minimumNewWords: Int = 4) {
        self.minimumHold = minimumHold
        self.changeThreshold = changeThreshold
        self.minimumNewWords = minimumNewWords
    }

    /// - Parameters:
    ///   - current: Text in use, or nil when nothing has been captured for the field yet.
    ///   - age: Seconds since `current` was adopted.
    ///   - candidate: Text from a capture that succeeded (empty when nothing was recognized).
    public func shouldReplace(current: String?, age: TimeInterval, with candidate: String) -> Bool {
        guard let current else { return true }
        if current == candidate { return false }
        let old = TextSimilarity.words(current), new = TextSimilarity.words(candidate)
        if TextSimilarity.jaccard(old, new) < changeThreshold { return true }
        return age >= minimumHold && new.subtracting(old).count >= minimumNewWords
    }
}

/// When to capture the screen again for one field.
///
/// Re-captures are spaced at least `baseInterval` apart. Each capture that changes nothing doubles the spacing up to
/// `maxInterval`, so a static window costs almost nothing; a change resets it. A field that moved on screen (the page
/// scrolled, the layout changed) is due again as soon as `baseInterval` allows.
struct CaptureSchedule: Equatable {
    var baseInterval: TimeInterval = 4
    var maxInterval: TimeInterval = 16
    /// How far the field must move, in points, to count as a layout change.
    var movementThreshold: CGFloat = 24

    private(set) var interval: TimeInterval = 4
    private(set) var lastStart: Date?
    private(set) var lastFrame: CGRect?

    init(baseInterval: TimeInterval = 4, maxInterval: TimeInterval = 16) {
        self.baseInterval = baseInterval
        self.maxInterval = max(maxInterval, baseInterval)
        self.interval = baseInterval
    }

    func isDue(now: Date, frame: CGRect?) -> Bool {
        guard let lastStart else { return true }
        let elapsed = now.timeIntervalSince(lastStart)
        guard elapsed >= baseInterval else { return false }
        if let frame, let lastFrame, CaptureSchedule.distance(frame, lastFrame) > movementThreshold { return true }
        return elapsed >= interval
    }

    mutating func started(now: Date, frame: CGRect?) {
        lastStart = now
        lastFrame = frame
    }

    mutating func finished(changed: Bool) {
        interval = changed ? baseInterval : min(maxInterval, interval * 2)
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }
}
