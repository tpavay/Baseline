import Foundation
import Testing
@testable import Baseline

/// Guards the stale/mixed-HRV fix: today's autonomic evidence must come only from a morning reading
/// taken *today*, and the baseline must be single-source.
@MainActor
struct TodayEvidenceTests {

    private func reading(daysAgo: Int, kind: ReadingType, ln: Double, hr: Double, source: ReadingSource) -> Reading {
        let r = Reading()
        r.date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        r.kind = kind
        r.lnRMSSD = ln
        r.meanHR = hr
        r.source = source
        return r
    }

    @Test func ignoresYesterdayAndTodaysSnapshot() async {
        let readings = [
            reading(daysAgo: 0, kind: .snapshot, ln: 3.0, hr: 70, source: .chestStrap),  // today, but a snapshot
            reading(daysAgo: 1, kind: .morning, ln: 4.5, hr: 50, source: .chestStrap),   // a morning, but yesterday
        ]
        let inputs = await TodayEvidence.baseInputs(readings: readings, todayEntry: nil, health: HealthService())
        #expect(inputs.lnRMSSD == nil)     // no morning reading *today* → autonomic simply absent
        #expect(inputs.restingHR == nil)
        #expect(inputs.hrvBaseline == nil)
    }

    @Test func usesTodaysMorningAndFiltersBaselineBySource() async {
        let readings = [
            reading(daysAgo: 0, kind: .morning, ln: 4.0, hr: 52, source: .chestStrap),   // today's read
            reading(daysAgo: 1, kind: .morning, ln: 4.1, hr: 51, source: .chestStrap),   // prior, same source ✓
            reading(daysAgo: 2, kind: .morning, ln: 4.2, hr: 53, source: .chestStrap),   // prior, same source ✓
            reading(daysAgo: 3, kind: .morning, ln: 1.0, hr: 90, source: .camera),       // other source — excluded
        ]
        let inputs = await TodayEvidence.baseInputs(readings: readings, todayEntry: nil, health: HealthService())
        #expect(inputs.lnRMSSD == 4.0)
        #expect(inputs.restingHR == 52)
        #expect(inputs.hrvBaseline?.count == 2)                       // only the two prior strap mornings
        if let mean = inputs.hrvBaseline?.mean { #expect(abs(mean - 4.15) < 0.001) }   // camera outlier not mixed in
    }
}
