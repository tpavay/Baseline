import Foundation
import SwiftData
import Testing
@testable import Baseline

/// End-to-end coverage for the "Today cards stay stale after a workout is deleted" bug. Exercises the two
/// halves of the fix together against a real in-memory store:
///   1. `PlanRepository.delete` cascades to the performed rows (`SDCompletedLog` / `SDCompletedExercise`),
///      so the "This Week" and "Movement Balance" inputs actually drop the deleted session.
///   2. `TodayRefreshSignature` moves when those rows change, so `TodayView.reassemble()` re-fires and the
///      cards recompute immediately instead of showing stale counts.
///
/// The sample mapping mirrors `TodayView.completedSessionSamples` / `completedExerciseSamples` so the
/// summary we assert on is the exact value the cards render.
@Suite(.serialized) @MainActor
struct TodayCardRecomputeTests {

    private let cal = Calendar.planWeek
    private var monday: Date { cal.weekStart(for: Date(timeIntervalSince1970: 1_752_000_000)) }

    private func makeStore() -> (repo: SwiftDataPlanRepository, context: ModelContext) {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models),
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (SwiftDataPlanRepository(context: container.mainContext), container.mainContext)
    }

    /// A deadlift (patterns: `.hinge`; primary muscles glutes/hamstrings/lowerBack) scheduled on `monday`,
    /// started at `monday` and finished 45 minutes later so the summary reports real training duration.
    @discardableResult
    private func completeDeadlift(_ repo: SwiftDataPlanRepository, program: UUID, load: Double) -> ScheduledWorkout {
        var ex = PlannedExercise(exerciseName: "Deadlift", definitionId: "deadlift")
        ex.prescription.sets = [PlannedSet(reps: 5, load: load)]
        let workout = Workout(title: "Pull", blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
        let sw = repo.addScheduled(ScheduledWorkout(programID: program, date: monday, origin: .userCreated,
                                                    workoutID: UUID(), workoutRevisionID: UUID(), workout: workout))
        let planned = sw.workout.allExercises.first!
        repo.startSession(forScheduled: sw.id, now: monday)
        repo.updateSessionLog(forScheduled: sw.id) { log in
            log.upsertSetLog(forPlanned: planned.id, name: planned.exerciseName, plannedSetID: planned.prescription.sets[0].id) {
                $0.values[.load] = load; $0.values.setInt(.reps, 5); $0.completed = true
            }
        }
        _ = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: true,
                                 now: cal.date(byAdding: .minute, value: 45, to: monday)!)
        return sw
    }

    private func sessionSamples(_ context: ModelContext) -> [TodayCompletedSessionSample] {
        let logs = (try? context.fetch(FetchDescriptor<SDCompletedLog>())) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<SDWorkoutSession>())) ?? []
        return logs.map { completed in
            let startedAt = sessions.first {
                $0.scheduledWorkoutID == completed.scheduledWorkoutID && $0.startedAt <= completed.finishedAt
            }?.startedAt
            return TodayCompletedSessionSample(completedLogID: completed.id, finishedAt: completed.finishedAt, startedAt: startedAt)
        }
    }

    private func exerciseSamples(_ context: ModelContext) -> [TodayCompletedExerciseSample] {
        let exercises = (try? context.fetch(FetchDescriptor<SDCompletedExercise>())) ?? []
        return exercises.map {
            TodayCompletedExerciseSample(
                completedLogID: $0.completedLogID, date: $0.date, definitionID: $0.exerciseDefinitionID,
                metrics: (try? JSONDecoder().decode([MetricValues].self, from: $0.metricsJSON)) ?? [])
        }
    }

    private func summary(_ context: ModelContext) -> TodayWeeklySummary {
        TodayWeeklySummary.build(
            sessions: sessionSamples(context),
            exercises: exerciseSamples(context),
            zoneModel: HeartRateZoneModel(maxHR: 200),
            referenceDate: monday,
            calendar: cal
        )
    }

    private func signature(_ context: ModelContext,
                           zoneModel: HeartRateZoneModel = HeartRateZoneModel(maxHR: 200)) -> String {
        TodayRefreshSignature.make(
            readings: [],
            entries: [],
            completedLogs: (try? context.fetch(FetchDescriptor<SDCompletedLog>())) ?? [],
            completedExercises: (try? context.fetch(FetchDescriptor<SDCompletedExercise>())) ?? [],
            workoutSessions: (try? context.fetch(FetchDescriptor<SDWorkoutSession>())) ?? [],
            zoneModel: zoneModel
        )
    }

    /// A zone edit is a card input like any other: it must move the signature so `.task(id:)` re-fires
    /// (and, being one cancellable task, coalesces the editor's per-keystroke commits).
    @Test func editingZonesMovesTheRefreshSignature() {
        let (repo, context) = makeStore()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        completeDeadlift(repo, program: prog.id, load: 100)

        #expect(signature(context, zoneModel: HeartRateZoneModel(maxHR: 190)) != signature(context))
        #expect(signature(context) == signature(context))
    }

    private func confirmDelete(_ repo: SwiftDataPlanRepository, _ id: UUID) {
        guard case .confirmationRequired(_, _, let proposalID) = repo.delete(id, actor: .user, reason: nil, proposalID: nil) else {
            Issue.record("expected confirmationRequired"); return
        }
        #expect(repo.delete(id, actor: .user, reason: nil, proposalID: proposalID).isApplied)
    }

    private func hingeSets(_ summary: TodayWeeklySummary) -> Int {
        summary.movements.first { $0.name == "Hinge" }?.sets ?? 0
    }

    /// Completion adds the performed rows and the cards recompute to include them — the correct existing
    /// behavior we must not regress.
    @Test func completionPopulatesTheWeeklyCards() {
        let (repo, context) = makeStore()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        completeDeadlift(repo, program: prog.id, load: 100)

        let built = summary(context)
        #expect(built.sessionCount == 1)
        #expect(built.trainingSeconds == 2_700)          // 45 minutes of training
        #expect(hingeSets(built) == 1)                   // one logged deadlift set → one Hinge set
        #expect(!built.frontMuscles.isEmpty)             // quads/traps/forearms light up front
        #expect(!built.backMuscles.isEmpty)              // glutes/hamstrings/lowerBack light up back
    }

    /// The bug and its fix: deleting the completed workout drops it from every card input immediately —
    /// session count, training duration, the Movement Balance bars, and the muscle heat map all return to
    /// empty — and the refresh signature changes so `reassemble()` re-fires.
    @Test func deletingACompletedWorkoutDropsItFromTheCardsImmediately() {
        let (repo, context) = makeStore()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = completeDeadlift(repo, program: prog.id, load: 100)

        let before = summary(context)
        let signatureBefore = signature(context)
        #expect(before.sessionCount == 1)
        #expect(hingeSets(before) == 1)

        confirmDelete(repo, sw.id)

        let after = summary(context)
        #expect(after.sessionCount == 0)                                 // "This Week" SESSIONS drops it
        #expect(after.trainingSeconds == 0)                              // TRAINING duration drops it
        #expect(after.movements.allSatisfy { $0.sets == 0 })            // every Movement Balance bar empties
        #expect(after.frontMuscles.isEmpty)                              // muscle heat map clears
        #expect(after.backMuscles.isEmpty)
        #expect(after == .empty)                                         // identical to a fresh, empty week
        #expect(signature(context) != signatureBefore)                   // the trigger fires → cards recompute
    }

    /// Deleting one completed day leaves an unrelated completed day fully intact in the cards.
    @Test func deletingOneDayLeavesAnotherDaysContributionIntact() {
        let (repo, context) = makeStore()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let doomed = completeDeadlift(repo, program: prog.id, load: 100)
        _ = completeDeadlift(repo, program: prog.id, load: 140)
        #expect(summary(context).sessionCount == 2)

        confirmDelete(repo, doomed.id)

        let after = summary(context)
        #expect(after.sessionCount == 1)                 // the surviving day still counts
        #expect(hingeSets(after) == 1)                   // and still contributes its Hinge set
        #expect(!after.backMuscles.isEmpty)
    }
}
