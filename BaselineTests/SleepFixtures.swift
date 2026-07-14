import Foundation
@testable import Baseline

/// Deterministic sleep fixtures: a fixed calendar/timezone, known source bundles, and a canonical
/// staged watch night whose expected metrics are known to the minute. Everything time-related is
/// pinned — no `Date()` anywhere in the sleep tests.
enum SleepFixtures {

    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    static let watchBundle = "com.apple.health.A1B2C3"
    static let phoneBundle = "com.apple.health.iphone"
    static let ouraBundle = "com.ouraring.oura"
    static let healthAppBundle = "com.apple.Health"

    static func date(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func watch(_ kind: SleepSample.Kind, _ start: Date, _ end: Date) -> SleepSample {
        SleepSample(start: start, end: end, kind: kind, sourceBundleID: watchBundle, deviceModel: "Watch")
    }

    static func context(lastSyncAt: Date, preferred: String? = nil) -> SleepIngestionEngine.Context {
        SleepIngestionEngine.Context(
            calendar: calendar,
            preferredSourceBundleID: preferred,
            lastSyncAt: lastSyncAt,
            stabilization: SleepStabilizationRule()
        )
    }

    /// The canonical staged night: bedtime → wake spans 8 h with two awakenings (12 m + 3 m),
    /// one 20-minute tracking gap, and an in-bed span of 8 h 10 m.
    ///
    /// Expected canonical facts (bedtime 23:00): asleep 7 h 25 m (7.41667 h), in-bed 8.16667 h,
    /// awakenings 2, WASO 15 m, one gap at +240 m…+260 m, 8 stage intervals, 1 episode.
    static func stagedWatchNight(bedtime: Date) -> [SleepSample] {
        func at(_ minutes: Double) -> Date { bedtime.addingTimeInterval(minutes * 60) }
        return [
            watch(.inBed, at(-5), at(485)),     // 22:55 – 07:05
            watch(.core, at(0), at(120)),       // 23:00 – 01:00
            watch(.deep, at(120), at(180)),     // 01:00 – 02:00
            watch(.awake, at(180), at(192)),    // 02:00 – 02:12
            watch(.rem, at(192), at(240)),      // 02:12 – 03:00
            // untracked 03:00 – 03:20: a 20-minute tracking gap
            watch(.core, at(260), at(360)),     // 03:20 – 05:00
            watch(.awake, at(360), at(363)),    // 05:00 – 05:03
            watch(.deep, at(363), at(420)),     // 05:03 – 06:00
            watch(.rem, at(420), at(480)),      // 06:00 – 07:00
        ]
    }

    /// Minimal staged night for backfill fixtures: one core block 23:00 (previous day) → 07:00.
    static func simpleStagedNight(wakeDay: Date, bundle: String = watchBundle) -> [SleepSample] {
        let previousDay = calendar.date(byAdding: .day, value: -1, to: wakeDay)!
        let bedtime = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: previousDay)!
        let wake = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: wakeDay)!
        return [SleepSample(start: bedtime, end: wake, kind: .core, sourceBundleID: bundle, deviceModel: "Watch")]
    }
}
