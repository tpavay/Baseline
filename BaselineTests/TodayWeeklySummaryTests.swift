import Foundation
import Testing
@testable import Baseline

struct TodayWeeklySummaryTests {
    @Test func buildsTheVisibleWeekFromCompletedTrainingFacts() throws {
        let calendar = Calendar.planWeek
        let reference = try #require(ISO8601DateFormatter().date(from: "2026-07-22T12:00:00Z"))
        let finished = try #require(calendar.date(byAdding: .hour, value: -2, to: reference))
        let started = try #require(calendar.date(byAdding: .hour, value: -1, to: finished))
        let oldFinished = try #require(calendar.date(byAdding: .day, value: -8, to: finished))
        let currentID = UUID()
        let oldID = UUID()

        let summary = TodayWeeklySummary.build(
            sessions: [
                TodayCompletedSessionSample(
                    completedLogID: currentID,
                    finishedAt: finished,
                    startedAt: started
                ),
                TodayCompletedSessionSample(
                    completedLogID: oldID,
                    finishedAt: oldFinished,
                    startedAt: nil
                ),
            ],
            exercises: [
                TodayCompletedExerciseSample(
                    completedLogID: currentID,
                    date: finished,
                    definitionID: "run",
                    metrics: [
                        MetricValues([.duration: 600, .heartRate: 130]),
                        MetricValues([.duration: 1_200, .heartRate: 160]),
                    ]
                ),
                TodayCompletedExerciseSample(
                    completedLogID: currentID,
                    date: finished,
                    definitionID: "front_squat",
                    metrics: [
                        MetricValues([.reps: 5, .load: 80]),
                        MetricValues([.reps: 5, .load: 80]),
                        MetricValues([.reps: 5, .load: 80]),
                    ]
                ),
                TodayCompletedExerciseSample(
                    completedLogID: oldID,
                    date: oldFinished,
                    definitionID: "run",
                    metrics: [MetricValues([.duration: 9_000, .heartRate: 190])]
                ),
            ],
            zoneModel: HeartRateZoneModel(maxHR: 200),
            referenceDate: reference,
            calendar: calendar
        )

        #expect(summary.sessionCount == 1)
        #expect(summary.trainingSeconds == 3_600)
        #expect(summary.cardioSeconds == 1_800)
        #expect(summary.averageHeartRate == 150)
        #expect(summary.heartRateZones.first { $0.zone == .z2 }?.seconds == 600)
        #expect(summary.heartRateZones.first { $0.zone == .z4 }?.seconds == 1_200)
        #expect(summary.movements.first { $0.name == "Squat" }?.sets == 3)
        #expect(summary.movements.first { $0.name == "Carry / gait" }?.sets == 2)
        #expect(!summary.frontMuscles.isEmpty)
    }

    @Test func durationFormattingMatchesTheApprovedInstrumentationStyle() {
        #expect(TodayWeeklySummary.durationText(0) == "0m")
        #expect(TodayWeeklySummary.durationText(2_040) == "34m")
        #expect(TodayWeeklySummary.durationText(8_580) == "2h 23m")
    }
}
