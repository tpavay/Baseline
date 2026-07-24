import SwiftUI
import Testing
import UIKit
@testable import Baseline

@MainActor
struct WorkoutLogSummaryTests {

    @Test func strengthWorkoutSummaryAndTextUseCompletedSets() {
        let summary = ShareComposerFixtures.strengthSummary()

        #expect(summary.exerciseCount == 2)
        #expect(summary.totalSets == 3)
        #expect(summary.totalReps == 18)
        #expect(abs(summary.totalVolumeKilograms - 1570) < 0.001)
        #expect(summary.heaviestLoadKilograms == 100)
        #expect(summary.totalDistanceMeters == 0)

        let text = WorkoutShareTextSummary.make(from: summary, units: ShareComposerFixtures.units)
        #expect(text.contains("Lower Strength"))
        #expect(text.contains("Duration: 01:12:00"))
        #expect(text.contains("Back Squat - 2 sets"))
        #expect(text.contains("1. 5 reps · 100 kg"))
        #expect(text.contains("Bench Press - 1 sets"))
    }

    @Test func cardioWorkoutSummaryAndTextIncludeDistanceDurationAndPace() {
        let summary = ShareComposerFixtures.cardioSummary()

        #expect(summary.exerciseCount == 1)
        #expect(summary.totalSets == 2)
        #expect(summary.totalReps == 0)
        #expect(summary.totalVolumeKilograms == 0)
        #expect(summary.totalDistanceMeters == 5000)
        #expect(summary.totalDurationSeconds == 1500)
        #expect(summary.averagePaceSecondsPerMeter == 0.3)

        let text = WorkoutShareTextSummary.make(from: summary, units: ShareComposerFixtures.units)
        #expect(text.contains("5 km Progression"))
        #expect(text.contains("Distance: 5 km"))
        #expect(text.contains("Average pace: 5:00/km"))
        #expect(text.contains("Treadmill Run - 2 sets"))
        #expect(text.contains("1. 12:00 · 2.4 km · 5:00/km"))
    }
}

@MainActor
struct BaselineShareStatResolverTests {

    @Test func strengthStatsResolveAgainstBaselineMetrics() throws {
        let resolver = BaselineShareStatResolver(
            summary: ShareComposerFixtures.strengthSummary(),
            units: ShareComposerFixtures.units
        )

        #expect(try #require(resolver.resolve(.duration)).value == "1h 12m")
        #expect(try #require(resolver.resolve(.totalSets)).value == "3")
        #expect(try #require(resolver.resolve(.totalReps)).value == "18")
        #expect(try #require(resolver.resolve(.totalVolume)).value == "1570 kg")
        #expect(try #require(resolver.resolve(.heaviestLoad)).value == "100 kg")
        #expect(resolver.resolve(.totalDistance) == nil)
        #expect(resolver.resolve(.avgPace) == nil)
    }

    @Test func cardioStatsOmitStrengthOnlyValues() throws {
        let resolver = BaselineShareStatResolver(
            summary: ShareComposerFixtures.cardioSummary(),
            units: ShareComposerFixtures.units
        )

        #expect(try #require(resolver.resolve(.totalDistance)).value == "5 km")
        #expect(try #require(resolver.resolve(.totalDuration)).value == "25m")
        #expect(try #require(resolver.resolve(.avgPace)).value == "5:00/km")
        #expect(resolver.resolve(.totalVolume) == nil)
        #expect(resolver.resolve(.heaviestLoad) == nil)
        #expect(resolver.availableKinds().contains(.workoutName))
    }
}

@MainActor
struct ShareUnitResolverTests {

    /// A share card is a display surface, so the floor/endurance distance rule has to reach it: a sled
    /// push logged in metres must not read "0.02 km" because the summary forgot which exercise it was.
    @Test func perExerciseUnitsSurviveIntoTheShareTextAndTotals() {
        let store = WorkoutStore(
            units: StubUnitSystem(.imperial),
            defaults: UserDefaults(suiteName: "share-units-\(UUID().uuidString)")!
        )
        let sled = PlannedExercise(exerciseName: "Sled Push", definitionId: "sled_push", selectedMetrics: [.distance])
        let run = PlannedExercise(exerciseName: "Run", definitionId: "run", selectedMetrics: [.distance])
        let workout = Workout(title: "Hybrid", blocks: [WorkoutBlock(name: "", exercises: [sled, run])])
        let log = WorkoutLog(exercises: [
            PerformedExercise(
                plannedExerciseID: sled.id,
                exerciseName: "Sled Push",
                setLogs: [SetLog(distance: 20, outcome: .completed)]
            ),
            PerformedExercise(
                plannedExerciseID: run.id,
                exerciseName: "Run",
                setLogs: [SetLog(distance: 1_609.344, outcome: .completed)]
            )
        ], isComplete: true)

        let units = ShareUnitResolver(workout: workout, store: store)
        let summary = WorkoutLogSummary(
            title: "Hybrid",
            log: log,
            startedAt: ShareComposerFixtures.startedAt,
            finishedAt: ShareComposerFixtures.finishedAt,
            units: units
        )
        let text = WorkoutShareTextSummary.make(from: summary, units: units)

        #expect(text.contains("20 m"))
        #expect(text.contains("1 mi"))
        // The one distance total covers both movements, and any floor work puts the whole total in metres.
        #expect(BaselineShareStatResolver(summary: summary, units: units).resolve(.totalDistance)?.value.hasSuffix(" m") == true)
    }
}

@MainActor
struct ShareStickerInstanceTests {

    /// The export clips to the card, so a normalized position outside 0...1 would be visible while
    /// editing and missing from the shared image.
    @Test func positionIsClampedToTheCanvasOnEveryWrite() {
        var sticker = ShareStickerInstance(kind: .duration, position: CGPoint(x: -0.4, y: 1.8))
        #expect(sticker.position == CGPoint(x: 0, y: 1))

        sticker.position = CGPoint(x: 1.4, y: -0.2)
        #expect(sticker.position == CGPoint(x: 1, y: 0))

        sticker.position = CGPoint(x: 0.3, y: 0.7)
        #expect(sticker.position == CGPoint(x: 0.3, y: 0.7))
    }
}

@MainActor
struct ShareComposerViewModelTests {

    /// A sticker whose stat resolves to nil renders nothing on either canvas, so seeding one would leave
    /// an entry the athlete can neither see, select, nor drag to the trash.
    @Test func everySeededStickerResolves() {
        let skippedEverything = WorkoutLogSummary(
            title: "Bailed",
            log: WorkoutLog(exercises: [
                PerformedExercise(
                    exerciseName: "Back Squat",
                    setLogs: [SetLog(reps: 5, load: 100, outcome: .skipped)]
                )
            ], isComplete: true),
            startedAt: ShareComposerFixtures.startedAt,
            finishedAt: ShareComposerFixtures.finishedAt,
            units: ShareComposerFixtures.units
        )
        let viewModel = ShareComposerViewModel(summary: skippedEverything, units: ShareComposerFixtures.units)

        #expect(viewModel.stickers.isEmpty == false)
        #expect(viewModel.stickers.allSatisfy { viewModel.resolve($0) != nil })

        // And the same invariant holds for the one other way a sticker gets added.
        viewModel.addSticker(kind: .totalSets)
        #expect(viewModel.stickers.allSatisfy { viewModel.resolve($0) != nil })
    }
}

@MainActor
struct CompletedWorkoutFinishTimeTests {

    /// A standalone log has no plan record to read a finish time back from, so completion has to leave
    /// one behind — otherwise reopening the workout tomorrow shares a multi-day "duration".
    @Test func standaloneCompletionPersistsTheFinishInstant() {
        let suite = "finish-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = WorkoutStore(units: StubUnitSystem(.metric), defaults: defaults)
        store.create(title: "Ad-hoc", goal: nil)
        store.startWorkout()
        #expect(store.currentLogFinishedAt == nil)

        let before = Date()
        store.completeWorkout(awaitingReconciliationDecision: false)
        let finishedAt = store.currentLogFinishedAt

        #expect(finishedAt != nil)
        #expect(finishedAt.map { $0.timeIntervalSince(before) < 5 } == true)

        // And it survives the app being reopened, which is exactly when "now" would have been wrong.
        let reopened = WorkoutStore(units: StubUnitSystem(.metric), defaults: defaults)
        #expect(reopened.currentLogFinishedAt == finishedAt)

        reopened.discardLog()
        #expect(reopened.currentLogFinishedAt == nil)
    }

    /// Completing can be refused — there was no live session, or no log to mark. Nothing finished, so
    /// nothing may claim a finish instant.
    @Test func aRefusedCompletionRecordsNoFinishInstant() {
        let store = WorkoutStore(
            units: StubUnitSystem(.metric),
            defaults: UserDefaults(suiteName: "finish-\(UUID().uuidString)")!
        )
        store.create(title: "Ad-hoc", goal: nil)

        store.completeWorkout(awaitingReconciliationDecision: false)

        #expect(store.currentLog == nil)
        #expect(store.currentLogFinishedAt == nil)
    }
}

@MainActor
struct ShareComposerRenderTests {

    @Test func rendererProducesStorySizedBaselineCard() async throws {
        let viewModel = ShareComposerViewModel(
            summary: ShareComposerFixtures.strengthSummary(),
            units: ShareComposerFixtures.units
        )
        let image = try #require(await ShareComposerExporter().renderImage(viewModel: viewModel))

        #expect(image.size.width == 1080)
        #expect(image.size.height == 1920)
        try ShareComposerFixtures.write(image, named: "share-card-render")
    }

    @Test func copyAndShareSheetWiringWorkFromHostedComposer() async throws {
        let screen = try ShareComposerScreen(summary: ShareComposerFixtures.strengthSummary())
        defer { screen.tearDown() }
        try await screen.settle()
        try screen.capture("share-composer-card")

        UIPasteboard.general.string = nil
        #expect(screen.activate(labelled: "Copy workout text"))
        try await screen.settle()
        #expect(UIPasteboard.general.string?.contains("Lower Strength") == true)

        #expect(screen.activate(labelled: "Share workout text"))
        try await screen.settleUntil(timeout: 5) { screen.presentedShareSheet != nil }
        screen.presentedShareSheet?.dismiss(animated: false)
        try await screen.settle()

        #expect(screen.activate(labelled: "Share workout image"))
        try await screen.settleUntil(timeout: 5) { screen.presentedShareSheet != nil }
        try await screen.settle()
        try screen.capture("share-composer-share-sheet")
        screen.presentedShareSheet?.dismiss(animated: false)
    }
}

@MainActor
private enum ShareComposerFixtures {
    static let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let finishedAt = startedAt.addingTimeInterval(4_320)

    static func strengthSummary() -> WorkoutLogSummary {
        WorkoutLogSummary(
            title: "Lower Strength",
            log: WorkoutLog(exercises: [
                PerformedExercise(
                    exerciseName: "Back Squat",
                    setLogs: [
                        SetLog(reps: 5, load: 100, outcome: .completed),
                        SetLog(reps: 5, load: 100, outcome: .completed),
                        SetLog(reps: 5, load: 100, outcome: .skipped)
                    ]
                ),
                PerformedExercise(
                    exerciseName: "Bench Press",
                    setLogs: [
                        SetLog(reps: 8, load: 71.25, outcome: .completed)
                    ]
                )
            ], isComplete: true),
            startedAt: startedAt,
            finishedAt: finishedAt,
            units: units
        )
    }

    static func cardioSummary() -> WorkoutLogSummary {
        WorkoutLogSummary(
            title: "5 km Progression",
            log: WorkoutLog(exercises: [
                PerformedExercise(
                    exerciseName: "Treadmill Run",
                    setLogs: [
                        SetLog(duration: 720, distance: 2_400, outcome: .completed),
                        SetLog(duration: 780, distance: 2_600, outcome: .completed)
                    ]
                )
            ], isComplete: true),
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(1_620),
            units: units
        )
    }

    static let units = ShareUnitResolver.withoutExerciseContext(metricUnits)

    nonisolated static func metricUnits(_ metric: MetricType) -> MetricUnit {
        switch metric {
        case .distance:
            return .kilometers
        case .pace:
            return .secondsPerKilometer
        case .load:
            return .kilograms
        default:
            return metric.canonicalUnit
        }
    }

    static func write(_ image: UIImage, named name: String) throws {
        let data = try #require(image.pngData())
        let url = AccessibilityElementWalker.evidenceDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        print("SCREENSHOT \(url.path)")
    }
}

@MainActor
private final class ShareComposerScreen: HostedScreen {
    let window: UIWindow

    init(summary: WorkoutLogSummary) throws {
        window = try Self.makeWindow(
            rootView: ShareComposerView(summary: summary, units: ShareComposerFixtures.units)
                .preferredColorScheme(.dark)
        )
    }

    var presentedShareSheet: UIActivityViewController? {
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController {
            if let activity = presented as? UIActivityViewController {
                return activity
            }
            presenter = presented
        }
        return nil
    }
}
