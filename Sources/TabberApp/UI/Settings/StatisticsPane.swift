import Charts
import SwiftUI

/// Words Tabber typed for you, per day, over the last 30 days.
struct StatisticsPane: View {
    @EnvironmentObject private var stats: StatsStore

    private var days: [(day: Date, words: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { ($0, stats.daily[$0] ?? 0) }
        }
    }

    private var total: Int { days.reduce(0) { $0 + $1.words } }
    private var activeDays: Int { days.filter { $0.words > 0 }.count }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    Figure(value: stats.wordsToday.formatted(), caption: "words today")
                    Figure(value: Self.duration(stats.estimatedTimeSavedToday), caption: "saved today")
                    Figure(value: total.formatted(), caption: "words in 30 days")
                    Figure(value: activeDays == 0 ? "–" : (total / activeDays).formatted(), caption: "per active day")
                }
                .padding(.vertical, 6)
            }

            Section("Last 30 days") {
                Chart(days, id: \.day) { item in
                    BarMark(x: .value("Day", item.day, unit: .day), y: .value("Words", item.words))
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 180)
                .animation(.snappy, value: stats.daily)
            }

            Section {
                Text("Counts only words you accepted with Tab or the whole-suggestion key. Time saved assumes \(Int(StatsStore.typingWordsPerMinute)) words a minute. Stays on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    static func duration(_ t: TimeInterval) -> String {
        if t < 60 { return "\(Int(t.rounded())) s" }
        if t < 3600 { return "\(Int((t / 60).rounded())) min" }
        return String(format: "%.1f h", t / 3600)
    }
}

private struct Figure: View {
    var value: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
