import Photos
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The share composer's only entry point, driven the way an athlete reaches it: finish a workout, land
/// on the completed-workout screen, and tap "Share workout". v1 has no save-workout finish screen, so
/// this completed surface is the whole doorway — if the button is absent or opens nothing, the feature
/// is unreachable no matter how well the composer itself renders.
@MainActor
@Suite(.serialized)
struct ShareComposerEntryPointTests {

    @Test func completedWorkoutScreenOpensTheComposer() async throws {
        let bed = try CompletedWorkoutBed()
        let screen = try CompletedWorkoutBed.Screen(bed: bed)
        defer { screen.tearDown() }
        try await screen.settle()

        // The completed-workout screen offers the share affordance.
        try await screen.settleUntil { screen.element(labelled: "Share workout") != nil }
        try screen.capture("share-entry-completed-workout")

        // Tapping it presents the composer over that screen, seeded from the real completed log.
        #expect(screen.activate(labelled: "Share workout"))
        try await screen.settleUntil(timeout: 5) { screen.element(labelled: "Compose a Baseline card") != nil }
        try await screen.settle()
        try screen.capture("share-entry-composer-open")

        // And the composer really read this workout, not a placeholder.
        UIPasteboard.general.string = nil
        #expect(screen.activate(labelled: "Copy workout text"))
        try await screen.settleUntil(timeout: 5) { UIPasteboard.general.string != nil }
        let text = try #require(UIPasteboard.general.string)
        print("SHARE TEXT SUMMARY >>>\n\(text)\n<<< END SHARE TEXT SUMMARY")
        #expect(text.contains("Evening Squat Session"))
        #expect(text.contains("Back Squat"))
        #expect(text.contains("Treadmill Run"))
    }

    /// A workout that is still being logged must not offer the share button — there is nothing finished
    /// to share, and the composer would have no finish instant to date the card with.
    @Test func aLiveLogDoesNotOfferTheShareAffordance() async throws {
        let bed = try CompletedWorkoutBed(complete: false)
        let screen = try CompletedWorkoutBed.Screen(bed: bed)
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.element(labelled: "Workout duration") != nil, "should be on the live logging surface")
        #expect(screen.element(labelled: "Share workout") == nil)
    }
}

/// The save-to-Photos leg of the export, which the share sheet cannot stand in for: it needs the
/// add-only authorization the new `NSPhotoLibraryAddUsageDescription` covers, and the change block has
/// to survive Photos running it off the main actor.
///
/// The write is only asserted through `saveToPhotos`'s own result: reading the library back would need
/// `NSPhotoLibraryUsageDescription`, which Baseline deliberately does not declare — asking for it would
/// crash the app on the first read, and add-only is the whole point. The asset itself is confirmed by
/// opening Photos on the simulator afterwards.
@MainActor
@Suite(.serialized)
struct ShareComposerPhotosExportTests {

    @Test func savingTheCardWritesAStorySizedAssetToPhotos() async throws {
        try #require(PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized,
                     "grant with: xcrun simctl privacy <device> grant photos-add com.tylerpavay.Baseline")

        let viewModel = ShareComposerViewModel(
            summary: WorkoutLogSummary(
                title: "Photos Export Check",
                log: WorkoutLog(exercises: [
                    PerformedExercise(exerciseName: "Back Squat",
                                      setLogs: [SetLog(reps: 5, load: 100, outcome: .completed)])
                ], isComplete: true),
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_800_003_600),
                units: ShareUnitResolver.withoutExerciseContext { $0.canonicalUnit }
            ),
            units: ShareUnitResolver.withoutExerciseContext { $0.canonicalUnit }
        )
        let exporter = ShareComposerExporter()
        let image = try #require(await exporter.renderImage(viewModel: viewModel))

        #expect(image.size == CGSize(width: 1080, height: 1920))
        #expect(await exporter.saveToPhotos(image))
        print("PHOTOS SAVE OK \(Int(image.size.width))x\(Int(image.size.height))")
    }
}

/// A standalone workout logged and finished for real through `WorkoutStore`, then presented through the
/// real `WorkoutView` — the same surface Plan and the workout tab push.
@MainActor
private final class CompletedWorkoutBed {

    let store: WorkoutStore
    let plan: PlanStore
    let container: ModelContainer

    init(complete: Bool = true) throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(for: Schema(models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        plan = PlanStore(context: container.mainContext)
        store = WorkoutStore(units: StubUnitSystem(.metric),
                             defaults: try #require(UserDefaults(suiteName: "share-entry-\(UUID().uuidString)")))

        store.create(title: "Evening Squat Session", goal: nil)
        let blockID = try #require(store.current?.blocks.first?.id)
        store.addExercise(
            PlannedExercise(exerciseName: "Back Squat", definitionId: "back_squat", selectedMetrics: [.reps, .load]),
            toBlockID: blockID,
            scope: .plan
        )
        store.addExercise(
            PlannedExercise(exerciseName: "Treadmill Run", definitionId: "treadmill_run", selectedMetrics: [.duration, .distance]),
            toBlockID: blockID,
            scope: .plan
        )

        store.startWorkout()
        store.editLog { log in
            log.exercises[0].setLogs = [
                SetLog(reps: 5, load: 102.5, outcome: .completed),
                SetLog(reps: 5, load: 102.5, outcome: .completed),
                SetLog(reps: 3, load: 115, outcome: .completed)
            ]
            log.exercises[1].setLogs = [
                SetLog(duration: 900, distance: 3_000, outcome: .completed)
            ]
        }
        guard complete else { return }
        store.completeWorkout(awaitingReconciliationDecision: false)
    }

    @MainActor
    final class Screen: HostedScreen {
        let window: UIWindow

        init(bed: CompletedWorkoutBed) throws {
            let root = WorkoutView()
                .environment(bed.store)
                .environment(bed.plan)
                .environment(BluetoothManager())
                .environment(OnboardingStore())
                .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
                .modelContainer(bed.container)
                .preferredColorScheme(.dark)
            window = try Self.makeWindow(rootView: root)
        }
    }
}
