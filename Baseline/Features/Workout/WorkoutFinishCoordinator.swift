import Observation

/// Owns the "finish the session, then maybe offer to promote its edits" sequence.
///
/// It exists because the two steps have opposite timing requirements. The reconciliation must be
/// captured *synchronously and before* completion, so it describes the session that was actually
/// performed. The prompt must be presented *after* the finish confirmation has finished dismissing:
/// SwiftUI drops an alert that is raised from inside another alert's action handler in the same
/// runloop turn, which would silently kill the whole opt-in.
///
/// Keeping the sequence here rather than inside the view keeps it free of SwiftUI and testable.
@MainActor
@Observable
final class WorkoutFinishCoordinator {

    /// Non-nil ⇒ the session diverged from the plan ⇒ show the promotion prompt.
    var pendingReconciliation: WorkoutStore.SessionReconciliation?

    /// Capture, complete, and schedule the prompt. Returns the deferral task so callers (tests) can
    /// await the presentation without polling; the view ignores it.
    @discardableResult
    func finish(_ store: WorkoutStore) -> Task<Void, Never>? {
        let reconciliation = store.captureSessionReconciliation()
        store.completeWorkout()
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
