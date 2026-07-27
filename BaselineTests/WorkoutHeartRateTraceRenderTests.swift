import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// App-hosted renders of the heart-rate trace chart: on its own, on the completed-workout summary,
/// and on the session log — plus the case that matters most for restraint, a workout with no heart
/// rate at all, which must show no chart and no placeholder. Screenshots go to `evidence/`.
@MainActor
struct WorkoutHeartRateTraceRenderTests {

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The chart itself

    @Test func theTraceChartRendersTheLineZoneBandsAndSummary() async throws {
        let capture = WorkoutHeartRateCapture.previewSession(startingAt: Self.start)
        let screen = try TraceChartScreen(
            capture: capture,
            startedAt: Self.start,
            finishedAt: Self.start.addingTimeInterval(1_800)
        )
        defer { screen.tearDown() }
        try await screen.settle()

        let spoken = try #require(screen.traceLabel)
        #expect(spoken.contains("Heart rate over time"))
        #expect(spoken.contains("beats per minute"))
        #expect(spoken.contains("30:00"))
        // Zone bands, the accent trace, and the surface behind them are all distinct colours.
        #expect(screen.sampledColorCount() > 8)

        try screen.capture("workout-heart-rate-trace-chart")
    }

    /// One reading is not a trend: it renders as a point with the summary, never as a line.
    @Test func aSingleReadingRendersWithoutALine() async throws {
        let capture = WorkoutHeartRateCapture(
            trace: WorkoutHeartRateTrace(points: [
                HeartRateTracePoint(timestamp: Self.start, bpm: 148)
            ]),
            summary: WorkoutHeartRateSummary(
                averageBPM: 148, maxBPM: 148, sampleCount: 1,
                zoneSeconds: [0, 0, 0, 0, 0],
                zoneModel: HeartRateZoneModelSnapshot(HeartRateZoneModel(maxHR: 190, restingHR: 52))
            )
        )
        let screen = try TraceChartScreen(capture: capture, startedAt: Self.start, finishedAt: Self.start)
        defer { screen.tearDown() }
        try await screen.settle()

        let set = WorkoutHeartRateTraceDataSet(capture: capture, startedAt: Self.start, finishedAt: Self.start)
        #expect(set.canPlotLine == false)
        #expect(try #require(screen.traceLabel).contains("average 148 beats per minute"))

        try screen.capture("workout-heart-rate-trace-single-sample")
    }

    // MARK: - The completed-workout summary

    @Test func theCompletedSummaryShowsTheTraceForARecordedWorkout() async throws {
        let screen = try await CompletedSummaryScreen(withHeartRate: true)
        defer { screen.tearDown() }

        #expect(screen.hasLabel(containing: "Heart rate over time"))
        try screen.capture("workout-summary-heart-rate-trace")
    }

    /// No strap, no chart, no placeholder — the summary looks exactly as it did before.
    @Test func theCompletedSummaryShowsNoChartWithoutHeartRate() async throws {
        let screen = try await CompletedSummaryScreen(withHeartRate: false)
        defer { screen.tearDown() }

        #expect(screen.hasLabel(containing: "Heart rate over time") == false)
        #expect(screen.hasLabel(containing: "No heart-rate") == false)
        try screen.capture("workout-summary-heart-rate-absent")
    }

    // MARK: - The session log

    @Test func theSessionLogShowsTheTraceAndMeasuredZoneTime() async throws {
        let screen = try await SessionLogScreen(withHeartRate: true)
        defer { screen.tearDown() }

        #expect(screen.hasLabel(containing: "Heart rate over time"))
        #expect(screen.hasLabel(containing: "HEART RATE ZONES"))
        try screen.capture("workout-detail-heart-rate-trace")
    }

    @Test func theSessionLogShowsNoHeartRateCardWithoutEvidence() async throws {
        let screen = try await SessionLogScreen(withHeartRate: false)
        defer { screen.tearDown() }

        // No recorded trace and no per-set readings ⇒ no heart-rate card at all, no placeholder.
        #expect(screen.hasLabel(containing: "Heart rate over time") == false)
        #expect(screen.hasLabel(containing: "BPM") == false)
        // Zone time the athlete actually logged against a zone-targeted exercise is still measured
        // evidence, so the zones card legitimately stays.
        #expect(screen.hasLabel(containing: "HEART RATE ZONES"))
        try screen.capture("workout-detail-heart-rate-absent")
    }

    /// A planned target zone is intent, not measurement. With nothing logged and nothing recorded
    /// there is no time in zone to show, and the card that used to render the *prescription* as if it
    /// were time spent is gone.
    @Test func theSessionLogNeverRendersPlannedZoneTimeAsMeasured() async throws {
        let screen = try await SessionLogScreen(withHeartRate: false, logSets: false)
        defer { screen.tearDown() }

        #expect(screen.hasLabel(containing: "HEART RATE ZONES") == false)
        #expect(screen.hasLabel(containing: "Heart rate over time") == false)
        try screen.capture("workout-detail-no-measured-zone-time")
    }
}

// MARK: - Screens

@MainActor
private final class TraceChartScreen: HostedScreen {
    let window: UIWindow

    init(capture: WorkoutHeartRateCapture, startedAt: Date?, finishedAt: Date?) throws {
        let root = VStack {
            BaselineCard {
                WorkoutHeartRateTraceChart(capture: capture, startedAt: startedAt, finishedAt: finishedAt)
            }
            Spacer()
        }
        .padding(BaselineSpacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BaselineColor.base)
        .preferredColorScheme(.dark)

        window = try Self.makeWindow(rootView: root)
    }

    var traceLabel: String? {
        AccessibilityElementWalker.elements(in: window)
            .compactMap(\.accessibilityLabel)
            .first { $0.contains("Heart rate over time") }
    }

    /// Distinct sampled colours — a proxy for "the chart actually drew something", matching the
    /// live-HUD render tests.
    func sampledColorCount() -> Int {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let source = image.cgImage else { return 0 }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return 0 }

        var colors = Set<UInt32>()
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let offset = (y * width + x) * 4
                colors.insert(
                    UInt32(pixels[offset]) << 24 | UInt32(pixels[offset + 1]) << 16
                        | UInt32(pixels[offset + 2]) << 8 | UInt32(pixels[offset + 3])
                )
            }
        }
        return colors.count
    }
}

/// `WorkoutView` in `.completed` mode, reached the way the athlete reaches it: a real plan-bound
/// session that is started, logged, and finished with (or without) a captured trace.
@MainActor
private final class CompletedSummaryScreen: HostedScreen {
    let window: UIWindow
    private let suiteName: String
    private let defaults: UserDefaults

    init(withHeartRate: Bool) async throws {
        suiteName = "WorkoutHeartRateTraceRenderTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plan = PlanStore(context: container.mainContext)
        let scheduled = plan.newScheduledWorkout(on: Date(), workout: WorkoutHeartRateFixtures.workout())

        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        store.startWorkout()
        WorkoutHeartRateFixtures.logEverything(in: store)
        WorkoutFinishCoordinator().finish(
            store,
            heartRate: withHeartRate ? .previewSession(startingAt: Date().addingTimeInterval(-1_800)) : nil
        )

        let root = WorkoutView()
            .environment(store)
            .environment(plan)
            .environment(BluetoothManager())
            .environment(OnboardingStore(defaults: defaults))
            .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 35 }))
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = try Self.makeWindow(rootView: root)
        try await settleUntil { self.hasLabel(containing: WorkoutHeartRateFixtures.title) }
        try await settle()
    }

    /// Shadows the protocol's window teardown to also drop this screen's scratch defaults suite.
    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    func hasLabel(containing text: String) -> Bool {
        AccessibilityElementWalker.elements(in: window).contains {
            $0.accessibilityLabel?.contains(text) ?? false
        }
    }
}

/// `WorkoutDetailView` — the history surface reached from Plan — over a completed session.
@MainActor
private final class SessionLogScreen: HostedScreen {
    let window: UIWindow
    private let suiteName: String
    private let defaults: UserDefaults

    init(withHeartRate: Bool, logSets: Bool = true) async throws {
        suiteName = "WorkoutHeartRateTraceRenderTests.detail.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plan = PlanStore(context: container.mainContext)
        let scheduled = plan.newScheduledWorkout(on: Date(), workout: WorkoutHeartRateFixtures.workout())

        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        store.startWorkout()
        if logSets { WorkoutHeartRateFixtures.logEverything(in: store) }
        WorkoutFinishCoordinator().finish(
            store,
            heartRate: withHeartRate ? .previewSession(startingAt: Date().addingTimeInterval(-1_800)) : nil
        )
        store.unbind()
        plan.reload()

        let root = WorkoutDetailView(scheduledWorkoutID: scheduled.id)
            .environment(AppSettings(defaults: defaults))
            .environment(plan)
            .environment(store)
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = try Self.makeWindow(rootView: root)
        try await settleUntil { self.hasLabel(containing: WorkoutHeartRateFixtures.title) }
        try await settle()
    }

    /// Shadows the protocol's window teardown to also drop this screen's scratch defaults suite.
    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    func hasLabel(containing text: String) -> Bool {
        AccessibilityElementWalker.elements(in: window).contains {
            $0.accessibilityLabel?.contains(text) ?? false
        }
    }
}

// MARK: - Fixtures

@MainActor
private enum WorkoutHeartRateFixtures {
    static let title = "Zone 2 Intervals"

    /// A zone-targeted cardio workout, so the detail screen's zone card has something to resolve —
    /// measured when a trace exists, and nothing at all when it does not.
    static func workout() -> Workout {
        var run = PlannedExercise(
            exerciseName: "Run",
            definitionId: "run",
            selectedMetrics: [.duration, .distance],
            prescription: Prescription(
                sets: [
                    PlannedSet(duration: 600, distance: 2_000),
                    PlannedSet(duration: 600, distance: 2_000),
                ],
                targetZone: 3
            )
        )
        run.guidance = CoachGuidance(formCues: ["Hold an easy conversational pace."])
        return Workout(
            title: title,
            goal: "Aerobic base",
            blocks: [WorkoutBlock(name: "", exercises: [run], isDefault: true)]
        )
    }

    static func logEverything(in store: WorkoutStore) {
        guard let workout = store.current else { return }
        store.editLog { log in
            for exercise in workout.allExercises {
                for set in exercise.prescription.sets {
                    log.upsertSetLog(
                        forPlanned: exercise.id,
                        name: exercise.exerciseName,
                        plannedSetID: set.id
                    ) { actual in
                        actual.values = set.expectedValues(iteration: 1)
                        actual.outcome = .completed
                    }
                }
                log.setStatus(.completed, forPlanned: exercise.id, name: exercise.exerciseName)
            }
        }
    }
}
