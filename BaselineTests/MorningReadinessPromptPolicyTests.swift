import Foundation
import Testing
@testable import Baseline

struct MorningReadinessPromptPolicyTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(hour: Int) -> Date {
        DateComponents(calendar: calendar, year: 2026, month: 7, day: 8, hour: hour).date!
    }

    private func config(enabled: Bool = true, source: HeartSource? = .strap) -> ReadinessConfig {
        var config = ReadinessConfig()
        config.heartReadingEnabled = enabled
        config.heartSource = source
        return config
    }

    @Test("Morning prompt appears before noon when HRV is configured and no morning reading exists")
    func appearsBeforeNoon() {
        #expect(MorningReadinessPromptPolicy.shouldPresent(
            now: date(hour: 8),
            hasMorningReadingToday: false,
            config: config(),
            calendar: calendar
        ))
    }

    @Test("Morning prompt does not appear after noon")
    func hiddenAfterNoon() {
        #expect(!MorningReadinessPromptPolicy.shouldPresent(
            now: date(hour: 12),
            hasMorningReadingToday: false,
            config: config(),
            calendar: calendar
        ))
    }

    @Test("Morning prompt does not appear after today's morning reading")
    func hiddenAfterReading() {
        #expect(!MorningReadinessPromptPolicy.shouldPresent(
            now: date(hour: 8),
            hasMorningReadingToday: true,
            config: config(),
            calendar: calendar
        ))
    }

    @Test("Morning prompt requires HRV heart reading to be configured")
    func requiresHeartReadingConfig() {
        #expect(!MorningReadinessPromptPolicy.shouldPresent(
            now: date(hour: 8),
            hasMorningReadingToday: false,
            config: config(enabled: false, source: nil),
            calendar: calendar
        ))
        #expect(!MorningReadinessPromptPolicy.shouldPresent(
            now: date(hour: 8),
            hasMorningReadingToday: false,
            config: config(enabled: true, source: nil),
            calendar: calendar
        ))
    }
}
