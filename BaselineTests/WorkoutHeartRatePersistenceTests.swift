import Foundation
import SwiftData
import Testing
@testable import Baseline

/// Durable heart rate: the sidecar entity through the repository, the summary riding on the log, and
/// the end-to-end path from a live monitor to a reloaded completed workout.
@Suite(.serialized) @MainActor
struct WorkoutHeartRatePersistenceTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRepo() throws -> SwiftDataPlanRepository {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return SwiftDataPlanRepository(context: container.mainContext)
    }

    private func workout(_ title: String = "Zone 2 Run") -> Workout {
        var exercise = PlannedExercise(exerciseName: "Run", definitionId: "run")
        exercise.prescription.sets = [PlannedSet(duration: 1_800)]
        return Workout(title: title, blocks: [WorkoutBlock(name: "", exercises: [exercise], isDefault: true)])
    }

    @discardableResult
    private func seed(_ repo: SwiftDataPlanRepository) -> ScheduledWorkout {
        let program = repo.addProgram(Program(name: "P", createdAt: start))
        return repo.addScheduled(ScheduledWorkout(
            programID: program.id, date: start, origin: .userCreated,
            workoutID: UUID(), workoutRevisionID: UUID(), workout: workout()
        ))
    }

    private func trace(count: Int, from origin: Date? = nil) -> WorkoutHeartRateTrace {
        let base = origin ?? start
        return WorkoutHeartRateTrace(points: (0..<count).map {
            HeartRateTracePoint(timestamp: base.addingTimeInterval(Double($0)), bpm: 130 + $0 % 40)
        })
    }

    private func summary(sampleCount: Int) -> WorkoutHeartRateSummary {
        WorkoutHeartRateSummary(
            averageBPM: 148,
            maxBPM: 169,
            sampleCount: sampleCount,
            zoneSeconds: [30, 240, 900, 120, 10],
            zoneModel: HeartRateZoneModelSnapshot(HeartRateZoneModel(maxHR: 190, restingHR: 50))
        )
    }

    // MARK: - Repository

    @Test func upsertingAndReadingBackRoundTripsTheWholeSeries() throws {
        let repo = try makeRepo()
        let scheduled = seed(repo)
        let recorded = trace(count: 600)

        repo.upsertHeartRateSeries(
            forScheduled: scheduled.id,
            trace: recorded,
            summary: summary(sampleCount: recorded.count),
            now: start
        )

        let stored = try #require(repo.heartRateSeries(forScheduled: scheduled.id))
        #expect(stored.trace == recorded)
        #expect(stored.scheduledWorkoutID == scheduled.id)
        #expect(stored.recordedAt == start)
        #expect(stored.summary.averageBPM == 148)
        #expect(stored.summary.zoneModel?.maxHR == 190)
        #expect(stored.remoteStoragePath == nil)   // the cloud leg is built but unwired
    }

    /// The cheap gate: "does this workout have heart rate?" must not pay for the sample array.
    @Test func theCheapChecksNeverDecodeTheSeries() throws {
        let repo = try makeRepo()
        let scheduled = seed(repo)
        #expect(repo.hasHeartRateSeries(forScheduled: scheduled.id) == false)
        #expect(repo.heartRateSummary(forScheduled: scheduled.id) == nil)

        let recorded = trace(count: 3_600)
        repo.upsertHeartRateSeries(
            forScheduled: scheduled.id,
            trace: recorded,
            summary: summary(sampleCount: recorded.count),
            now: start
        )

        #expect(repo.hasHeartRateSeries(forScheduled: scheduled.id))
        let cheapSummary = try #require(repo.heartRateSummary(forScheduled: scheduled.id))
        #expect(cheapSummary.sampleCount == 3_600)
        #expect(cheapSummary.maxBPM == 169)
    }

    @Test func reRecordingReplacesTheSeriesRatherThanAccumulating() throws {
        let repo = try makeRepo()
        let scheduled = seed(repo)
        repo.upsertHeartRateSeries(forScheduled: scheduled.id, trace: trace(count: 10), summary: summary(sampleCount: 10), now: start)
        repo.upsertHeartRateSeries(forScheduled: scheduled.id, trace: trace(count: 25), summary: summary(sampleCount: 25), now: start.addingTimeInterval(60))

        let stored = try #require(repo.heartRateSeries(forScheduled: scheduled.id))
        #expect(stored.trace.count == 25)
        #expect(stored.recordedAt == start.addingTimeInterval(60))
    }

    /// An empty trace is not evidence, so it erases rather than storing a hollow row that would make
    /// `hasHeartRateSeries` lie.
    @Test func upsertingAnEmptyTraceErasesTheSeries() throws {
        let repo = try makeRepo()
        let scheduled = seed(repo)
        repo.upsertHeartRateSeries(forScheduled: scheduled.id, trace: trace(count: 10), summary: summary(sampleCount: 10), now: start)

        repo.upsertHeartRateSeries(
            forScheduled: scheduled.id,
            trace: WorkoutHeartRateTrace(),
            summary: summary(sampleCount: 0),
            now: start
        )

        #expect(repo.hasHeartRateSeries(forScheduled: scheduled.id) == false)
        #expect(repo.heartRateSeries(forScheduled: scheduled.id) == nil)
    }

    /// The series is written while the session is still live; completion is what tells it which frozen
    /// log it belongs to.
    @Test func completingTheSessionStampsTheCompletedLogOntoTheSeries() throws {
        let repo = try makeRepo()
        let scheduled = seed(repo)
        _ = repo.startSession(forScheduled: scheduled.id, now: start)
        repo.upsertHeartRateSeries(forScheduled: scheduled.id, trace: trace(count: 20), summary: summary(sampleCount: 20), now: start)

        let completion = repo.completeSession(forScheduled: scheduled.id, acknowledgingOpenWork: true, now: start.addingTimeInterval(1_800))
        let completed = try #require({ if case .completed(let log) = completion { return log } else { return nil } }())

        let stored = try #require(repo.heartRateSeries(forScheduled: scheduled.id))
        #expect(stored.completedLogID == completed.id)
    }

    @Test func deletingTheWorkoutRemovesItsSeriesWithTheRestOfThePerformedFootprint() throws {
        let repo = try makeRepo()
        let scheduled = seed(repo)
        _ = repo.startSession(forScheduled: scheduled.id, now: start)
        repo.upsertHeartRateSeries(forScheduled: scheduled.id, trace: trace(count: 20), summary: summary(sampleCount: 20), now: start)
        _ = repo.completeSession(forScheduled: scheduled.id, acknowledgingOpenWork: true, now: start.addingTimeInterval(600))

        _ = repo.purgeProvisionalWorkout(scheduled.id, actor: .user, reason: nil)

        // The entities link by loose UUIDs, so a stranded series would keep answering "this workout
        // has heart rate" for a workout that no longer exists.
        #expect(repo.hasHeartRateSeries(forScheduled: scheduled.id) == false)
    }

    @Test func deleteHeartRateSeriesIsIdempotent() throws {
        let repo = try makeRepo()
        let scheduled = seed(repo)
        repo.deleteHeartRateSeries(forScheduled: scheduled.id)   // nothing stored yet
        repo.upsertHeartRateSeries(forScheduled: scheduled.id, trace: trace(count: 5), summary: summary(sampleCount: 5), now: start)
        repo.deleteHeartRateSeries(forScheduled: scheduled.id)
        repo.deleteHeartRateSeries(forScheduled: scheduled.id)
        #expect(repo.hasHeartRateSeries(forScheduled: scheduled.id) == false)
    }

    // MARK: - The summary on the log

    @Test func theSummaryRidesOnTheLogAndSurvivesEncodingRoundTrips() throws {
        var log = WorkoutLog()
        log.heartRateSummary = summary(sampleCount: 900)

        let decoded = try JSONDecoder().decode(WorkoutLog.self, from: try JSONEncoder().encode(log))
        #expect(decoded.heartRateSummary == log.heartRateSummary)
        #expect(decoded.heartRateSummary?.seconds(in: .z3) == 900)
    }

    /// The field is additive: a log written before it existed still decodes.
    @Test func aLogWithoutTheFieldStillDecodes() throws {
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","isComplete":true}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkoutLog.self, from: legacy)
        #expect(decoded.heartRateSummary == nil)
        #expect(decoded.isComplete)
    }

    /// The whole reason the samples live in their own entity: adding heart rate must not fatten the
    /// log blob that is re-encoded on every logged set.
    @Test func theSeriesNeverTravelsInsideTheLogBlob() throws {
        var log = WorkoutLog()
        let recorded = trace(count: 3_600)
        log.heartRateSummary = summary(sampleCount: recorded.count)

        let logBytes = try JSONEncoder().encode(log).count
        let seriesBytes = try JSONEncoder().encode(recorded.points).count
        #expect(seriesBytes > 100_000)      // ~160 KB for an hour at 1 Hz
        #expect(logBytes < 1_000)           // the log carries tens of bytes of heart rate, not that
    }

    // MARK: - End to end

    /// Live samples → finish → reload: the trace and every summary number survive, and the zone
    /// seconds match what the monitor accumulated.
    @Test func aLiveSessionPersistsItsTraceAndSummaryThroughCompletion() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plan = PlanStore(context: container.mainContext)
        let suiteName = "WorkoutHeartRatePersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let program = plan.addProgram(Program(name: "P", createdAt: start))
        let scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id, date: start, origin: .userCreated,
            workoutID: UUID(), workoutRevisionID: UUID(), workout: workout()
        ))

        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        store.startWorkout()

        // Drive a real monitor with a hand-advanced clock, as the workout screen does.
        let clock = PersistenceClock()
        let source = PersistenceLiveSource()
        let monitor = HeartRateMonitor(source: source, zoneModel: HeartRateZoneModel(maxHR: 200), now: clock.now)
        let recorder = WorkoutHeartRateRecorder()
        monitor.recorder = recorder
        monitor.startMonitoring()
        for tick in 0..<30 {
            source.emit(bpm: 130 + tick)     // 130…159: Z2 then Z3
            clock.advance(by: 1)
        }

        let capture = try #require(WorkoutHeartRateCapture(recorder: recorder, monitor: monitor))
        let coordinator = WorkoutFinishCoordinator()
        coordinator.finish(store, heartRate: capture)
        monitor.stopMonitoring()

        // What a later reader sees, straight from the repository.
        let stored = try #require(plan.heartRateSeries(for: scheduled.id))
        #expect(stored.trace.count == 30)
        #expect(stored.trace == capture.trace)
        #expect(stored.summary.averageBPM == monitor.averageBPM)
        #expect(stored.summary.maxBPM == 159)
        #expect(stored.summary.seconds(in: .z2) == capture.summary.seconds(in: .z2))
        #expect(stored.summary.seconds(in: .z3) == capture.summary.seconds(in: .z3))
        #expect(stored.summary.totalZoneSeconds == 29)   // 29 credited intervals across 30 samples

        // And what the completed log carries: the summary, never the samples.
        let completed = try #require(plan.completed(for: scheduled.id))
        #expect(completed.log.isComplete)
        #expect(completed.log.heartRateSummary == capture.summary)

        // A fresh store bound to the same workout resolves the same heart rate.
        let reopened = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        reopened.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        let reloaded = try #require(reopened.loadHeartRate())
        #expect(reloaded.trace == capture.trace)
        #expect(reloaded.summary == capture.summary)
    }

    /// A workout finished without a strap persists nothing at all — no empty row, no zero summary.
    @Test func finishingWithoutHeartRatePersistsNothing() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plan = PlanStore(context: container.mainContext)
        let suiteName = "WorkoutHeartRatePersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let program = plan.addProgram(Program(name: "P", createdAt: start))
        let scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id, date: start, origin: .userCreated,
            workoutID: UUID(), workoutRevisionID: UUID(), workout: workout()
        ))

        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        store.startWorkout()
        WorkoutFinishCoordinator().finish(store, heartRate: nil)

        #expect(plan.hasHeartRateSeries(scheduled.id) == false)
        #expect(plan.completed(for: scheduled.id)?.log.heartRateSummary == nil)
        #expect(store.loadHeartRate() == nil)
    }
}

// MARK: - Fixtures

private final class PersistenceLiveSource: LiveHeartRateSource {
    var liveSample: HeartRateSample?
    var connectionStatus: BluetoothManager.Status = .connected
    var onLiveSample: ((HeartRateSample) -> Void)?

    func startLiveMonitoring() {}
    func stopLiveMonitoring() {}
    func resubscribeLive() {}
    func reconnectLive() {}

    func emit(bpm: Int) {
        let sample = HeartRateSample(bpm: bpm, sensorContact: .detected, receivedAt: .distantPast)
        liveSample = sample
        onLiveSample?(sample)
    }
}

@MainActor
private final class PersistenceClock {
    private(set) var current = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(by seconds: TimeInterval) { current += seconds }
    var now: @MainActor () -> Date { { [self] in current } }
}
