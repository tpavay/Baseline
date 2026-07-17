#if DEBUG
import Foundation

/// Preview-only, fully deterministic sleep fixtures (no `Date()`): a staged watch night with real
/// stage intervals + a nap, a cold-start partial night, and a manual night — each paired with the
/// analysis the pure `SleepEngine` derives from it, so previews render the same numbers production
/// would. Used only by `#Preview` blocks; excluded from release builds.
enum SleepPreviewFixtures {

    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    private static let need: Duration = .seconds(8 * 3600)

    private static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Staged night (score present, rich evidence)

    /// The wake day of the headline night.
    private static let wakeDay = at(2026, 7, 14, 0)

    static let stagedNight: SleepNight = {
        let bedtime = at(2026, 7, 13, 23, 0)
        func off(_ minutes: Double) -> Date { bedtime.addingTimeInterval(minutes * 60) }
        let intervals: [SleepStageInterval] = [
            .init(stage: .core, start: off(0), end: off(75), source: source),
            .init(stage: .deep, start: off(75), end: off(150), source: source),
            .init(stage: .awake, start: off(150), end: off(158), source: source),
            .init(stage: .rem, start: off(158), end: off(210), source: source),
            .init(stage: .core, start: off(210), end: off(240), source: source),
            // 04:00–04:20 tracking gap
            .init(stage: .core, start: off(260), end: off(360), source: source),
            .init(stage: .deep, start: off(360), end: off(405), source: source),
            .init(stage: .awake, start: off(405), end: off(412), source: source),
            .init(stage: .rem, start: off(412), end: off(475), source: source),
        ]
        let primary = SleepEpisode(id: UUID(), start: off(0), end: off(475), intervals: intervals,
                                   isPrimary: true, gaps: [DateInterval(start: off(240), end: off(260))])
        let napStart = at(2026, 7, 14, 14, 30)
        let nap = SleepEpisode(id: UUID(), start: napStart, end: napStart.addingTimeInterval(35 * 60),
                               intervals: [.init(stage: .core, start: napStart,
                                                 end: napStart.addingTimeInterval(35 * 60), source: source)],
                               isPrimary: false, gaps: [])
        return SleepNight(
            id: UUID(), date: wakeDay, episodes: [primary, nap],
            bedtime: bedtime, wakeTime: off(475),
            asleepHours: 7.3, inBedHours: 8.0, awakenings: 2, wasoMinutes: 15,
            resolvedSource: source, analysisStatus: .complete,
            sourceFingerprint: "preview-staged", composingSampleUUIDs: [],
            lastHealthKitSyncAt: at(2026, 7, 14, 7, 30), lastSampleEndDate: off(475),
            revision: 0, factsSchemaVersion: 1)
    }()

    static let stagedAnalysis = SleepEngine.analyze(night: stagedNight, history: stagedHistory, need: need)

    // MARK: - Cold-start partial night (score nil — duration only)

    static let partialNight: SleepNight = {
        let bedtime = at(2026, 7, 13, 23, 30)
        let wake = at(2026, 7, 14, 6, 15)
        let primary = SleepEpisode(id: UUID(), start: bedtime, end: wake,
                                   intervals: [.init(stage: .unspecified, start: bedtime, end: wake, source: source)],
                                   isPrimary: true, gaps: [])
        return SleepNight(
            id: UUID(), date: wakeDay, episodes: [primary],
            bedtime: bedtime, wakeTime: wake, asleepHours: 6.75, inBedHours: 6.75,
            awakenings: nil, wasoMinutes: nil,
            resolvedSource: source, analysisStatus: .provisional,
            sourceFingerprint: "preview-partial", composingSampleUUIDs: [],
            lastHealthKitSyncAt: at(2026, 7, 14, 6, 30), lastSampleEndDate: wake,
            revision: 0, factsSchemaVersion: 1)
    }()

    /// No prior history → consistency unavailable, so the score stays nil (observed/possible only).
    static let partialAnalysis = SleepEngine.analyze(night: partialNight, history: [], need: need)

    // MARK: - Manual night (low reliability, duration-only evidence, score nil)

    static let manualNight: SleepNight = {
        let bedtime = at(2026, 7, 13, 23, 45)
        let wake = at(2026, 7, 14, 7, 0)
        let primary = SleepEpisode(id: UUID(), start: bedtime, end: wake,
                                   intervals: [.init(stage: .unspecified, start: bedtime, end: wake, source: .manual)],
                                   isPrimary: true, gaps: [])
        return SleepNight(
            id: UUID(), date: wakeDay, episodes: [primary],
            bedtime: bedtime, wakeTime: wake, asleepHours: 7.25, inBedHours: 7.25,
            awakenings: nil, wasoMinutes: nil,
            resolvedSource: .manual, analysisStatus: .complete,
            sourceFingerprint: "preview-manual", composingSampleUUIDs: [],
            lastHealthKitSyncAt: nil, lastSampleEndDate: nil,
            revision: 0, factsSchemaVersion: 1)
    }()

    static let manualAnalysis = SleepEngine.analyze(night: manualNight, history: [], need: need)

    // MARK: - Decisions for the footer

    /// A decision where a sleep cap bound the day → cap attribution + weighted influence.
    static let cappedDecision = DecisionEngine.Result(
        score: 55, band: .red, certainty: .medium, calibrating: false,
        domains: [.init(domain: .sleep, subscore: 62, weight: 0.24),
                  .init(domain: .autonomic, subscore: 71, weight: 0.40)],
        primaryLimiter: .sleep, secondaryLimiter: nil,
        appliedCaps: [.init(domain: .sleep, cap: 55, reason: "poorSleep")],
        constraints: [])

    /// A decision where sleep only influenced the blend (no cap) → influence line, no cap.
    static let influenceOnlyDecision = DecisionEngine.Result(
        score: 81, band: .green, certainty: .high, calibrating: false,
        domains: [.init(domain: .sleep, subscore: 82, weight: 0.24),
                  .init(domain: .autonomic, subscore: 84, weight: 0.40)],
        primaryLimiter: nil, secondaryLimiter: nil, appliedCaps: [], constraints: [])

    // MARK: - Helpers

    private static let source: SleepSource = .healthKit(bundleID: "com.apple.health.PREVIEW")

    /// 20 prior staged nights so consistency (≥5) and notable-night flags (≥14) are available.
    private static let stagedHistory: [SleepNight] = (1...20).map { back in
        let day = calendar.date(byAdding: .day, value: -back, to: wakeDay)!
        let bedtime = calendar.date(byAdding: .day, value: -1, to: day)
            .flatMap { calendar.date(bySettingHour: 23, minute: 5, second: 0, of: $0) }!
        let wake = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: day)!
        let primary = SleepEpisode(id: UUID(), start: bedtime, end: wake,
                                   intervals: [.init(stage: .core, start: bedtime, end: wake, source: source)],
                                   isPrimary: true, gaps: [])
        return SleepNight(
            id: UUID(), date: day, episodes: [primary],
            bedtime: bedtime, wakeTime: wake, asleepHours: 7.6, inBedHours: 7.9,
            awakenings: 1, wasoMinutes: 8,
            resolvedSource: source, analysisStatus: .complete,
            sourceFingerprint: "preview-hist-\(back)", composingSampleUUIDs: [],
            lastHealthKitSyncAt: wake, lastSampleEndDate: wake, revision: 0, factsSchemaVersion: 1)
    }
}
#endif
