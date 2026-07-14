import Foundation

/// Lifecycle of a canonical night. HealthKit keeps delivering and revising samples after first
/// import, so facts are immutable *per source revision* and the canonical night is replaceable:
/// `provisional` while data may still arrive, `complete` once the source has stabilized, and
/// `revised` (with `revision` bumped) when a later delta changes the composing samples.
enum SleepAnalysisStatus: String, Codable, Sendable {
    case provisional, complete, revised
}

/// Canonical sleep facts for one recovery day — the replaceable output of `SleepIngestionEngine`.
/// Pure value type: no scoring, no SwiftData, no HealthKit. Duration metrics come from the
/// primary episode only; naps are retained as extra episodes without inflating them.
struct SleepNight: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    /// The recovery day this night belongs to (start of the wake day; noon-to-noon assignment).
    var date: Date
    var episodes: [SleepEpisode]
    /// Primary episode bounds.
    var bedtime: Date?
    var wakeTime: Date?
    /// Asleep time in the primary episode (union of asleep-stage intervals, gaps excluded).
    var asleepHours: Double?
    /// In-bed time from the resolved source's `inBed` samples; nil when the source records none.
    var inBedHours: Double?
    /// Awakening count / wake-after-sleep-onset inside the primary asleep window. nil for sources
    /// that can't observe awakenings (generic asleep, manual) — never imputed to zero.
    var awakenings: Int?
    var wasoMinutes: Double?
    /// Winner of the multi-source precedence resolution; losing sources are dropped, never merged.
    var resolvedSource: SleepSource
    var analysisStatus: SleepAnalysisStatus
    /// Deterministic digest of the normalized samples composing this night (see
    /// `SleepIngestionEngine.fingerprint`). Unchanged fingerprint ⇒ the stored night stands.
    var sourceFingerprint: String
    var lastHealthKitSyncAt: Date?
    var lastSampleEndDate: Date?
    /// Bumps on every canonical replacement (fingerprint change). 0 for a first ingestion.
    var revision: Int
    var factsSchemaVersion: Int

    var primaryEpisode: SleepEpisode? { episodes.first { $0.isPrimary } }
}
