import AppKit
import Foundation

/// Counts words inserted from accepted suggestions, per day, for the last 30 days.
@MainActor
public final class StatsStore: ObservableObject {
    public static let defaultsKey = "stats.v1"
    /// Typing speed used to estimate time saved.
    public static let typingWordsPerMinute: Double = 40
    private static let keptDays = 30

    @Published public private(set) var wordsToday = 0
    /// Words per day, keyed by the start of the day.
    @Published public private(set) var daily: [Date: Int] = [:]

    private let defaults: UserDefaults
    private let calendar = Calendar.current
    private var dayObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        daily = Self.load(from: defaults, calendar: calendar)
        prune()
        refreshToday()
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prune()
                self?.refreshToday()
            }
        }
    }

    public func recordAccepted(words: Int) {
        guard words > 0 else { return }
        let today = calendar.startOfDay(for: Date())
        daily[today, default: 0] += words
        refreshToday()
        save()
    }

    public var estimatedTimeSavedToday: TimeInterval {
        Double(wordsToday) / Self.typingWordsPerMinute * 60
    }

    private func refreshToday() {
        wordsToday = daily[calendar.startOfDay(for: Date())] ?? 0
    }

    private func prune() {
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.keptDays - 1), to: calendar.startOfDay(for: Date())) else { return }
        let kept = daily.filter { $0.key >= cutoff }
        if kept.count != daily.count { daily = kept }
    }

    // Stored as "yyyy-MM-dd" strings so the data survives time zone changes.
    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private static func load(from defaults: UserDefaults, calendar: Calendar) -> [Date: Int] {
        guard let stored = defaults.dictionary(forKey: defaultsKey) as? [String: Int] else { return [:] }
        let f = formatter()
        var result: [Date: Int] = [:]
        for (key, value) in stored {
            if let date = f.date(from: key) { result[calendar.startOfDay(for: date)] = value }
        }
        return result
    }

    private func save() {
        let f = Self.formatter()
        let stored = Dictionary(uniqueKeysWithValues: daily.map { (f.string(from: $0.key), $0.value) })
        defaults.set(stored, forKey: Self.defaultsKey)
    }
}
