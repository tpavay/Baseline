import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The claim the whole feature rests on, exercised against a real **on-disk** store rather than an
/// in-memory one: a session recorded from a live strap is still chartable after the app is gone.
/// The trace is written through the finish coordinator, the container that wrote it is released, and
/// a brand-new container is opened over the same store file — the way a relaunch reaches it — before
/// the session log is rendered.
@MainActor
struct WorkoutHeartRateDurabilityRenderTests {

    @Test func aRecordedTraceSurvivesAColdReopenAndStillCharts() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hr-durability-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let suiteName = "WorkoutHeartRateDurabilityRenderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // MARK: Session one — record from a live monitor and finish.
        let scheduledID = try record(storeURL: storeURL, defaults: defaults)

        // MARK: Relaunch — a container that never saw the write.
        let reopened = try Self.container(at: storeURL)
        let plan = PlanStore(context: reopened.mainContext)
        let series = try #require(
            plan.heartRateSeries(for: scheduledID),
            "The recorded series did not survive a cold reopen of the store."
        )
        #expect(series.trace.count == 60)
        #expect(series.summary.maxBPM == 169)
        // The samples live in the sidecar, never inside the completed log's JSON blob.
        let completed = try #require(plan.completed(for: scheduledID))
        #expect(completed.log.heartRateSummary == series.summary)

        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        let screen = try DurableSessionLogScreen(
            scheduledID: scheduledID, plan: plan, store: store, container: reopened, defaults: defaults
        )
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.hasLabel(containing: "Zone 2 Intervals") }
        try await screen.settle()

        let spoken = try #require(
            AccessibilityElementWalker.elements(in: screen.window)
                .compactMap(\.accessibilityLabel)
                .first { $0.contains("Heart rate over time") }
        )
        #expect(spoken.contains("beats per minute"))
        try screen.capture("workout-detail-heart-rate-after-relaunch")
    }

    /// Everything the first launch does: schedule, start, log, stream a strap through the real
    /// monitor + recorder, finish. Scoped so its container is released before the store is reopened.
    private func record(storeURL: URL, defaults: UserDefaults) throws -> UUID {
        let container = try Self.container(at: storeURL)
        let plan = PlanStore(context: container.mainContext)

        var run = PlannedExercise(
            exerciseName: "Run",
            definitionId: "run",
            selectedMetrics: [.duration, .distance],
            prescription: Prescription(sets: [PlannedSet(duration: 1_800, distance: 6_000)], targetZone: 3)
        )
        run.guidance = CoachGuidance(formCues: ["Hold an easy conversational pace."])
        let workout = Workout(
            title: "Zone 2 Intervals",
            goal: "Aerobic base",
            blocks: [WorkoutBlock(name: "", exercises: [run], isDefault: true)]
        )
        let scheduled = plan.newScheduledWorkout(on: Date(), workout: workout)

        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        store.startWorkout()
        store.editLog { log in
            for exercise in store.current?.allExercises ?? [] {
                for set in exercise.prescription.sets {
                    log.upsertSetLog(
                        forPlanned: exercise.id, name: exercise.exerciseName, plannedSetID: set.id
                    ) { actual in
                        actual.values = set.expectedValues(iteration: 1)
                        actual.outcome = .completed
                    }
                }
                log.setStatus(.completed, forPlanned: exercise.id, name: exercise.exerciseName)
            }
        }

        // Seeded at the session's own start: in the app the monitor and the store read the same
        // wall clock, so the trace's span and the session's bookends agree to within seconds.
        let clock = DurabilityClock(start: store.currentLogStartedAt ?? Date())
        let source = DurabilityLiveSource()
        let monitor = HeartRateMonitor(
            source: source, zoneModel: HeartRateZoneModel(maxHR: 190, restingHR: 52), now: clock.now
        )
        let recorder = WorkoutHeartRateRecorder()
        monitor.recorder = recorder
        monitor.startMonitoring()
        // A minute of strap data that climbs into Z4 and settles back — 169 is the peak.
        for tick in 0..<60 {
            source.emit(bpm: 130 + Int((sin(Double(tick) / 9) * 39).rounded()))
            clock.advance(by: 1)
        }
        let capture = try #require(WorkoutHeartRateCapture(recorder: recorder, monitor: monitor))
        WorkoutFinishCoordinator().finish(store, heartRate: capture)
        monitor.stopMonitoring()
        store.unbind()

        return scheduled.id
    }

    static func container(at url: URL) throws -> ModelContainer {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        return try ModelContainer(for: Schema(models), configurations: ModelConfiguration(url: url))
    }
}

// MARK: - Screen

@MainActor
private final class DurableSessionLogScreen: HostedScreen {
    let window: UIWindow

    init(
        scheduledID: UUID,
        plan: PlanStore,
        store: WorkoutStore,
        container: ModelContainer,
        defaults: UserDefaults
    ) throws {
        let root = WorkoutDetailView(scheduledWorkoutID: scheduledID)
            .environment(AppSettings(defaults: defaults))
            .environment(plan)
            .environment(store)
            .modelContainer(container)
            .preferredColorScheme(.dark)
        window = try Self.makeWindow(rootView: root)
    }

    func hasLabel(containing text: String) -> Bool {
        AccessibilityElementWalker.elements(in: window).contains {
            $0.accessibilityLabel?.contains(text) ?? false
        }
    }
}

// MARK: - Live-strap doubles

private final class DurabilityLiveSource: LiveHeartRateSource {
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

/// Hand-advanced clock so capture timestamps and zone seconds are deterministic.
@MainActor
private final class DurabilityClock {
    private var current: Date
    init(start: Date) { current = start }
    func advance(by seconds: TimeInterval) { current += seconds }
    var now: @MainActor () -> Date { { [self] in current } }
}
