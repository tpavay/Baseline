import Foundation

/// A sleep stage as HealthKit models it. `unspecified` is generic "asleep" from sources that
/// don't stage (phone-only tracking, manual entries).
enum SleepStage: String, Codable, Sendable {
    case core, deep, rem, awake, unspecified

    /// Awake intervals sit inside a sleep episode but never count toward asleep time.
    var isAsleep: Bool { self != .awake }
}

/// One contiguous span of a single stage, with per-interval source provenance.
struct SleepStageInterval: Equatable, Hashable, Codable, Sendable {
    var stage: SleepStage
    var start: Date
    var end: Date
    var source: SleepSource

    var duration: TimeInterval { end.timeIntervalSince(start) }
}
