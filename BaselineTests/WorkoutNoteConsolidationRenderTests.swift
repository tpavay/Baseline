import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

extension IdleTimerRenderTests {
    @MainActor
    struct WorkoutNoteConsolidationRenderTests {
        @Test func templateEditorEditsOnePlainNote() async throws {
            let screen = try await WorkoutNoteScreen(stage: .editing, includesExistingNote: true)
            defer { screen.tearDown() }

            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.hasLabel(containing: "Workout goal") == false)
            #expect(screen.inputText(labelled: "Workout note") == "Preserve this goal.")
            // The editor is where the second field used to live, so it is worth a look as well as an
            // assertion: one note, carrying the old goal text.
            try screen.capture("workout-note-editor")

            try screen.replaceInput(labelled: "Workout note", with: "One consolidated note")
            try await screen.settle()

            // The field is plain free-form storage: it reads back exactly what was typed.
            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.inputText(labelled: "Workout note") == "One consolidated note")
            #expect(screen.workout?.goal == "One consolidated note")
        }

        @Test func loggingShowsThePlanNoteInTheOneFieldAndAdoptsItOnTheFirstEdit() async throws {
            let screen = try await WorkoutNoteScreen(stage: .logging, includesExistingNote: true)
            defer { screen.tearDown() }

            // One workout-level surface, before and after the first edit: the plan's note is the field's
            // own content rather than a second block that would vanish out from under the cursor.
            #expect(screen.hasLabel(containing: "Workout goal") == false)
            #expect(screen.hasLabel(containing: "Plan note") == false)
            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.inputText(labelled: "Workout note") == "Preserve this goal.")
            #expect(screen.hasRenderedText("Add a note here…") == false)

            // Nothing is written until the athlete acts: `startLog` seeded no performed note.
            #expect(screen.log?.athleteNotes == [])
            #expect(screen.log?.hasAuthoredNotes == false)
            try screen.capture("workout-note-plan-fallback")

            try screen.replaceInput(labelled: "Workout note", with: "Preserve this goal.\n\nLegs heavy today.")
            try await screen.settle()

            // The first edit adopts what was on screen plus the athlete's own words into the log, and
            // leaves the plan's own note exactly as it was.
            #expect(screen.log?.athleteNotes == ["Preserve this goal.\n\nLegs heavy today."])
            #expect(screen.log?.hasAuthoredNotes == true)
            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.inputText(labelled: "Workout note") == "Preserve this goal.\n\nLegs heavy today.")
            #expect(screen.hasLabel(containing: "Plan note") == false)
            #expect(screen.workout?.goal == "Preserve this goal.")

            // Clearing it leaves it cleared: the plan's note can no longer reappear under the cursor.
            try screen.replaceInput(labelled: "Workout note", with: "")
            try await screen.settle()

            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.inputText(labelled: "Workout note") == "")
            #expect(screen.hasRenderedText("Add a note here…"))
            #expect(screen.log?.athleteNotes == [])
            #expect(screen.log?.hasAuthoredNotes == true)
        }

        @Test func emptyCompletedWorkoutShowsOneNotePlaceholder() async throws {
            let screen = try await WorkoutNoteScreen(stage: .completed, includesExistingNote: false)
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

    init(stage: Stage, includesExistingNote: Bool) async throws {
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
            goal: includesExistingNote ? "Preserve this goal." : nil
        )

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

    /// Whether `text` reaches the athlete at all on this screen — as rendered text, inside an editable
    /// field, or announced through the accessibility tree.
    func shows(_ text: String) -> Bool {
        if hasRenderedText(text) || hasLabel(containing: text) { return true }
        return views()
            .compactMap { $0 as? (UIView & UITextInput) }
            .contains { input in
                guard let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
                else { return false }
                return input.text(in: range)?.contains(text) ?? false
            }
    }

    /// UIKit keeps a text field's placeholder label in the hierarchy after the field gains text, so a
    /// plain lookup would report a placeholder the athlete cannot see. Only labels that actually render
    /// count.
    func hasRenderedText(_ text: String) -> Bool {
        views().contains { view in
            guard let label = view as? UILabel, label.text == text else { return false }
            return sequence(first: label, next: \.superview).allSatisfy { !$0.isHidden && $0.alpha > 0.01 }
        }
    }
}
