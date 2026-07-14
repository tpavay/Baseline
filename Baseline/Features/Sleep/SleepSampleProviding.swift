import Foundation

/// The orchestrator's window onto raw sleep data. `HealthService` is the real implementation;
/// tests inject fixture providers so backfill and delta-sync logic run without HealthKit.
@MainActor
protocol SleepSampleProviding {
    /// Normalized raw samples whose end falls inside `window`. Empty when Health is unavailable
    /// or access was denied — HealthKit reports read denial as no data, never as an error.
    func sleepSamples(in window: DateInterval) async -> [SleepSample]
    /// New samples since `cursor` (nil = from the beginning) plus the cursor to persist next.
    func sleepSampleDelta(after cursor: Data?) async -> SleepSampleDelta
}
