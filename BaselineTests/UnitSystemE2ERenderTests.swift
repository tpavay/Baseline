import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The reported bug, driven the way the athlete hits it: choose a unit system, open the Plan tab,
/// tap today's workout, and read the set table. Before the fix this rendered `KM` / `KG` whatever the
/// setting said, because `PlanView` built its execution `WorkoutStore` without the athlete's unit
/// system and that store shadows the app-wide one inside the sheet.
///
/// The workout is a sled push and a run together, because that is the case the approved design
/// turns on: on one screen an imperial athlete reads **lb** for load, **m** for the sled, and **mi**
/// for the run — three different answers that all come from one resolver.
///
/// Hosted in a scene-attached window: sign-in gates a plain launch, `ImageRenderer` cannot rasterize
/// the `ScrollView` this screen is made of, and an unattached window renders blank.
@Suite(.serialized) @MainActor
struct UnitSystemE2ERenderTests {

    @Test(arguments: [
        (UnitSystem.imperial, "lb", "mi"),
        (UnitSystem.metric, "kg", "km"),
    ])
    func todaysWorkoutOpenedFromPlanIsShownInTheAthletesUnits(
        system: UnitSystem, loadUnit: String, enduranceUnit: String
    ) async throws {
        let bed = try Bed(system: system)
        defer { bed.tearDown() }

        try await bed.openTodaysWorkout()
        bed.capture("units-\(system.rawValue)-workout")

        // The set cells announce their unit (the visual column header is accessibility-hidden
        // precisely because each cell carries it), so this reads the unit the athlete is shown.
        #expect(bed.cell("Sled Push", "Load") == "Set 1, Load, \(loadUnit)")
        // Floor work: meters in both systems, on the same screen as an imperial load.
        #expect(bed.cell("Sled Push", "Distance") == "Set 1, Distance, m")
        // Endurance work on the very same screen follows the athlete's system.
        #expect(bed.cell("Run", "Distance") == "Set 1, Distance, \(enduranceUnit)")

        // The other system's load unit must be nowhere on screen — a half-converted table is worse
        // than a consistently wrong one.
        let wrongLoad = system == .imperial ? "kg" : "lb"
        #expect(!bed.visibleText.contains(", \(wrongLoad)"),
                "\(wrongLoad) is still on screen under \(system.rawValue)")
    }

    /// The store the sheet runs on must be the athlete's, not a fresh one that fell back to a default.
    @Test func theExecutionStoreCarriesTheAthletesUnitSystem() async throws {
        let bed = try Bed(system: .imperial)
        defer { bed.tearDown() }
        try await bed.openTodaysWorkout()

        #expect(bed.cell("Run", "Distance") == "Set 1, Distance, mi")
        bed.settings.unitSystem = .metric
        try await bed.settle()
        #expect(bed.cell("Run", "Distance") == "Set 1, Distance, km",
                "changing the setting did not reach the already-open workout")
    }
}

// MARK: - Harness

@MainActor
private final class Bed {
    let settings: AppSettings
    private let window: UIWindow
    private static var retained: [Any] = []

    init(system: UnitSystem) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "units-e2e-\(UUID().uuidString)")))
        settings.unitSystem = system

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(for: Schema(models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))
        Self.retained.append(contentsOf: [container, plan])

        // Stored canonically exactly as the repository holds them: a 20 m sled at 100 kg, and a
        // 5 km run. Both distances, one canonical unit, two different right answers on screen.
        var sled = PlannedExercise(exerciseName: "Sled Push", definitionId: "sled_push",
                                   selectedMetrics: [.distance, .load])
        sled.prescription.sets = [PlannedSet(values: MetricValues([.distance: 20, .load: 100]))]
        var run = PlannedExercise(exerciseName: "Run", definitionId: "run", selectedMetrics: [.distance])
        run.prescription.sets = [PlannedSet(values: MetricValues([.distance: 5_000]))]
        let workout = Workout(title: "Conditioning",
                              blocks: [WorkoutBlock(name: "", exercises: [sled, run], isDefault: true)])
        let program = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: program.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: workout))

        let root = PlanView()
            .environment(plan)
            .environment(WorkoutStore(units: settings,
                                      defaults: try #require(UserDefaults(suiteName: "units-e2e-app-\(UUID().uuidString)"))))
            .environment(settings)
            .environment(BluetoothManager())
            .environment(OnboardingStore(defaults: try #require(UserDefaults(suiteName: "units-e2e-ob-\(UUID().uuidString)"))))
            // `PlanView` starts the session in `WorkoutView`, which reads the shared zone store; a
            // throwaway suite keeps this harness off the athlete's real config.
            .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
    }

    func openTodaysWorkout() async throws {
        try await settle()
        let card = try #require(element(labelled: "Conditioning"), "today's workout card is not on the Plan tab")
        // Tapping the calendar row opens the read-only detail screen; starting the session lives in
        // the row's menu, mirrored as the row's "Start workout" accessibility custom action.
        let start = try #require(
            (card.accessibilityCustomActions ?? []).first { $0.name.localizedCaseInsensitiveContains("start") },
            "the session row does not expose its start action"
        )
        #expect(perform(start))
        try await settle()
        #expect(cell("Sled Push", "Load") != nil, "the workout execution sheet did not open")
    }

    private func perform(_ action: UIAccessibilityCustomAction) -> Bool {
        if let handler = action.actionHandler { return handler(action) }
        guard let target = action.target else { return false }
        return (target.perform(action.selector, with: action) != nil)
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        spin(0.2)
    }

    /// Everything rendered anywhere in the scene. SwiftUI draws `Text` into layers rather than
    /// `UILabel`s, so the column headers only exist as synthesised accessibility elements — which are
    /// plain `NSObject`s hanging off `accessibilityElements`, not views. `elements` walks both.
    var visibleText: String {
        elements.flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }
            .joined(separator: "\n")
    }

    /// A set cell's spoken label for a metric under the named exercise, which is where the unit
    /// lives. Cells are in document order after their exercise heading, so the search starts there —
    /// two exercises on this screen carry a Distance cell each, and they must not be confused.
    /// (The cell's accessibility *value* is the row's completion state, not the number — a separate
    /// a11y gap, untouched here.)
    func cell(_ exercise: String, _ metric: String) -> String? {
        let all = elements
        guard let start = all.firstIndex(where: { $0.accessibilityLabel == exercise }) else { return nil }
        return all[start...]
            .first { $0.accessibilityLabel?.contains(", \(metric), ") ?? false }?
            .accessibilityLabel
    }

    func capture(_ name: String) {
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            visibleWindows.forEach { $0.drawHierarchy(in: bounds, afterScreenUpdates: true) }
        }
        guard let data = image.pngData() else { return }
        let url = Self.evidenceDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unit-system")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private var visibleWindows: [UIWindow] {
        (window.windowScene?.windows ?? [window])
            .filter { !$0.isHidden && $0.alpha > 0 }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    private func element(labelled text: String) -> NSObject? {
        elements.first { $0.accessibilityLabel?.contains(text) ?? false }
    }

    private var elements: [NSObject] {
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
        visibleWindows.reversed().forEach(walk)
        return out
    }

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
