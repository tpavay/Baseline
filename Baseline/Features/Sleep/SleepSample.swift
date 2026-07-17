import Foundation

/// A normalized raw sleep sample — the engine's input type. `HealthService` maps
/// `HKCategorySample`s into these (timestamps, stage, and source preserved, unlike the
/// aggregate `sleepSummary`), and tests build them directly so the whole ingestion pipeline
/// runs without HealthKit.
struct SleepSample: Equatable, Hashable, Sendable {

    enum Kind: String, Sendable {
        case inBed, asleepUnspecified, core, deep, rem, awake

        /// Counts toward asleep time (everything but `inBed` and `awake`).
        var isAsleep: Bool {
            switch self {
            case .asleepUnspecified, .core, .deep, .rem: true
            case .inBed, .awake: false
            }
        }

        /// True staged sleep — the marker of a stage-capable source (awake alone isn't).
        var isStagedSleep: Bool {
            switch self {
            case .core, .deep, .rem: true
            case .inBed, .asleepUnspecified, .awake: false
            }
        }

        /// The stage interval this sample produces; `inBed` produces none (it feeds
        /// `inBedHours`, not the timeline).
        var stage: SleepStage? {
            switch self {
            case .inBed: nil
            case .asleepUnspecified: .unspecified
            case .core: .core
            case .deep: .deep
            case .rem: .rem
            case .awake: .awake
            }
        }
    }

    /// HealthKit's sample UUID — the identity deletions arrive under (`HKDeletedObject.uuid`).
    /// Deliberately excluded from the fingerprint: the fingerprint contract is over the night's
    /// *content* (source, start, end, value), and a re-imported identical sample must not read
    /// as a revision just because HealthKit assigned it a fresh UUID.
    var uuid: UUID
    var start: Date
    var end: Date
    var kind: Kind
    /// Bundle identifier of the HealthKit source that wrote the sample.
    var sourceBundleID: String
    /// `HKDevice.model` when present ("Watch" identifies Apple Watch staged data).
    var deviceModel: String?
    /// HealthKit's was-user-entered metadata — routes the sample to the manual precedence tier.
    var isUserEntered: Bool

    init(uuid: UUID = UUID(), start: Date, end: Date, kind: Kind, sourceBundleID: String,
         deviceModel: String? = nil, isUserEntered: Bool = false) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.deviceModel = deviceModel
        self.isUserEntered = isUserEntered
    }
}

/// One window fetch's result: the mapped samples plus how many raw HealthKit samples were
/// rejected by the `@unknown default` mapping — surfaced as a count so silent data loss is
/// visible (never the values themselves; no health data is logged).
struct SleepSampleBatch: Sendable {
    var samples: [SleepSample]
    var droppedUnknownCount: Int = 0
}

/// One anchored-query step: the new samples since the previous cursor, the UUIDs HealthKit
/// reports as deleted, and the cursor to persist for the next step. The `HKQueryAnchor` never
/// leaves `HealthService` — callers hold opaque data.
struct SleepSampleDelta: Sendable {
    var samples: [SleepSample]
    var deletedSampleUUIDs: [UUID] = []
    var cursor: Data?
    var droppedUnknownCount: Int = 0
}
