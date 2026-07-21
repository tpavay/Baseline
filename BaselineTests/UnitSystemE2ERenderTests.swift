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
/// Hosted in a scene-attached window: sign-in gates a plain launch, `ImageRenderer` cannot rasterize
/// the `ScrollView` this screen is made of, and an unattached window renders blank.
@Suite(.serialized) @MainActor
struct UnitSystemE2ERenderTests {

    @Test(arguments: [
        (UnitSystem.imperial, "mi", "lb"),
        (UnitSystem.metric, "km", "kg"),
    ])
    func todaysWorkoutOpenedFromPlanIsShownInTheAthletesUnits(
        system: UnitSystem, distanceUnit: String, loadUnit: String
    ) async throws {
        let bed = try Bed(system: system)
        defer { bed.tearDown() }

        try await bed.openTodaysWorkout()
        bed.capture("units-\(system.rawValue)-workout")

        // The set cells announce their unit (the visual column header is accessibility-hidden
        // precisely because each cell carries it), so this reads the unit the athlete is shown.
        #expect(bed.cell("Distance") == "Set 1, Distance, \(distanceUnit)")
        #expect(bed.cell("Load") == "Set 1, Load, \(loadUnit)")

        // The other system's units must be nowhere on screen — a half-converted table is worse than
        // a consistently wrong one.
        let wrong = system == .imperial ? ["km", "kg"] : ["mi", "lb"]
        let text = bed.visibleText
        for token in wrong {
            #expect(!text.contains(", \(token)"), "\(token) is still on screen under \(system.rawValue)")
        }
    }

    /// The store the sheet runs on must be the athlete's, not a fresh one that fell back to a default.
    @Test func theExecutionStoreCarriesTheAthletesUnitSystem() async throws {
        let bed = try Bed(system: .imperial)
        defer { bed.tearDown() }
        try await bed.openTodaysWorkout()

        #expect(bed.cell("Distance") == "Set 1, Distance, mi")
        bed.settings.unitSystem = .metric
        try await bed.settle()
        #expect(bed.cell("Distance") == "Set 1, Distance, km",
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

        // 121 m and 100 kg, stored canonically exactly as the repository holds them.
        var sled = PlannedExercise(exerciseName: "Sled Push", definitionId: "sled_push",
                                   selectedMetrics: [.distance, .load])
        sled.prescription.sets = [PlannedSet(values: MetricValues([.distance: 121, .load: 100]))]
        let workout = Workout(title: "Conditioning",
                              blocks: [WorkoutBlock(name: "", exercises: [sled], isDefault: true)])
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
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
    }

    func openTodaysWorkout() async throws {
        try await settle()
        let card = try #require(element(labelled: "Conditioning"), "today's workout card is not on the Plan tab")
        #expect(card.accessibilityActivate())
        try await settle()
        #expect(element(labelled: "Sled Push") != nil, "the workout sheet did not open")
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

    /// A set cell's spoken label for the named metric, which is where the unit lives. (The cell's
    /// accessibility *value* is the row's completion state, not the number — a separate a11y gap.)
    func cell(_ metric: String) -> String? {
        elements.first { $0.accessibilityLabel?.contains(", \(metric), ") ?? false }?.accessibilityLabel
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
