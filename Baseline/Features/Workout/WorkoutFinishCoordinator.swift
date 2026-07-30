import Foundation
import Observation

/// Owns the "finish the session, then maybe offer to promote its edits" sequence.
///
/// It exists because the two steps have opposite timing requirements. The reconciliation must be
/// captured *synchronously and before* completion, so it describes the session that was actually
/// performed. The prompt must be presented *after* the finish review starts dismissing so SwiftUI
/// can transition cleanly from the sheet to the plan-reconciliation alert.
///
/// Keeping the sequence here rather than inside the view keeps it free of SwiftUI and testable.
@MainActor
@Observable
final class WorkoutFinishCoordinator {

    /// Non-nil ⇒ the session diverged from the plan ⇒ show the promotion prompt.
    var pendingReconciliation: WorkoutStore.SessionReconciliation?

    /// Capture, complete, and schedule the prompt. Returns the deferral task so callers (tests) can
    /// await the presentation without polling; the view ignores it.
    ///
    /// `heartRate` is captured by the caller from the live monitor and handed in here for the same
    /// timing reason as the reconciliation: completing the workout flips the presentation to
    /// `.completed`, which tears the monitor down, so anything read from it afterwards is already
    /// gone. Nil when no strap was streaming — that persists nothing rather than an empty record, and
    /// is still handed to the store so this run's "no heart rate" replaces any earlier run's answer.
    @discardableResult
    func finish(
        _ store: WorkoutStore,
        heartRate: WorkoutHeartRateCapture? = nil,
        durationSeconds: TimeInterval? = nil,
        finishedAt: Date = Date()
    ) -> Task<Void, Never>? {
        let reconciliation = store.captureSessionReconciliation()
        store.attachHeartRate(heartRate)
        // Most workouts are performed as planned, so no prompt appears — completion itself has to settle
        // the decision, or the session would stay the editing surface for the rest of the app's life.
        store.completeWorkout(
            awaitingReconciliationDecision: reconciliation != nil,
            durationSeconds: durationSeconds,
            finishedAt: finishedAt
        )
        guard let reconciliation else { return nil }
        return Task { @MainActor [weak self] in
            self?.pendingReconciliation = reconciliation
        }
    }

    func apply(_ reconciliation: WorkoutStore.SessionReconciliation, to store: WorkoutStore) {
        store.applySessionReconciliation(reconciliation)
        pendingReconciliation = nil
    }

    /// The athlete kept their original plan. Told to the store explicitly rather than left as the mere
    /// absence of an accept, so the session stops being the editing surface either way.
    func decline(_ store: WorkoutStore) {
        store.declineSessionReconciliation()
        pendingReconciliation = nil
    }
}
