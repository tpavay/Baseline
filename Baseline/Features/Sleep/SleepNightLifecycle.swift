import Foundation

/// When is a night's data trusted as stable? Watch sleep keeps syncing into HealthKit for a while
/// after wake, so a fetch made too soon sees a partial night. The rule: a sync happening at least
/// `interval` after wake has had time to receive the full night — anything earlier is provisional.
/// Injectable so tests (and future tuning) control it without touching the engine.
///
/// `complete` means "stable as of the last sync", NOT "the night's window has closed": the rule
/// keys on the *primary episode's* wake time, so a night whose only episode ends early (an
/// evening nap-only night, or split sleep whose first block ends before midnight) can read
/// `complete` while its noon-to-noon window is still open. That's safe — later samples in the
/// same window change the fingerprint and the night self-corrects to `revised` — but Slice 3+
/// must not treat a `complete` night as final until its window has actually passed.
struct SleepStabilizationRule: Equatable, Sendable {
    static let defaultInterval: TimeInterval = 2 * 60 * 60

    var interval: TimeInterval

    init(interval: TimeInterval = SleepStabilizationRule.defaultInterval) {
        self.interval = interval
    }

    func isStabilized(wakeTime: Date?, lastSyncAt: Date) -> Bool {
        guard let wakeTime else { return false }
        return lastSyncAt >= wakeTime.addingTimeInterval(interval)
    }
}

/// Pure provisional → complete → revised transitions: given the stored night and a freshly
/// assembled candidate, decide whether the store must write. Facts are immutable per source
/// revision — a changed fingerprint *replaces* the canonical night (same identity, `revision`
/// bumped), never mutates it in place.
enum SleepNightLifecycle {

    enum Outcome: Equatable, Sendable {
        /// The stored night stands — nothing to write (the idempotence guarantee).
        case unchanged(SleepNight)
        /// Write this night: first ingestion, provisional → complete upgrade, or a revision.
        case store(SleepNight)
    }

    static func reconcile(previous: SleepNight?, candidate: SleepNight?) -> Outcome? {
        switch (previous, candidate) {
        case (nil, nil):
            return nil
        case (nil, let candidate?):
            return .store(candidate)
        case (let previous?, nil):
            // The window can come back empty after a source deletes its data. Keeping recorded
            // facts beats silently erasing history; deletion handling lands with Slice 2 persistence.
            return .unchanged(previous)
        case (let previous?, let candidate?):
            guard candidate.sourceFingerprint == previous.sourceFingerprint else {
                var revised = candidate
                revised.id = previous.id
                revised.revision = previous.revision + 1
                revised.analysisStatus = .revised
                return .store(revised)
            }
            if previous.analysisStatus == .provisional, candidate.analysisStatus == .complete {
                var completed = previous
                completed.analysisStatus = .complete
                completed.lastHealthKitSyncAt = candidate.lastHealthKitSyncAt
                return .store(completed)
            }
            return .unchanged(previous)
        }
    }
}
