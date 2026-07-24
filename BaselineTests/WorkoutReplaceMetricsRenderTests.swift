import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Drives the replace-exercise metrics fix through the real `WorkoutView`, mid-session, the way the
/// captain hit it: a lift is logged, then replaced with a cardio movement. Each state is written to a
/// PNG so the fix can be looked at, not only asserted about.
///
/// The bug had two visible halves, both checked here:
/// - the old movement's per-set values (a lift's reps/load) no longer linger on the new movement, and
///   the displayed columns follow the new movement's metric schema (time/distance/pace); and
/// - the metric selection is editable against the *new* movement after the swap, not locked to the
///   hidden original.
///
/// Hosted in a scene-attached window because sign-in gates a plain launch and an unattached window
/// renders blank — the same harness the other in-workout render suites use.
@MainActor
struct WorkoutReplaceMetricsRenderTests {

    @Test func replacingALiftWithCardioResetsMetricsAndStaysEditable() async throws {
        let bed = try ReplaceBed()
        let screen = try await bed.render()
        defer { screen.tearDown() }

        // BEFORE: a live-logged lift shows its own schema — reps and load.
        let exID = try #require(bed.store.current?.allExercises.first?.id)
        bed.store.editLog {
            $0.upsertSetLog(forPlanned: exID, name: "Barbell Back Squat", plannedSetID: bed.firstSetID) {
                $0.reps = 5; $0.load = 100; $0.completed = true
            }
        }
        try await screen.settle()
        screen.capture("01-live-log-lift-before-replace")

        // Replace with a cardio movement through the same store call the substitute sheet makes.
        let run = ExerciseCatalog.resolve("Run")
        bed.store.substituteLoggedExercise(exerciseID: exID, with: run)
        try await screen.settle()
        screen.capture("02-live-log-after-replace-to-cardio")

        // The visible exercise now carries the run's schema — no lift metrics survive on it.
        let planned = try #require(bed.store.current?.exercise(exID))
        let effective = try #require(bed.store.currentLog?.effectiveExercise(for: planned))
        #expect(effective.definitionId == "run")
        #expect(effective.selectedMetrics.contains(.reps) == false)
        #expect(effective.selectedMetrics.contains(.load) == false)
        let logged = try #require(bed.store.currentLog?.performed(forPlanned: exID)?.setLogs.first)
        #expect(logged.reps == nil)
        #expect(logged.load == nil)

        // The metric selection is editable and validated against the NEW movement: a run metric enables
        // (proving the editor is no longer pointed at the hidden lift), while a lift metric is rejected.
        #expect(bed.store.setLoggingConfigForActiveExercise(
            exerciseID: exID, enabled: [.duration, .distance, .cadence], scope: .session))
        #expect(bed.store.setLoggingConfigForActiveExercise(
            exerciseID: exID, enabled: [.load], scope: .session) == false)
        try await screen.settle()
        screen.capture("03-live-log-after-editing-cardio-metrics")
    }
}

/// Today's scheduled workout holding one logged lift, bound to a started `WorkoutStore`.
@MainActor
private final class ReplaceBed {
    let plan: PlanStore
    let store: WorkoutStore
    let firstSetID: UUID
    private let container: ModelContainer
    private let scheduledID: UUID

    init() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(for: Schema(models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))

        let squat = ExerciseCatalog.resolve("back squat")
        var exercise = PlannedExercise(exerciseName: squat.name, definitionId: squat.id)
        exercise.selectedMetrics = [.reps, .load]
        exercise.prescription.sets = (0..<3).map { _ in PlannedSet(reps: 5, load: 100) }
        firstSetID = exercise.prescription.sets[0].id

        let workout = Workout(
            title: "Lower body",
            blocks: [WorkoutBlock(name: "", exercises: [exercise], isDefault: true)]
        )
        let program = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: program.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: workout))
        scheduledID = try #require(plan.todayScheduled()).id

        store = WorkoutStore(units: StubUnitSystem(), defaults: try #require(UserDefaults(suiteName: "replace-\(UUID().uuidString)")))
        store.bind(plan.sink(forScheduled: scheduledID), coalesceContent: false)
        store.startWorkout()
    }

    func render() async throws -> ReplaceScreen {
        try await ReplaceScreen(store: store, plan: plan, container: container)
    }
}

/// `WorkoutView` in a scene-attached window; captures composite every visible window.
@MainActor
private final class ReplaceScreen {
    private let window: UIWindow

    init(store: WorkoutStore, plan: PlanStore, container: ModelContainer) async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = WorkoutView()
            .environment(store)
            .environment(plan)
            .environment(BluetoothManager())
            .environment(OnboardingStore(defaults: try #require(UserDefaults(suiteName: "replace-onboarding-\(UUID().uuidString)"))))
            .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        try await settle()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        spin(0.3)
    }

    private var visibleWindows: [UIWindow] {
        (window.windowScene?.windows ?? [window])
            .filter { !$0.isHidden && $0.alpha > 0 }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    func capture(_ name: String) {
        let bounds = window.bounds
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { _ in
            for window in visibleWindows { window.drawHierarchy(in: bounds, afterScreenUpdates: true) }
        }
        guard let data = image.pngData() else { return }
        let url = Self.evidenceDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workout-replace-metrics")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Non-async on purpose: `RunLoop.current` is unavailable from an async context.
    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    func settle(timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            spin(0.1)
            await Task.yield()
        }
        spin(0.2)
    }
}
