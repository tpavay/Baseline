import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

extension IdleTimerRenderTests {
    @MainActor
    struct WorkoutNoteConsolidationRenderTests {
        @Test func templateEditorEditsOnePlainNoteAndLeavesGuidanceUntouched() async throws {
            let screen = try await WorkoutNoteScreen(stage: .editing, includesLegacyNotes: true)
            defer { screen.tearDown() }

            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.hasLabel(containing: "Workout goal") == false)
            #expect(screen.inputText(labelled: "Workout note") == "Preserve this goal.")

            try screen.replaceInput(labelled: "Workout note", with: "One consolidated note")
            try await screen.settle()

            // The field is plain free-form storage: it reads back exactly what was typed.
            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.inputText(labelled: "Workout note") == "One consolidated note")
            #expect(screen.workout?.goal == "One consolidated note")
            // Structured guidance is separate plan metadata the note path never rewrites.
            #expect(screen.workout?.guidance == CoachGuidance(formCues: ["Preserve this imported note."]))
        }

        @Test func loggingShowsThePlanNoteUntilTheAthleteCommitsTheField() async throws {
            let screen = try await WorkoutNoteScreen(stage: .logging, includesLegacyNotes: true)
            defer { screen.tearDown() }

            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.hasLabel(containing: "Workout goal") == false)
            #expect(screen.hasLabel(containing: "Plan note. Preserve this imported note.") == false)

            // A session that has never had the field committed shows the plan's folded note, so nothing
            // that used to render is lost — and the log still records no note it did not perform.
            #expect(screen.inputText(labelled: "Workout note") == """
            Preserve this goal.

            Preserve this imported note.
            """)
            #expect(screen.log?.athleteNotes == [])
            #expect(screen.log?.hasAuthoredNotes == false)

            try screen.replaceInput(labelled: "Workout note", with: "Legs heavy today.")
            try await screen.settle()

            // Typing writes the performed note only; the plan keeps its goal and its guidance.
            #expect(screen.log?.athleteNotes == ["Legs heavy today."])
            #expect(screen.inputText(labelled: "Workout note") == "Legs heavy today.")
            #expect(screen.workout?.goal == "Preserve this goal.")
            #expect(screen.workout?.guidance == CoachGuidance(formCues: ["Preserve this imported note."]))

            // Clearing it leaves it cleared: the plan's note can no longer reappear under the cursor.
            try screen.replaceInput(labelled: "Workout note", with: "")
            try await screen.settle()

            #expect(screen.inputText(labelled: "Workout note") == "")
            #expect(screen.hasRenderedText("Add a note here…"))
            #expect(screen.log?.athleteNotes == [])
            #expect(screen.log?.hasAuthoredNotes == true)
        }

        @Test func emptyCompletedWorkoutShowsOneNotePlaceholder() async throws {
            let screen = try await WorkoutNoteScreen(stage: .completed, includesLegacyNotes: false)
            defer { screen.tearDown() }

            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.inputText(labelled: "Workout note") == "")
            #expect(screen.hasRenderedText("Add a note here…"))
            try screen.capture("workout-note-empty")
        }
    }
}

@MainActor
private final class WorkoutNoteScreen: HostedScreen {
    enum Stage {
        case editing
        case logging
        case completed
    }

    let window: UIWindow
    private let store: WorkoutStore
    private let defaults: UserDefaults
    private let suiteName: String
    private let container: ModelContainer

    var workout: Workout? { store.current }
    var log: WorkoutLog? { store.currentLog }

    init(stage: Stage, includesLegacyNotes: Bool) async throws {
        suiteName = "WorkoutNoteConsolidationRenderTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.create(
            title: "Workout Note Test",
            goal: includesLegacyNotes ? "Preserve this goal." : nil
        )
        if includesLegacyNotes {
            store.edit(.plan) {
                $0.updateGuidance(CoachGuidance(formCues: ["Preserve this imported note."]))
            }
        }

        switch stage {
        case .editing:
            break
        case .logging:
            store.startWorkout()
        case .completed:
            store.startWorkout()
            store.completeWorkout(awaitingReconciliationDecision: false)
        }

        let root = WorkoutView()
            .environment(store)
            .environment(PlanStore(context: container.mainContext))
            .environment(BluetoothManager())
            .environment(OnboardingStore(defaults: defaults))
            .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 35 }))
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = try Self.makeWindow(rootView: root)
        try await settleUntil { self.hasLabel(containing: "Workout Note Test") }

        if case .editing = stage {
            try #require(activate(labelled: "Edit"), "The workout Edit button did not activate.")
            try await settleUntil { self.hasLabel(containing: "Edit Workout") }
        }
        try await settleUntil { self.inputCount(labelled: "Workout note") == 1 }
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func hasRenderedText(_ text: String) -> Bool {
        views().contains { ($0 as? UILabel)?.text == text }
    }
}
