import Foundation
import SwiftData
import Testing
@testable import Baseline

/// Slice 4 (issue #7) AC-7: `ReadinessEntry` freezes the exact sleep analysis used at decision time.
/// Optional-backed fields → a row saved without them decodes with working (nil) defaults; the
/// snapshot blob round-trips the analysis losslessly and is immutable per entry.
@MainActor
struct ReadinessEntrySleepSnapshotTests {

    private let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Schema([ReadinessEntry.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func decisionAndPlan() -> (DecisionEngine.Result, PlanningEngine.Plan) {
        PlanAssembler.assemble(base: DecisionEngine.Inputs(sleepScore: 80, sleepHours: 7.0, energy: 4))
    }

    // MARK: - AC-7: snapshot round-trips through the store

    @Test func snapshotRoundTripsLosslessly() throws {
        let analysis = TestSleepAnalysis.make(score: 78, coverage: 0.9, reliability: 1.0,
                                              asleepHours: 6.8, deficit: 1.2, burden: 0.25, shift: 22)
        let (decision, plan) = decisionAndPlan()
        let snapshot = ReadinessSleepSnapshot(score: 78, confidence: 1.0, analysis: analysis)

        let context = ModelContext(container)
        context.insert(ReadinessEntry(decision: decision, plan: plan, answers: nil, sleep: snapshot))
        try context.save()

        // Reopen with a fresh context — as close to a cold read as an in-memory store allows.
        let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<ReadinessEntry>()).first)
        #expect(fetched.sleepScore == 78)
        #expect(fetched.sleepConfidence == 1.0)
        #expect(fetched.sleepDecisionSnapshot == analysis)   // the exact analysis + versions
    }

    // MARK: - AC-7: an entry saved without the seam decodes with working defaults

    @Test func entryWithoutSleepSeamHasNilDefaults() throws {
        let (decision, plan) = decisionAndPlan()
        let context = ModelContext(container)
        context.insert(ReadinessEntry(decision: decision, plan: plan, answers: nil))   // no sleep snapshot
        try context.save()

        let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<ReadinessEntry>()).first)
        #expect(fetched.sleepScore == nil)
        #expect(fetched.sleepConfidence == nil)
        #expect(fetched.sleepDecisionSnapshot == nil)
    }

    @Test func bareInitHasNilSleepFields() {
        let entry = ReadinessEntry()
        #expect(entry.sleepScore == nil)
        #expect(entry.sleepConfidence == nil)
        #expect(entry.sleepDecisionSnapshot == nil)
    }
}
