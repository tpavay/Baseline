import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

@MainActor
struct TaxonomyScreenRenderTests {
    @Test func profileMatchesApprovedPresentation() throws {
        let fixture = try ScreenFixture()
        let harness = try TaxonomyScreenRenderHarness(root: fixture.mainTabs(selection: .profile))
        defer { harness.tearDown() }

        harness.capture(named: "profile")
    }

    @Test func detailMatchesApprovedPresentation() throws {
        let fixture = try ScreenFixture()
        let harness = try TaxonomyScreenRenderHarness(
            root: WorkoutDetailView(scheduledWorkoutID: fixture.detailWorkout.id)
                .environment(fixture.settings)
                .environment(fixture.plan)
                .environment(fixture.workouts)
                .modelContainer(fixture.container)
                .preferredColorScheme(.dark)
        )
        defer { harness.tearDown() }

        harness.capture(named: "detail")
    }

    @Test func calendarMatchesApprovedPresentation() throws {
        let fixture = try ScreenFixture()
        let harness = try TaxonomyScreenRenderHarness(root: fixture.mainTabs(selection: .plan))
        defer { harness.tearDown() }

        harness.capture(named: "calendar")
    }
}

@MainActor
private final class ScreenFixture {
    let container: ModelContainer
    let settings = AppSettings(defaults: UserDefaults(suiteName: "taxonomy-screen-settings") ?? .standard)
    let plan: PlanStore
    let workouts: WorkoutStore
    let detailWorkout: ScheduledWorkout

    private let auth = AuthViewModel()
    private let bluetooth = BluetoothManager()
    private let health = HealthService()
    private let context = TrainingContextStore()
    private let onboarding: OnboardingStore

    init() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models + SleepSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        plan = PlanStore(context: container.mainContext)
        workouts = WorkoutStore(units: settings, defaults: UserDefaults(suiteName: "taxonomy-screen-workouts") ?? .standard)
        onboarding = OnboardingStore(defaults: UserDefaults(suiteName: "taxonomy-screen-onboarding") ?? .standard)
        onboarding.draft.name = "Tyler Pavay"

        let calendar = Calendar.planWeek
        let today = calendar.startOfDay(for: Date())
        let detailed = Self.detailedWorkout()
        detailWorkout = plan.newScheduledWorkout(on: today, workout: detailed)
        Self.complete(detailWorkout, workout: detailed, in: plan)

        var aerobic = detailed
        aerobic.id = UUID()
        aerobic.title = "Aerobic Capacity #1"
        aerobic.goal = "Run + strength"
        _ = plan.newScheduledWorkout(
            on: calendar.date(byAdding: .day, value: -2, to: today) ?? today,
            workout: aerobic
        )

        var bike = Self.cardioWorkout()
        bike.title = "Zone 2 Bike"
        _ = plan.newScheduledWorkout(
            on: calendar.date(byAdding: .day, value: -4, to: today) ?? today,
            workout: bike
        )

        var push = detailed
        push.id = UUID()
        push.title = "Push A - Heavy"
        push.goal = "Bench · OHP · dips"
        _ = plan.newScheduledWorkout(
            on: calendar.date(byAdding: .day, value: -6, to: today) ?? today,
            workout: push
        )
    }

    func mainTabs(selection: MainTab) -> some View {
        MainTabView(initialSelection: selection)
            .environment(auth)
            .environment(settings)
            .environment(bluetooth)
            .environment(health)
            .environment(context)
            .environment(onboarding)
            .environment(workouts)
            .environment(plan)
            .modelContainer(container)
            .preferredColorScheme(.dark)
    }

    private static func detailedWorkout() -> Workout {
        let bike = exercise(
            name: "Stationary Bike",
            definitionID: "stationary_bike",
            metrics: [.duration, .power, .calories, .heartRate],
            targetZone: 4,
            values: [
                [.duration: 30, .power: 142, .calories: 9, .heartRate: 148],
                [.duration: 30, .power: 139, .calories: 9, .heartRate: 156],
                [.duration: 30, .power: 144, .calories: 10, .heartRate: 163],
                [.duration: 30, .power: 136, .calories: 8, .heartRate: 151],
                [.duration: 30, .power: 148, .calories: 10, .heartRate: 171]
            ]
        )
        let sledPush = exercise(
            name: "Sled Push",
            definitionID: "sled_push",
            metrics: [.load, .distance, .duration, .heartRate],
            targetZone: 4,
            values: [
                [.load: 41, .distance: 20, .duration: 22, .heartRate: 175],
                [.load: 41, .distance: 20, .duration: 23, .heartRate: 181],
                [.load: 41, .distance: 20, .duration: 24, .heartRate: 169],
                [.load: 41, .distance: 20, .duration: 26, .heartRate: 164]
            ]
        )
        let sledPull = exercise(
            name: "Sled Pull",
            definitionID: "sled_pull",
            metrics: [.load, .distance, .duration],
            targetZone: 3,
            values: [
                [.load: 32, .distance: 20, .duration: 19],
                [.load: 32, .distance: 20, .duration: 20],
                [.load: 32, .distance: 20, .duration: 21],
                [.load: 32, .distance: 20, .duration: 23]
            ]
        )
        let wallBalls = exercise(
            name: "Wall Balls",
            definitionID: "wall_balls",
            metrics: [.load, .reps, .rpe],
            targetZone: 3,
            values: [
                [.load: 9, .reps: 15, .rpe: 7],
                [.load: 9, .reps: 15, .rpe: 7],
                [.load: 9, .reps: 15, .rpe: 8],
                [.load: 9, .reps: 13, .rpe: 9]
            ]
        )
        let pullUp = exercise(
            name: "Pull-Up",
            definitionID: "pull_up",
            metrics: [.reps, .rpe],
            targetZone: 2,
            values: [
                [.reps: 8, .rpe: 7],
                [.reps: 8, .rpe: 8],
                [.reps: 7, .rpe: 9],
                [.reps: 6, .rpe: 9]
            ]
        )

        return Workout(
            title: "Intensity - Block 12",
            goal: "Intervals · sled",
            blocks: [WorkoutBlock(name: "Main", exercises: [bike, sledPush, sledPull, wallBalls, pullUp])]
        )
    }

    private static func cardioWorkout() -> Workout {
        Workout(
            title: "Zone 2 Bike",
            goal: "Cardio",
            blocks: [
                WorkoutBlock(
                    name: "Main",
                    exercises: [
                        exercise(
                            name: "Stationary Bike",
                            definitionID: "stationary_bike",
                            metrics: [.duration, .heartRate],
                            targetZone: 2,
                            values: [[.duration: 2_700, .heartRate: 134]]
                        )
                    ]
                )
            ]
        )
    }

    private static func exercise(
        name: String,
        definitionID: String,
        metrics: [MetricType],
        targetZone: Int,
        values: [[MetricType: Double]]
    ) -> PlannedExercise {
        PlannedExercise(
            exerciseName: name,
            definitionId: definitionID,
            selectedMetrics: metrics,
            prescription: Prescription(
                sets: values.map { PlannedSet(values: MetricValues($0)) },
                targetZone: targetZone
            )
        )
    }

    private static func complete(_ scheduled: ScheduledWorkout, workout: Workout, in plan: PlanStore) {
        _ = plan.start(scheduled.id)
        var log = workout.startLog()
        for index in log.exercises.indices {
            guard let plannedID = log.exercises[index].plannedExerciseID,
                  let planned = workout.exercise(plannedID)
            else { continue }
            log.exercises[index].status = .completed
            log.exercises[index].setLogs = planned.prescription.sets.map { set in
                SetLog(plannedSetID: set.id, values: set.values, outcome: .completed)
            }
        }
        log.isComplete = true
        plan.updateSessionLog(scheduled.id) { $0 = log }
        _ = plan.complete(scheduled.id, acknowledgingOpenWork: true)
    }
}

@MainActor
private final class TaxonomyScreenRenderHarness {
    private let window: UIWindow

    init<Content: View>(root: Content) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "The screenshot test must run in the app-hosted test bundle."
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        settle()
    }

    func tearDown() {
        window.resignKey()
        window.isHidden = true
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        window.rootViewController = nil
    }

    func capture(named name: String) {
        settle()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        #expect(image.size == CGSize(width: 393, height: 852))
        guard let data = image.pngData() else {
            Issue.record("Could not encode \(name) screenshot")
            return
        }

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("evidence", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        } catch {
            Issue.record("Could not write \(name) screenshot: \(error)")
        }
    }

    private func settle() {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.35))
        window.layoutIfNeeded()
    }
}
