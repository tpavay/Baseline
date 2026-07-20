import SwiftUI
import SwiftData
import Testing
import UIKit
@testable import Baseline

/// Renders the two net-new in-workout editing surfaces in a scene-attached window so they can be
/// looked at, not only asserted about: the drag-reorder sheet and the prescription editor.
///
/// Both are `List`-based, which `ImageRenderer` cannot rasterize, so they go through a real `UIWindow`
/// and `drawHierarchy` exactly as the other render suites in this bundle do.
@MainActor
struct WorkoutEditingRenderTests {

    @Test func reorderSheetShowsBlocksWithTheirExerciseCounts() async throws {
        let screen = try await EditingScreen(blocks: true) { WorkoutReorderSheet() }
        defer { screen.tearDown() }

        // Multi-block workouts land on the block list, where blocks reorder and exercises live one
        // level down — the structure that makes a cross-block exercise drag impossible.
        #expect(screen.element(labelled: "Strength") != nil)
        #expect(screen.element(labelled: "Accessory") != nil)
        screen.capture("01-reorder-blocks")
    }

    @Test func tappingABlockOpensItsExerciseList() async throws {
        // The block list is permanently in edit mode so blocks can be dragged, which is exactly what
        // makes a plain `NavigationLink` row unselectable. Tap the real row and prove it still opens —
        // without this, the two-level design is unreachable for every multi-block workout.
        let screen = try await EditingScreen(blocks: true) { WorkoutReorderSheet() }
        defer { screen.tearDown() }

        #expect(screen.element(labelled: "Curl") == nil)
        let row = try #require(screen.element(labelled: "Accessory"))
        #expect(row.accessibilityActivate())
        try await screen.settle()

        #expect(screen.element(labelled: "Curl") != nil)
        screen.capture("04-reorder-exercises-within-a-block")
    }

    @Test func reorderSheetGoesStraightToExercisesForASingleBlockWorkout() async throws {
        let screen = try await EditingScreen(blocks: false) { WorkoutReorderSheet() }
        defer { screen.tearDown() }

        // One block means nothing to reorder at the block level, so the athlete should not have to
        // tap through a one-row list to reach the exercises.
        #expect(screen.element(labelled: "Squat") != nil)
        #expect(screen.element(labelled: "Bench press") != nil)
        screen.capture("02-reorder-exercises-single-block")
    }

    @Test func prescriptionSheetShowsAnEditableRowPerPlannedSet() async throws {
        let store = try await EditingScreen.makeStore(multipleBlocks: false)
        let exerciseID = try #require(store.current?.allExercises.first?.id)
        let screen = try await EditingScreen(store: store) { EditPrescriptionSheet(exerciseID: exerciseID) }
        defer { screen.tearDown() }

        #expect(screen.element(labelled: "Add Set") != nil)
        screen.capture("03-edit-prescription")
    }
}

// MARK: - Harness

@MainActor
private final class EditingScreen {
    private let window: UIWindow
    private static var retainedContainers: [ModelContainer] = []
    private static var retainedPlans: [PlanStore] = []
    let store: WorkoutStore

    /// A started session so the surfaces render in the state they actually ship in — mid-workout,
    /// where every edit is session-scoped.
    static func makeStore(multipleBlocks: Bool) async throws -> WorkoutStore {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(for: Schema(models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        retainedContainers.append(container)
        let plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))
        retainedPlans.append(plan)

        func exercise(_ name: String, sets: Int) -> PlannedExercise {
            var ex = PlannedExercise(exerciseName: name, definitionId: "deadlift")
            ex.prescription.sets = (0..<sets).map { _ in PlannedSet(reps: 5, load: 100) }
            return ex
        }

        var workout = Workout(
            title: "Lower body",
            blocks: [WorkoutBlock(name: multipleBlocks ? "Strength" : "",
                                  exercises: [exercise("Squat", sets: 3), exercise("Bench press", sets: 3)],
                                  isDefault: !multipleBlocks)]
        )
        if multipleBlocks {
            workout.blocks.append(WorkoutBlock(name: "Accessory",
                                               exercises: [exercise("Curl", sets: 2)],
                                               isDefault: false))
        }

        let program = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: program.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: workout))
        let scheduled = try #require(plan.todayScheduled())
        let store = WorkoutStore(defaults: try #require(UserDefaults(suiteName: "render-\(UUID().uuidString)")))
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        store.startWorkout()
        return store
    }

    convenience init<Content: View>(blocks multipleBlocks: Bool, @ViewBuilder content: () -> Content) async throws {
        try await self.init(store: try await Self.makeStore(multipleBlocks: multipleBlocks), content: content)
    }

    init<Content: View>(store: WorkoutStore, @ViewBuilder content: () -> Content) async throws {
        self.store = store
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = content()
            .environment(store)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        try await settle()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func element(labelled text: String) -> NSObject? {
        Self.elements(in: window).first { $0.accessibilityLabel?.contains(text) ?? false }
    }

    func capture(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return }
        let url = Self.evidenceDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workout-editing")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Non-async on purpose: `RunLoop.current` is unavailable from an async context.
    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    func settle(timeout: TimeInterval = 3) async throws {
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
