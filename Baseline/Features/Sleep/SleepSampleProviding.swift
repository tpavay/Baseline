import Foundation

/// The orchestrator's window onto raw sleep data. `HealthService` is the real implementation;
/// tests inject fixture providers so backfill and delta-sync logic run without HealthKit.
///
/// Both methods are throwing so "no data" and "fetch failed" are distinguishable channels: an
/// empty result means the window is genuinely empty (HealthKit reports read denial that way
/// too), while a throw means transient failure — the orchestrator must hold its cursor and
/// retry rather than treat the night as gone. `HealthService`'s own conformance never throws
/// today; the channel exists so orchestration logic is honest about the difference.
@MainActor
protocol SleepSampleProviding {
    /// Mapped samples whose end falls inside `window`, plus the count of raw samples the
    /// mapping rejected (`@unknown default`).
    func sleepSamples(in window: DateInterval) async throws -> SleepSampleBatch
    /// New and deleted samples since `cursor` plus the cursor to persist next, bounded to
    /// samples starting at or after `start` — so a nil cursor (first sync) can never replay the
    /// athlete's entire Health sleep history, only the window the engine actually reasons over.
    func sleepSampleDelta(after cursor: Data?, startingFrom start: Date) async throws -> SleepSampleDelta
}
