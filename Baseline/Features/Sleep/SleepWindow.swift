import Foundation

/// Day-window math for night queries — the only aggregation Slice 2 owns. Pure and tiny by
/// design: Slice 3's scoring/comparison logic consumes these windows, it does not live here.
enum SleepWindow {
    /// Half-open interval covering the `days` recovery days ending on (and including) the day
    /// of `date`: `[startOfDay(date) - (days-1), startOfDay(date) + 1)`.
    static func interval(days: Int, endingOn date: Date, calendar: Calendar) -> DateInterval {
        let dayStart = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let start = calendar.date(byAdding: .day, value: -max(1, days), to: end) ?? end
        return DateInterval(start: start, end: end)
    }
}
