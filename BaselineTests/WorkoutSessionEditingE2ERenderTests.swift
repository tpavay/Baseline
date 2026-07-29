import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

extension IdleTimerRenderTests {
    /// Drives the whole in-workout editing story through the real `WorkoutView`, the way an athlete
    /// lives it: start today's scheduled workout, restructure it mid-session (true-remove, add,
    /// reorder), finish, and answer the "Update your plan?" opt-in. The saved plan is read back at
    /// every step, so the session-scoping claim is checked against the plan the athlete would open
    /// tomorrow rather than against store internals. Each step also writes a PNG of the surface.
    ///
    /// Hosted in a scene-attached window because sign-in gates a plain launch and an unattached
    /// window renders blank. Alerts are presented in their own windows, so the harness looks at - and
    /// captures - every window in the scene.
    ///
    /// Serialized: each test drives a modal alert on the shared scene, and overlapping presentations
    /// from a parallel peer wedge UIKit's presentation machinery.
    @Suite(.serialized) @MainActor
    struct WorkoutSessionEditingE2ERenderTests {

        @Test func sessionEditsReachThePlanOnlyWhenTheAthleteAccepts() async throws {
            let bed = try SessionBed()
            let screen = try await bed.render()
            defer { screen.tearDown() }

            #expect(bed.planExerciseNames == ["Squat", "Bench press", "Curl"])
            screen.capture("10-live-session-as-planned")

            try await bed.editMidSession(on: screen)
            screen.capture("11-live-session-after-edits")

            // The whole point: the athlete has restructured today's execution and the saved plan has not
            // moved at all.
            #expect(bed.sessionExerciseNames == ["Curl", "Squat", "Face pull"])
            #expect(bed.planExerciseNames == ["Squat", "Bench press", "Curl"])

            try await screen.tap("Finish")
            screen.capture("12-finish-review")
            try await screen.tap("Save workout")

            #expect(screen.element(labelled: "Update your plan?") != nil)
            screen.capture("13-update-your-plan-prompt")

            try await screen.tapAlertButton("Update Plan")
            // Accepting is the one path that writes a mid-workout edit into the plan.
            #expect(bed.planExerciseNames == ["Curl", "Squat", "Face pull"])
            screen.capture("14-plan-updated-summary")
        }

        @Test func keepingTheOriginalLeavesTheSavedPlanUntouched() async throws {
            let bed = try SessionBed()
            let screen = try await bed.render()
            defer { screen.tearDown() }

            try await bed.editMidSession(on: screen)
            try await screen.tap("Finish")
            try await screen.tap("Save workout")
            #expect(screen.element(labelled: "Update your plan?") != nil)

            try await screen.tapAlertButton("Keep Original")
            #expect(bed.planExerciseNames == ["Squat", "Bench press", "Curl"])
            screen.capture("15-kept-original-plan")
        }

        /// Logging different actuals is a performed fact, not a plan change, so finishing shows no prompt.
        @Test func loggingDifferentActualsShowsNoPrompt() async throws {
            let bed = try SessionBed()
            let screen = try await bed.render()
            defer { screen.tearDown() }

            let squat = try #require(bed.store.current?.allExercises.first)
            let setID = try #require(squat.prescription.sets.first?.id)
            bed.store.editLog { log in
                log.upsertSetLog(forPlanned: squat.id, name: squat.exerciseName, plannedSetID: setID) { set in
                    set.values[.load] = 180
                    set.completed = true
                }
            }
            try await screen.settle()

            try await screen.tap("Finish")
            try await screen.tap("Save workout")
            #expect(screen.element(labelled: "Update your plan?") == nil)
            #expect(bed.planExerciseNames == ["Squat", "Bench press", "Curl"])
            screen.capture("16-no-prompt-for-logged-actuals")
        }
    }
}

// MARK: - Harness

/// Today's scheduled workout in a real plan store, bound to a `WorkoutStore` and already started.
@MainActor
private final class SessionBed {
    let plan: PlanStore
    let store: WorkoutStore
    private let container: ModelContainer
    private let scheduledID: UUID

    init() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(for: Schema(models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))

        func exercise(_ name: String) -> PlannedExercise {
            var ex = PlannedExercise(exerciseName: name, definitionId: "deadlift")
            ex.prescription.sets = (0..<3).map { _ in PlannedSet(reps: 5, load: 100) }
            return ex
        }
        let workout = Workout(
            title: "Lower body",
            blocks: [WorkoutBlock(name: "",
                                  exercises: [exercise("Squat"), exercise("Bench press"), exercise("Curl")],
                                  isDefault: true)]
        )
        let program = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: program.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: workout))
        scheduledID = try #require(plan.todayScheduled()).id

        store = WorkoutStore(units: StubUnitSystem(), defaults: try #require(UserDefaults(suiteName: "e2e-\(UUID().uuidString)")))
        store.bind(plan.sink(forScheduled: scheduledID), coalesceContent: false)
        store.startWorkout()
    }

    /// The workout the athlete would open tomorrow.
    var planExerciseNames: [String] {
        plan.scheduledWorkout(scheduledID)?.workout.allExercises.map(\.exerciseName) ?? []
    }

    var sessionExerciseNames: [String] {
        store.current?.allExercises.map(\.exerciseName) ?? []
    }

    func render() async throws -> Screen {
        try await Screen(store: store, plan: plan, container: container)
    }

    /// The three structural edits under test, applied through the same store calls the sheets and
    /// menus make: true-remove, add, and a within-block reorder.
    func editMidSession(on screen: Screen) async throws {
        let bench = try #require(store.current?.allExercises.first { $0.exerciseName == "Bench press" })
        store.removeExerciseFromWorkout(bench.id, scope: .session)

        let blockID = try #require(store.current?.blocks.first?.id)
        var added = PlannedExercise(exerciseName: "Face pull", definitionId: "deadlift")
        added.prescription.sets = (0..<2).map { _ in PlannedSet(reps: 12, load: 20) }
        store.addExercise(added, toBlockID: blockID, scope: .session)

        // Curl to the front, exactly what a drag in WorkoutReorderSheet does.
        _ = store.edit(.session) { $0.moveNodes(inBlock: blockID, fromOffsets: IndexSet(integer: 1), toOffset: 0) }
        try await screen.settle()
    }
}

/// `WorkoutView` in a scene-attached window, driven by activating real accessibility elements.
@MainActor
private final class Screen: HostedScreen {
    let window: UIWindow

    init(store: WorkoutStore, plan: PlanStore, container: ModelContainer) async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = WorkoutView()
            .environment(store)
            .environment(plan)
            .environment(BluetoothManager())
            .environment(OnboardingStore(defaults: try #require(UserDefaults(suiteName: "e2e-onboarding-\(UUID().uuidString)"))))
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

    /// Alerts live in their own window, so search the whole scene rather than just ours. Back to front
    /// by window level, so a capture composites the alert *over* the opaque app window.
    private var visibleWindows: [UIWindow] {
        (window.windowScene?.windows ?? [window])
            .filter { !$0.isHidden && $0.alpha > 0 }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    func element(labelled text: String) -> NSObject? {
        visibleWindows.reversed().lazy
            .flatMap { Self.elements(in: $0) }
            .first { $0.accessibilityLabel?.contains(text) ?? false }
    }

    func tap(_ label: String) async throws {
        let target = try #require(element(labelled: label), "No element labelled \"\(label)\" on screen.")
        #expect(target.accessibilityActivate(), "\"\(label)\" did not activate.")
        try await settle()
    }

    func capture(_ name: String) {
        // A system alert's blur does not survive an offscreen render, so when the harness is asked to
        // hold, it parks on the live screen long enough for a real device screenshot to be taken.
        if Self.holdSeconds > 0 {
            print("HOLD \(name)")
            spin(Self.holdSeconds)
        }
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

    private static let holdSeconds: TimeInterval =
        ProcessInfo.processInfo.environment["BASELINE_CAPTURE_HOLD"].flatMap(Double.init) ?? 0

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workout-session-editing")
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

    private static func elements(in root: UIView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                if view.isAccessibilityElement { out.append(view) }
                (view.accessibilityElements as? [NSObject])?.forEach(walk)
                view.subviews.forEach(walk)
            } else {
                out.append(object)
                let count = object.accessibilityElementCount()
                guard count != NSNotFound, count > 0 else { return }
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { walk(child) }
                }
            }
        }
        walk(root)
        return out
    }
}
