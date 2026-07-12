import Foundation
import Testing
@testable import Baseline

/// Slice 1 foundation: the pure Plan domain resolvers (status derivation + contribution-based aggregates).
struct PlanModelTests {

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date(timeIntervalSince1970: 1_752_000_000)) } // fixed ref day

    // MARK: helpers

    private func strengthWorkout() -> Workout {
        var ex = PlannedExercise(exerciseName: "Deadlift", definitionId: "deadlift")   // category .strength
        ex.prescription.sets = [PlannedSet(reps: 5, load: 100), PlannedSet(reps: 5, load: 100), PlannedSet(reps: 5, load: 100)]
        return Workout(title: "Strength", blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
    }

    private func runWorkout() -> Workout {
        var ex = PlannedExercise(exerciseName: "Run", definitionId: "run")             // category .running
        ex.prescription.sets = [PlannedSet(duration: 600, distance: 2000)]
        return Workout(title: "Run", blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
    }

    private func sched(_ w: Workout, on date: Date, skipped: Bool = false) -> ScheduledWorkout {
        ScheduledWorkout(programID: UUID(), date: date, origin: .userCreated,
                         workoutID: UUID(), workoutRevisionID: UUID(), workout: w, skipped: skipped)
    }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    // MARK: status resolver

    @Test func todaySessionResolvesToTodayStatus() {
        let sw = sched(runWorkout(), on: today)
        let s = ScheduleStatusResolver.status(for: sw, today: today, session: nil, completed: nil)
        #expect(s == .today(.asPlanned))
    }

    @Test func todayModificationIsCarriedThrough() {
        let sw = sched(runWorkout(), on: today)
        let s = ScheduleStatusResolver.status(for: sw, today: today, session: nil, completed: nil,
                                              todayModification: .reducedVolume(percent: 20))
        #expect(s == .today(.reducedVolume(percent: 20)))
    }

    @Test func futureIsPlannedUnlessExplicitlyChanged() {
        let sw = sched(runWorkout(), on: day(2))
        #expect(ScheduleStatusResolver.status(for: sw, today: today, session: nil, completed: nil) == .planned)
        let changed = ScheduleStatusResolver.status(for: sw, today: today, session: nil, completed: nil, changedBy: .baseline)
        #expect(changed == .modifiedIntent(.baseline))
    }

    @Test func pastUncompletedIsMissed_skippedIsSkipped() {
        let past = sched(runWorkout(), on: day(-2))
        #expect(ScheduleStatusResolver.status(for: past, today: today, session: nil, completed: nil) == .missed)
        let skipped = sched(runWorkout(), on: today, skipped: true)
        #expect(ScheduleStatusResolver.status(for: skipped, today: today, session: nil, completed: nil) == .skipped)
    }

    @Test func performedFactsWinOverIntent() {
        let sw = sched(runWorkout(), on: today)
        let active = WorkoutSession(scheduledWorkoutID: sw.id, startedAt: today, status: .active, log: WorkoutLog())
        #expect(ScheduleStatusResolver.status(for: sw, today: today, session: active, completed: nil) == .inProgress)
        let paused = WorkoutSession(scheduledWorkoutID: sw.id, startedAt: today, status: .paused, log: WorkoutLog())
        #expect(ScheduleStatusResolver.status(for: sw, today: today, session: paused, completed: nil) == .paused)
        // Completed wins even for a past date (immutable fact), never becomes "missed".
        let done = CompletedWorkoutLog(scheduledWorkoutID: sw.id, finishedAt: day(-1), log: WorkoutLog())
        let pastDone = sched(runWorkout(), on: day(-2))
        #expect(ScheduleStatusResolver.status(for: pastDone, today: today, session: nil, completed: done) == .completed)
    }

    // MARK: aggregates

    @Test func contributionsReflectWorkoutContent() {
        let c = AggregateProvider.contributions(of: runWorkout())
        #expect(c.contains(.init(key: .duration, amount: 600)))
        #expect(c.contains(.init(key: .distance, amount: 2000)))
        #expect(!c.contains { $0.key == .strengthSets })
        let s = AggregateProvider.contributions(of: strengthWorkout())
        #expect(s.contains(.init(key: .strengthSets, amount: 3)))
    }

    @Test func weeklyAggregatesSumAndCountSessions_excludingSkipped() {
        let week = [sched(strengthWorkout(), on: today), sched(runWorkout(), on: day(1)),
                    sched(runWorkout(), on: day(2), skipped: true)]
        let aggs = AggregateProvider.aggregates(for: week)
        func total(_ k: AggregateKey) -> Double? { aggs.first { $0.key == k }?.total }
        #expect(total(.sessions) == 2)          // skipped one excluded
        #expect(total(.strengthSets) == 3)
        #expect(total(.distance) == 2000)       // only the non-skipped run
        #expect(total(.duration) == 600)
    }
}
