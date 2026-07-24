import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The Plan "Start an empty workout" → discard story, end to end. Starting an empty workout schedules a
/// blank placeholder up front so live logging has something to write through; discarding that log is not
/// "keep the plan, drop the log" (there is no plan to keep) — it must remove the placeholder entirely and
/// land the athlete back on the Plan page with the day undecided again, never stuck on a blank workout.
///
/// SwiftUI toolbar `Menu` items render as context-menu mock elements that do not answer
/// `accessibilityActivate()`, so — as the existing in-workout E2E suite does — the menu-buried discard
/// action is invoked through the same code the confirmed alert runs, while everything the harness *can*
/// drive (the real add sheet, the real start, the real placeholder, the real WorkoutView surface, the
/// real purge) is driven for real.
@MainActor
@Suite(.serialized)
struct PlanEmptyWorkoutDiscardTests {

    private let cal = Calendar.planWeek

    /// The full user path through the real shell up to the discard affordance: tap "Add workout", start
    /// an empty workout, and confirm the placeholder is really scheduled and live logging is running,
    /// and that its discard control reads "Discard Workout" (it removes the whole thing), not the
    /// plain-log "Discard Log". Captures the live-logging surface as before-evidence.
    @Test func startEmptyWorkoutSchedulesAProvisionalPlaceholderWithADiscardWorkoutAffordance() async throws {
        let screen = try MainTabShellScreen(tab: .plan)
        defer { screen.tearDown() }
        try await screen.settle()

        try await screen.settleUntil { screen.element(labelled: "Add workout") != nil }
        #expect(screen.activate(labelled: "Add workout"))
        try await screen.settleUntil { screen.element(labelled: "Start an empty workout") != nil }
        #expect(screen.activate(labelled: "Start an empty workout"))
        try await screen.settleUntil(timeout: 10) {
            guard let label = screen.element(labelled: "Workout duration")?.accessibilityLabel else { return false }
            return !label.hasSuffix("00:00:00")
        }

        // The placeholder is really on the plan — starting empty schedules it up front.
        let placeholder = try #require(soleScheduledWorkout(screen.plan), "empty start should schedule exactly one placeholder")
        #expect(screen.plan.days(from: placeholder.date, through: placeholder.date).first?.sessions.count == 1)
        try screen.capture("plan-empty-workout-live")

        // The real WorkoutView offers the provisional-discard affordance (removes the whole placeholder).
        #expect(screen.activate(labelled: "More workout actions"))
        try await screen.settle()
        #expect(anyLabel(screen, contains: "Discard Workout"),
                "empty workout's discard must read \"Discard Workout\", not \"Discard Log\"")
        #expect(anyLabel(screen, contains: "Discard Log") == false)
    }

    /// The fix, driven through the real `WorkoutView` and a faithful copy of Plan's execution seam:
    /// confirming the discard of a provisional empty workout dismisses the sheet (back to the Plan page)
    /// and purges the placeholder, so the day is undecided again — no stuck empty workout, no rest
    /// marker. Captures the returned-to-Plan surface as after-evidence.
    @Test func discardingAProvisionalEmptyWorkoutReturnsToPlanAndLeavesTheDayUndecided() async throws {
        let bed = try DiscardBed()
        let screen = try DiscardBed.Screen(bed: bed)
        defer { screen.tearDown() }
        try await screen.settle()

        // Live logging is up over the Plan root, and the placeholder is scheduled.
        #expect(screen.element(labelled: "Workout duration") != nil)
        #expect(bed.dayHasScheduledWorkout)
        #expect(screen.isPresentingSheet)

        // Confirm the discard: exactly what WorkoutView's "Discard Workout" button runs.
        bed.confirmDiscard()
        try await screen.settle()

        // (a) Back on the Plan page — the execution sheet is gone.
        #expect(screen.isPresentingSheet == false)
        #expect(screen.element(labelled: "Plan root") != nil)
        // (b) The day is undecided again — no scheduled workout, no rest marker.
        #expect(bed.dayHasScheduledWorkout == false)
        #expect(bed.dayIsRestDay == false)
        try screen.capture("plan-after-discard-empty")
    }

    /// The bug, pinned: the plain "Discard Log" action (`store.discardLog()` on the bound session) only
    /// marks the session discarded. The empty placeholder stays scheduled on the day, and the store
    /// flips to a viewable blank template rather than dismissing — which is exactly how the pre-fix build
    /// stranded the athlete on an Edit-Workout-looking screen with the empty workout stuck on the day.
    /// The fix routes the empty-workout discard through `purgeProvisional` + dismissal instead.
    @Test func plainDiscardLogLeavesAProvisionalEmptyWorkoutStuck() throws {
        let bed = try DiscardBed()
        #expect(bed.dayHasScheduledWorkout)

        bed.store.discardLog()   // the old confirmed-discard action, before the fix

        #expect(bed.dayHasScheduledWorkout)      // placeholder still stuck on the day
        #expect(bed.store.current != nil)        // store still shows a (blank) workout to view…
        #expect(bed.store.currentLog == nil)     // …in .view mode (no log) — not dismissed to Plan
    }

    /// The happy path the fix must not break: *completing* (not discarding) an empty workout keeps it on
    /// the day as a real, completed session.
    @Test func completingAnEmptyWorkoutKeepsItScheduled() throws {
        let bed = try DiscardBed()
        #expect(bed.dayHasScheduledWorkout)

        bed.store.completeWorkout(awaitingReconciliationDecision: false)

        #expect(bed.dayHasScheduledWorkout)                       // still scheduled
        #expect(bed.plan.completed(for: bed.scheduledID) != nil)  // and now a completed session
    }

    // MARK: - Helpers

    private func soleScheduledWorkout(_ plan: PlanStore) -> ScheduledWorkout? {
        let today = cal.startOfDay(for: Date())
        let days = plan.days(from: cal.date(byAdding: .day, value: -60, to: today)!,
                             through: cal.date(byAdding: .day, value: 120, to: today)!)
        let sessions = days.flatMap(\.sessions)
        return sessions.count == 1 ? sessions.first : nil
    }

    private func anyLabel(_ screen: MainTabShellScreen, contains text: String) -> Bool {
        let windows = (screen.window.windowScene?.windows ?? [screen.window]).filter { !$0.isHidden && $0.alpha > 0 }
        return windows.contains { window in
            AccessibilityElementWalker.elements(in: window).contains { $0.accessibilityLabel?.contains(text) ?? false }
        }
    }
}

// MARK: - Discard bed

/// A blank workout scheduled and started exactly as Plan's "Start an empty workout" does — a real plan,
/// a real bound `WorkoutStore`, and Plan's own discard-then-purge wiring reproduced so the confirmed
/// discard runs the real `purgeProvisional`.
@MainActor
@Observable
private final class DiscardBed {

    let plan: PlanStore
    let store: WorkoutStore
    let scheduledID: UUID
    let day: Date
    @ObservationIgnored let container: ModelContainer
    /// Mirrors Plan's `execContext` sheet item — the real `WorkoutView` is presented while `true`.
    var present = true
    /// Mirrors Plan's `queuedProvisionalPurgeID` → purge-on-dismiss deferral.
    private var queuedPurgeID: UUID?

    init() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(for: Schema(models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        plan = PlanStore(context: container.mainContext)
        day = Calendar.planWeek.startOfDay(for: Date())

        // Exactly PlanView.startEmptyWorkout: schedule a blank placeholder, bind, and start logging.
        let sw = plan.newScheduledWorkout(on: day)
        scheduledID = sw.id
        store = WorkoutStore(units: StubUnitSystem(),
                             defaults: try #require(UserDefaults(suiteName: "discard-\(UUID().uuidString)")))
        store.bind(plan.sink(forScheduled: sw.id), coalesceContent: true)
        store.startWorkout()
    }

    var dayHasScheduledWorkout: Bool {
        (plan.days(from: day, through: day).first?.sessions.isEmpty ?? true) == false
    }

    var dayIsRestDay: Bool {
        plan.days(from: day, through: day).first?.isRestDay ?? false
    }

    /// What WorkoutView's confirmed "Discard Workout" button runs — `onRequestDiscard()` (queue the
    /// purge) then `dismiss()` (drop the sheet). The purge itself runs in the sheet's real `onDismiss`.
    func confirmDiscard() {
        queuedPurgeID = scheduledID   // onRequestDiscard: { queuedProvisionalPurgeID = ctx.id }
        present = false               // WorkoutView's dismiss()
    }

    /// Plan's `flushExecution` purge branch, run from the sheet's `onDismiss`.
    func flushOnDismiss() {
        guard let id = queuedPurgeID else { return }
        queuedPurgeID = nil
        plan.purgeProvisional(id)
    }

    /// Plan's execution seam, faithfully reproduced: the real `WorkoutView` presented in a sheet over a
    /// Plan-root marker, with the same discard-callback and purge-on-dismiss wiring.
    @MainActor
    final class Screen: HostedScreen {
        let window: UIWindow

        init(bed: DiscardBed) throws {
            let root = Host(bed: bed)
                .modelContainer(bed.container)
                .preferredColorScheme(.dark)
            window = try Self.makeWindow(rootView: root)
        }

        var isPresentingSheet: Bool { window.rootViewController?.presentedViewController != nil }
    }

    private struct Host: View {
        @Bindable var bed: DiscardBed
        var body: some View {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                Text("Plan").accessibilityLabel("Plan root")
            }
            .sheet(isPresented: $bed.present, onDismiss: { bed.flushOnDismiss() }) {
                WorkoutView(onRequestDiscard: { bed.present = false })
                    .environment(bed.store)
                    .environment(bed.plan)
                    .environment(BluetoothManager())
                    .environment(OnboardingStore())
                    .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
            }
        }
    }
}
