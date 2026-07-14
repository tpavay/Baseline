import Foundation

/// Derived, versioned analysis of one canonical `SleepNight` (plan §3). Pure value types with no
/// SwiftData/HealthKit/SwiftUI dependency — the whole struct is the Codable blob persisted on the
/// Slice 2 reserved fields (`SDSleepNight.analysisJSON`), so every member is `Codable`, `Equatable`,
/// and `Sendable`.
///
/// The engine (`SleepEngine`) is the only producer. Scoring lives entirely in `SleepEngine`; these
/// types just carry its results. The Apple-aligned score is **duration 50 / bedtime consistency 30 /
/// interruptions 20** — stage proportions are never scored (round-2 correction, AC-3); they live in
/// `additionalEvidence` for display only.

// MARK: - Reasons

/// Why a component is unavailable or a quality dimension is reduced. Stable keys, not user copy —
/// the UI maps them to strings. Descriptive only; never a stage→effect claim (AC-7).
enum SleepReason: String, Codable, Equatable, Sendable {
    case manualEntry
    case genericSource
    case unknownSource
    case trackingGap
    case insufficientHistoryForConsistency
    case noStageEvidenceForInterruptions
    case provisionalNight
    case noDuration
}

// MARK: - Components

/// One scored component with its earned value, its ceiling, and whether it was observable at all.
/// An unobservable component carries `value == 0` and `isAvailable == false` and contributes to
/// neither `observedPoints` nor `possiblePoints` (the no-renormalization rule, AC-2).
struct SleepComponent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case duration
        case bedtimeConsistency
        case interruptions
    }

    var kind: Kind
    /// Points earned (0 when unavailable). Kept as a Double so hand-computed fixtures pin exactly;
    /// the published `score` is the rounded sum of the available components.
    var value: Double
    /// The component ceiling: 50 / 30 / 20.
    var max: Double
    var isAvailable: Bool
}

// MARK: - Additional evidence (never scored)

/// Stage durations, distribution, timing and tracking gaps for the primary sleep — **displayed,
/// never scored** in v1 (AC-3). Two nights identical except for deep/REM distribution produce the
/// same score but different `SleepStageEvidence`.
struct SleepStageEvidence: Codable, Equatable, Sendable {
    var remMinutes: Double
    var deepMinutes: Double
    var coreMinutes: Double
    /// Fractions of asleep time (0 when asleep time is zero). Distribution only — not a claim.
    var remFraction: Double
    var deepFraction: Double
    var coreFraction: Double
    /// First asleep instant and final wake of the primary episode.
    var sleepOnset: Date?
    var finalWake: Date?
    /// Total tracking-gap minutes inside the primary episode window.
    var gapMinutes: Double
}

// MARK: - Evidence quality

/// Coverage, reliability and lifecycle status are **independent** (AC-4): a complete manual entry is
/// high-coverage (all the facts it can carry are present) but low-reliability (a self-report, not a
/// staged wearable). Each dimension records its reasons.
struct SleepEvidenceQuality: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case provisional, complete, revised
    }

    /// Fraction of the primary sleep window actually tracked (1 − gap fraction); 0 when no duration.
    var coverage: Double
    /// Source-class trust: staged wearable > generic phone inference > manual > none.
    var reliability: Double
    var status: Status
    var reasons: [SleepReason]
}

// MARK: - Comparison & consistency

/// Acute (7 d) vs chronic (30 d) asleep-hour means over **available** history, plus a 14-day sleep
/// debt (AC-5). Means exclude gap nights (nil when the window holds no recorded night); debt sums
/// only recorded nights below need — missing nights are never imputed.
struct SleepComparison: Codable, Equatable, Sendable {
    var acute7Mean: Double?
    var chronic30Mean: Double?
    var debt14Hours: Double
}

/// Circular (clock-arithmetic) bedtime/wake means and variability over the rolling 14-day window.
/// `isAvailable` is false during cold start (< 5 recorded nights, AC-2); the mean/variance are nil
/// then. Seconds-of-day anchored to each night's own local-midnight `date` — no calendar needed.
struct SleepConsistency: Codable, Equatable, Sendable {
    var bedtimeMeanSecondsOfDay: Double?
    var bedtimeStdMinutes: Double?
    var wakeMeanSecondsOfDay: Double?
    var wakeStdMinutes: Double?
    var recordedNights: Int
    var isAvailable: Bool
}

// MARK: - Flags

/// Notable-night flags. `bestIn`/`worstIn` are comparative (suppressed below 14 recorded nights and
/// capped at available history, AC-6); `scheduleShift`/`shortNight` fire on tunable thresholds.
enum SleepFlag: Codable, Equatable, Sendable {
    case bestIn(days: Int)
    case worstIn(days: Int)
    case scheduleShift(minutes: Double)
    case shortNight(hours: Double)
}

// MARK: - Decision evidence

/// The structured hand-off to Slice 4's `DecisionEngine` (AC-9): populated for observed nights,
/// nil-safe for partial ones, so the decision layer consumes it without recomputation.
struct SleepDecisionEvidence: Codable, Equatable, Sendable {
    /// Hours short of need (max(0, need − asleep)); nil when the night has no asleep time.
    var durationDeficitHours: Double?
    /// Normalized WASO burden 0…1; nil when interruptions are unobservable.
    var interruptionBurden: Double?
    /// |bedtime − rolling mean| in minutes; nil when consistency is unavailable.
    var scheduleShiftMinutes: Double?
}

// MARK: - Aggregate

/// The complete derived analysis for one night. `score` is non-nil only when all three components
/// are observed; otherwise `observedPoints/possiblePoints` describe the partial evidence with no
/// scaling (AC-2). Carries both engine versions so the store can re-derive lazily on a bump (AC-8).
struct SleepAnalysis: Codable, Equatable, Sendable {
    var observedPoints: Int
    var possiblePoints: Int
    var score: Int?
    /// Headline raw facts the analysis scored, echoed so display and `SleepInsights` are a pure
    /// function of the analysis blob (AC-7) without re-reading the source `SleepNight`. nil mirrors
    /// the night's own nils (unobservable, never imputed).
    var asleepHours: Double?
    var wasoMinutes: Double?
    var awakenings: Int?
    var components: [SleepComponent]
    var additionalEvidence: SleepStageEvidence
    var quality: SleepEvidenceQuality
    var vsBaseline: SleepComparison
    var consistency: SleepConsistency
    var flags: [SleepFlag]
    var decisionEvidence: SleepDecisionEvidence
    var aggregationVersion: Int
    var scoreAlgorithmVersion: Int

    /// Convenience: the earned points for a component kind, or nil when unavailable.
    func component(_ kind: SleepComponent.Kind) -> SleepComponent? {
        components.first { $0.kind == kind }
    }
}
