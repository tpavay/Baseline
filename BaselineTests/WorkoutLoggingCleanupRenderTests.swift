import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

@Suite(.serialized)
@MainActor
struct WorkoutLoggingCleanupRenderTests {
    @Test func rowingPaceOffersFiveHundredMeterUnit() {
        #expect(MetricType.pace.displayUnits.map(\.short).contains("/500m"))
    }

    @Test func rowingUnitPickerShowsFiveHundredMeterPace() async throws {
        let screen = try await RowingUnitPickerScreen()
        defer { screen.tearDown() }

        #expect(screen.hasLabel(containing: "/500m"))
        #expect(screen.hasLabel(containing: "/km"))
        #expect(screen.hasLabel(containing: "/mi"))
        try screen.capture("rowing-pace-500m")
    }

    @Test func activeLoggingHeaderShowsTitleWithoutInProgressStatus() async throws {
        let screen = try await LoggingCleanupScreen()
        defer { screen.tearDown() }

        #expect(screen.hasLabel(containing: "Tempo Row"))
        #expect(screen.hasLabel(containing: "In progress") == false)
        try screen.capture("logging-header-without-in-progress")
        #expect(screen.hasLabel(containing: "/500m"))
    }

    @Test func finishDurationCanBeEditedAndPersistsThroughHistoryAndSharing() async throws {
        let screen = try await LoggingCleanupScreen()
        defer { screen.tearDown() }

        #expect(screen.activate(labelled: "Finish"))
        try await screen.settle()

        #expect(screen.hasLabel(containing: "Save workout"))
        #expect(screen.hasLabel(containing: "Edit workout duration"))
        #expect(screen.activate(labelled: "Edit workout duration"))
        try await screen.settle()
        try screen.capture("finish-duration-picker")

        try #require(screen.selectDuration(minutes: 24, seconds: 18))
        #expect(screen.activate(labelled: "Done"))
        try await screen.settle()
        #expect(screen.hasLabel(containing: "24:18"))
        #expect(screen.activate(labelled: "Save workout"))
        try await screen.settle()

        let completed = try #require(screen.completed)
        #expect(completed.durationSeconds == 1_458)
        #expect(screen.storeDurationSeconds == 1_458)
        // The actual completion instant remains the finish tap. Editing duration must not move it.
        #expect(completed.finishedAt.timeIntervalSince(screen.startedAt) < 120)

        let summary = try #require(screen.shareSummary)
        #expect(summary.elapsedSeconds == 1_458)
        #expect(
            BaselineShareStatResolver(summary: summary, units: screen.shareUnits)
                .resolve(.duration)?.value == "24m"
        )
    }

    /// Discard inside the review is a sheet-to-alert handoff, which SwiftUI refuses while the sheet is
    /// still on screen. Without the deferral the athlete taps Discard and nothing happens at all.
    @Test func discardingFromTheFinishReviewRaisesTheConfirmation() async throws {
        let screen = try await LoggingCleanupScreen()
        defer { screen.tearDown() }

        #expect(screen.activate(labelled: "Finish"))
        try await screen.settle()
        #expect(screen.hasLabel(containing: "Discard workout"))
        #expect(screen.activate(labelled: "Discard workout"))
        try await screen.settleUntil { screen.hasLabel(containing: "Discard Log") }

        #expect(screen.hasLabel(containing: "Save workout") == false)
        try await screen.tapAlertButton("Discard Log")
        #expect(screen.hasLiveLog == false)
        #expect(screen.completed == nil)
    }

    /// The wheels are bounded, so the largest duration they can express has to stay inside the
    /// canonical ceiling — otherwise the picker shows a value storage silently clamps.
    @Test func theDurationPickerCannotSelectMoreThanTheCanonicalCeiling() {
        let largest = WorkoutDurationPickerSheet.maxSelectableSeconds + 59
        #expect(largest < MetricFormat.maxDurationSeconds)
        #expect(WorkoutDurationPickerSheet.maxSelectableSeconds
            == TimeInterval(WorkoutDurationPickerSheet.maxMinutes * 60))
    }
}

@MainActor
private final class RowingUnitPickerScreen: HostedScreen {
    let window: UIWindow

    init() async throws {
        let row = PlannedExercise(
            exerciseName: "Row",
            definitionId: "row",
            selectedMetrics: [.duration, .distance, .pace]
        )
        let root = MetricConfigSheet(
            exercise: row,
            focus: .units,
            unitFor: { metric in
                metric == .pace ? .secondsPer500Meters : metric.canonicalUnit
            },
            onApply: { _, _ in }
        )
        .preferredColorScheme(.dark)

        window = try Self.makeWindow(rootView: root)
        try await settleUntil { self.hasLabel(containing: "/500m") }
    }
}

@MainActor
private final class LoggingCleanupScreen: HostedScreen {
    let window: UIWindow

    private let defaults: UserDefaults
    private let suiteName: String
    private let container: ModelContainer
    private let plan: PlanStore
    private let store: WorkoutStore
    private let scheduledID: UUID

    init() async throws {
        suiteName = "logging-cleanup-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))

        var row = PlannedExercise(
            exerciseName: "Row",
            definitionId: "row",
            selectedMetrics: [.duration, .distance, .pace]
        )
        row.displayUnits[.pace] = .secondsPer500Meters
        row.prescription.sets = [PlannedSet(duration: 480, distance: 2_000)]
        let workout = Workout(
            title: "Tempo Row",
            blocks: [WorkoutBlock(name: "", exercises: [row], isDefault: true)]
        )
        let program = plan.addProgram(Program(name: "Baseline", createdAt: Date()))
        let scheduled = plan.addScheduled(
            ScheduledWorkout(
                programID: program.id,
                date: Date(),
                origin: .userCreated,
                workoutID: workout.id,
                workoutRevisionID: UUID(),
                workout: workout
            )
        )
        scheduledID = scheduled.id

        store = WorkoutStore(units: StubUnitSystem(.metric), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        store.startWorkout()

        let root = WorkoutView()
            .environment(store)
            .environment(plan)
            .environment(BluetoothManager())
            .environment(OnboardingStore(defaults: defaults))
            .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 35 }))
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = try Self.makeWindow(rootView: root)
        try await settleUntil { self.hasLabel(containing: "Tempo Row") }
    }

    var completed: CompletedWorkoutLog? {
        plan.completed(for: scheduledID)
    }

    var startedAt: Date {
        store.currentLogStartedAt ?? .distantPast
    }

    var storeDurationSeconds: TimeInterval? {
        store.currentLogDurationSeconds
    }

    var hasLiveLog: Bool {
        store.currentLog != nil
    }

    var shareUnits: ShareUnitResolver {
        ShareUnitResolver(workout: store.current ?? Workout(title: ""), store: store)
    }

    var shareSummary: WorkoutLogSummary? {
        guard let workout = store.current,
              let log = store.currentLog,
              let startedAt = store.currentLogStartedAt,
              let finishedAt = store.currentLogFinishedAt
        else { return nil }
        return WorkoutLogSummary(
            title: workout.title,
            log: log,
            startedAt: startedAt,
            finishedAt: finishedAt,
            confirmedDurationSeconds: store.currentLogDurationSeconds,
            units: shareUnits
        )
    }

    func selectDuration(minutes: Int, seconds: Int) -> Bool {
        let pickers = views()
            .compactMap { $0 as? UIPickerView }
            .sorted { lhs, rhs in
                lhs.convert(lhs.bounds, to: window).minX < rhs.convert(rhs.bounds, to: window).minX
            }
        guard pickers.count >= 2 else { return false }
        select(minutes, in: pickers[0])
        select(seconds, in: pickers[1])
        return true
    }

    private func select(_ row: Int, in picker: UIPickerView) {
        picker.selectRow(row, inComponent: 0, animated: false)
        picker.delegate?.pickerView?(picker, didSelectRow: row, inComponent: 0)
        window.layoutIfNeeded()
    }
}
