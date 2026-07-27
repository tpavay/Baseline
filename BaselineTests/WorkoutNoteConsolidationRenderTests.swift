import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

extension IdleTimerRenderTests {
    @MainActor
    struct WorkoutNoteConsolidationRenderTests {
        @Test func templateEditorShowsOneNoteAndNormalizesLegacyContent() async throws {
            let screen = try await WorkoutNoteScreen(stage: .editing, includesLegacyNotes: true)
            defer { screen.tearDown() }

            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.hasLabel(containing: "Workout goal") == false)
            #expect(screen.inputText(labelled: "Workout note") == """
            Preserve this goal.

            Preserve this imported note.
            """)

            try screen.replaceInput(labelled: "Workout note", with: "One consolidated note")
            try await screen.settle()

            #expect(screen.workout?.notesText == "One consolidated note")
            #expect(screen.workout?.goal == "One consolidated note")
            #expect(screen.workout?.guidance == nil)
        }

        @Test func loggingStartsWithOneNoteContainingPriorGoalAndGuidance() async throws {
            let screen = try await WorkoutNoteScreen(stage: .logging, includesLegacyNotes: true)
            defer { screen.tearDown() }

            #expect(screen.inputCount(labelled: "Workout note") == 1)
            #expect(screen.hasLabel(containing: "Workout goal") == false)
            #expect(screen.hasLabel(containing: "Plan note. Preserve this imported note.") == false)
            #expect(screen.log?.notesText == """
            Preserve this goal.

            Preserve this imported note.
            """)
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

    func hasLabel(containing text: String) -> Bool {
        AccessibilityElementWalker.elements(in: window).contains {
            $0.accessibilityLabel?.contains(text) ?? false
        }
    }

    func hasRenderedText(_ text: String) -> Bool {
        Self.allViews(in: window).contains {
            ($0 as? UILabel)?.text == text
        }
    }

    func inputCount(labelled label: String) -> Int {
        textInputs(labelled: label).count
    }

    func inputText(labelled label: String) -> String? {
        guard let input = textInputs(labelled: label).first,
              let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        else { return nil }
        return input.text(in: range)
    }

    func replaceInput(labelled label: String, with text: String) throws {
        let input = try #require(textInputs(labelled: label).first)
        input.becomeFirstResponder()
        let range = try #require(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument))
        input.replace(range, withText: text)
        input.resignFirstResponder()
        window.layoutIfNeeded()
    }

    private func textInputs(labelled label: String) -> [UIView & UITextInput] {
        Self.allViews(in: window)
            .compactMap { $0 as? (UIView & UITextInput) }
            .filter { $0.accessibilityLabel?.contains(label) ?? false }
    }

    private static func allViews(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { allViews(in: $0) }
    }
}
