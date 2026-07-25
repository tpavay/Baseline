import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

@MainActor
struct WorkoutCompletedSummaryRenderTests {
    @Test func completedSummaryHidesExerciseStateChipsButKeepsLoggedRows() async throws {
        let screen = try await CompletedWorkoutSummaryScreen()
        defer { screen.tearDown() }

        try await screen.settle()
        try screen.capture("workout-summary-state-chips-after")

        #expect(screen.hasLabel(containing: "Logged Cleanup Session"))
        #expect(screen.hasLabel(containing: "Workout notes"))
        #expect(screen.hasLabel(containing: "Back Squat"))
        #expect(screen.hasLabel(containing: "Bench Press"))
        #expect(screen.hasLabel(containing: "Pull-Up"))
        #expect(screen.hasLabel(containing: "Run"))
        #expect(screen.hasLabel(containing: "Notes for Back Squat"))
        #expect(screen.hasAccessibleText(containing: "Felt stable under load."))
        // The workout-level note the athlete typed is read back into the field they typed it in.
        #expect(screen.hasAccessibleText(containing: "Kept the session short."))
        // The note the athlete typed stays a performed fact; it is never folded into the plan's guidance.
        #expect(screen.performedNotes(forExerciseAt: 0) == ["Felt stable under load."])
        #expect(screen.plannedNotes(forExerciseAt: 0) == ["Existing note for Back Squat."])
        // The plan's own note is read-only context, announced as such rather than as a second Notes field.
        #expect(screen.hasLabel(containing: "Plan note for Back Squat. Existing note for Back Squat."))
        #expect(screen.hasLabel(containing: "Notes for Back Squat. Existing note") == false)
        // Same at the workout level: the goal and the plan note are captioned context, and the session
        // notes field is the only thing in the header that accepts typing.
        #expect(screen.hasLabel(containing: "Workout goal. Keep the completed log readable."))
        #expect(screen.hasLabel(containing: "Plan note. Hold the paces we agreed on."))
        #expect(screen.hasLabel(containing: "Set completed"))
        #expect(screen.canFocusInput(labelled: "Workout notes"))
        #expect(screen.canFocusInput(labelled: "Notes for Back Squat"))
        #expect(screen.canFocusInput(labelled: "Plan note for Back Squat") == false)
        #expect(screen.canFocusInput(labelled: "Workout goal") == false)
        #expect(screen.canFocusInput(labelled: "Plan note.") == false)

        #expect(screen.hasLabel(containing: "Done") == false)
        #expect(screen.hasLabel(containing: "Modified") == false)
        #expect(screen.hasLabel(containing: "Substituted") == false)
        #expect(screen.hasLabel(containing: "Subbed") == false)
        #expect(screen.hasLabel(containing: "Skipped") == false)
    }
}

@MainActor
private final class CompletedWorkoutSummaryScreen: HostedScreen {
    let window: UIWindow
    private let defaults: UserDefaults
    private let suiteName: String
    private let container: ModelContainer
    private let store: WorkoutStore

    init() async throws {
        suiteName = "WorkoutCompletedSummaryRenderTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        self.store = store
        store.create(title: "Logged Cleanup Session", goal: "Keep the completed log readable.")
        store.edit(.plan) { workout in
            workout.updateGuidance(CoachGuidance(formCues: ["Hold the paces we agreed on."]))
        }
        let blockID = try #require(store.current?.blocks.first?.id)
        for exercise in Self.exercises {
            store.addExercise(exercise, toBlockID: blockID, scope: .plan)
        }
        store.startWorkout()
        Self.seedLog(in: store)
        store.completeWorkout(awaitingReconciliationDecision: false)

        let root = WorkoutView()
            .environment(store)
            .environment(PlanStore(context: container.mainContext))
            .environment(BluetoothManager())
            .environment(OnboardingStore(defaults: defaults))
            .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 35 }))
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = try Self.makeWindow(rootView: root)
        try await settleUntil { self.hasLabel(containing: "Logged Cleanup Session") }
    }

    func hasLabel(containing text: String) -> Bool {
        AccessibilityElementWalker.elements(in: window).contains {
            $0.accessibilityLabel?.contains(text) ?? false
        }
    }

    func hasAccessibleText(containing text: String) -> Bool {
        AccessibilityElementWalker.elements(in: window).contains {
            ($0.accessibilityLabel?.contains(text) ?? false)
                || ($0.accessibilityValue?.contains(text) ?? false)
        }
    }

    func performedNotes(forExerciseAt index: Int) -> [String] {
        guard let exercise = plannedExercise(at: index) else { return [] }
        return store.currentLog?.performed(forPlanned: exercise.id)?.athleteNotes ?? []
    }

    func plannedNotes(forExerciseAt index: Int) -> [String] {
        plannedExercise(at: index)?.guidance?.formCues ?? []
    }

    private func plannedExercise(at index: Int) -> PlannedExercise? {
        let exercises = store.current?.allExercises ?? []
        return index < exercises.count ? exercises[index] : nil
    }

    func canFocusInput(labelled label: String) -> Bool {
        guard let input = Self.allViews(in: window)
            .compactMap({ $0 as? (UIView & UITextInput) })
            .first(where: { $0.accessibilityLabel?.contains(label) ?? false })
        else { return false }
        input.becomeFirstResponder()
        let isFocused = input.isFirstResponder
        input.resignFirstResponder()
        return isFocused
    }

    private static func allViews(in root: UIView) -> [UIView] {
        var views = [root]
        for subview in root.subviews {
            views.append(contentsOf: allViews(in: subview))
        }
        return views
    }

    private static func seedLog(in store: WorkoutStore) {
        guard let workout = store.current else { return }
        let exercises = workout.allExercises
        guard exercises.count == 4 else { return }

        store.editLog { log in
            log.setNotes("Kept the session short.")

            logSet(for: exercises[0], in: &log, outcome: .completed)
            log.setStatus(.completed, forPlanned: exercises[0].id, name: exercises[0].exerciseName)
            log.addNote(
                "Felt stable under load.",
                forPlanned: exercises[0].id,
                name: exercises[0].exerciseName
            )

            logSet(for: exercises[1], in: &log, outcome: .completed)
            log.logSet(
                SetLog(reps: 10, load: 120, outcome: .completed),
                forPlanned: exercises[1].id,
                name: exercises[1].exerciseName
            )
            log.setStatus(.modified, forPlanned: exercises[1].id, name: exercises[1].exerciseName)

            log.setExerciseAdjustment(
                plannedExerciseID: exercises[2].id,
                outcome: .skipped,
                name: exercises[2].exerciseName
            )
        }

        store.substituteLoggedExercise(exerciseID: exercises[3].id, with: ExerciseCatalog.resolve("Run"))
        store.editLog { log in
            let effective = log.effectiveExercise(for: exercises[3])
            logSet(for: effective, plannedID: exercises[3].id, in: &log, outcome: .completed)
            log.setStatus(.substituted, forPlanned: exercises[3].id, name: exercises[3].exerciseName)
        }
    }

    private static var exercises: [PlannedExercise] {
        [
            exercise("Back Squat"),
            exercise("Bench Press"),
            exercise("Pull-Up"),
            exercise("BikeErg"),
        ]
    }

    private static func exercise(_ name: String) -> PlannedExercise {
        var exercise = PlannedExercise(exerciseName: name)
        exercise.selectedMetrics = [.reps, .load]
        exercise.prescription.sets = [
            PlannedSet(reps: 5, load: 135),
            PlannedSet(reps: 5, load: 135),
        ]
        exercise.guidance = CoachGuidance(formCues: ["Existing note for \(name)."])
        return exercise
    }

    private static func logSet(
        for exercise: PlannedExercise,
        plannedID: UUID? = nil,
        in log: inout WorkoutLog,
        outcome: SetLogOutcome
    ) {
        let targetID = plannedID ?? exercise.id
        for set in exercise.prescription.sets {
            log.upsertSetLog(
                forPlanned: targetID,
                name: exercise.exerciseName,
                plannedSetID: set.id
            ) { actual in
                actual.values = set.expectedValues(iteration: 1)
                actual.outcome = outcome
            }
        }
    }
}
