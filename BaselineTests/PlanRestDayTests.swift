import Foundation
import SwiftData
import Testing
@testable import Baseline

/// The explicit rest-day marker: the one-tap "Make it a rest day" path from the per-day add sheet
/// and the Plan row's moon toggle. A marker is a plain per-day fact — global across programs,
/// idempotent, and reversible by the same toggle — surfaced through the calendar projections.
@Suite(.serialized) @MainActor
struct PlanRestDayTests {

    private func makeRepo() -> SwiftDataPlanRepository {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models),
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return SwiftDataPlanRepository(context: container.mainContext)
    }

    private let cal = Calendar.planWeek
    private var monday: Date { cal.weekStart(for: Date(timeIntervalSince1970: 1_752_000_000)) }

    @Test func markingADayRestSurfacesInEveryProjection() {
        let repo = makeRepo()
        repo.setRestDay(monday, true)

        #expect(repo.day(monday, filter: .allTraining).isRestDay)
        #expect(repo.week(containing: monday, filter: .allTraining).days[0].isRestDay)
        let range = repo.days(from: monday, through: cal.date(byAdding: .day, value: 3, to: monday)!,
                              filter: .allTraining)
        #expect(range[0].isRestDay)
        #expect(range.dropFirst().allSatisfy { $0.isRestDay == false },
                "The marker is per-day: neighbours stay unmarked")
    }

    @Test func markingIsIdempotentAndUnmarkingRemovesTheMarker() {
        let repo = makeRepo()
        repo.setRestDay(monday, true)
        repo.setRestDay(monday, true)   // second tap of a stale UI must not double-mark
        #expect(repo.day(monday, filter: .allTraining).isRestDay)

        repo.setRestDay(monday, false)
        #expect(repo.day(monday, filter: .allTraining).isRestDay == false)
        #expect(repo.restDays(in: monday ..< cal.date(byAdding: .day, value: 7, to: monday)!).isEmpty)
    }

    @Test func anyTimeOfDayMarksTheSameCalendarDay() {
        let repo = makeRepo()
        let evening = cal.date(byAdding: .hour, value: 22, to: monday)!
        repo.setRestDay(evening, true)
        #expect(repo.day(monday, filter: .allTraining).isRestDay)

        repo.setRestDay(cal.date(byAdding: .hour, value: 7, to: monday)!, false)
        #expect(repo.day(monday, filter: .allTraining).isRestDay == false)
    }

    @Test func restMarkerIsGlobalAcrossFilters() {
        let repo = makeRepo()
        let program = repo.addProgram(Program(name: "P", createdAt: monday))
        repo.setRestDay(monday, true)
        #expect(repo.day(monday, filter: .program(program.id)).isRestDay,
                "A rest day belongs to the athlete's calendar, not to a program filter")
    }

    @Test func planStoreTogglePublishesARevision() {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models),
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = PlanStore(context: container.mainContext)
        let before = store.revision
        store.setRestDay(monday, true)
        #expect(store.revision > before, "The Plan calendar caches on revision; a toggle must bump it")
        #expect(store.days(from: monday, through: monday).first?.isRestDay == true)
    }
}
