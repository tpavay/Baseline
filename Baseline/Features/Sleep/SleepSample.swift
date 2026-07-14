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

    var start: Date
    var end: Date
    var kind: Kind
    /// Bundle identifier of the HealthKit source that wrote the sample.
    var sourceBundleID: String
    /// `HKDevice.model` when present ("Watch" identifies Apple Watch staged data).
    var deviceModel: String?
    /// HealthKit's was-user-entered metadata — routes the sample to the manual precedence tier.
    var isUserEntered: Bool

    init(start: Date, end: Date, kind: Kind, sourceBundleID: String,
         deviceModel: String? = nil, isUserEntered: Bool = false) {
        self.start = start
        self.end = end
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.deviceModel = deviceModel
        self.isUserEntered = isUserEntered
    }
}

/// One anchored-query step: the new samples since the previous cursor, plus the cursor to persist
/// for the next step. The `HKQueryAnchor` never leaves `HealthService` — callers hold opaque data.
struct SleepSampleDelta: Sendable {
    var samples: [SleepSample]
    var cursor: Data?
}
