import Foundation

/// The small, always-cheap heart-rate facts about a completed workout: average, max, how many
/// samples backed them, seconds in each zone, and the zone boundaries in force when those seconds
/// were earned.
///
/// This is the part that rides on `WorkoutLog` (tens of bytes). The sample array never does — see
/// `SDWorkoutHeartRateSeries`. Everything here is a recorded aggregate of samples that actually
/// arrived, so it is honest about a dropout rather than fabricating coverage.
struct WorkoutHeartRateSummary: Codable, Equatable, Sendable {

    /// Rounded mean BPM over every recorded sample, nil when none arrived.
    let averageBPM: Int?
    /// Highest recorded BPM, nil when no sample arrived.
    let maxBPM: Int?
    /// How many samples the trace holds — the denominator behind `averageBPM`, and the cheap
    /// "is there anything to chart?" answer.
    let sampleCount: Int
    /// Seconds credited to Z1…Z5 in that order, always five entries.
    let zoneSeconds: [TimeInterval]
    /// The zone boundaries in force at completion, snapshotted so a later change to the athlete's
    /// max HR cannot silently re-band this workout's chart (see `baseline-live-heart-rate`: persist
    /// what is needed to explain or reproduce a historical zone boundary). Nil for a summary
    /// recorded without a model.
    let zoneModel: HeartRateZoneModelSnapshot?

    init(
        averageBPM: Int?,
        maxBPM: Int?,
        sampleCount: Int,
        zoneSeconds: [TimeInterval],
        zoneModel: HeartRateZoneModelSnapshot?
    ) {
        self.averageBPM = averageBPM
        self.maxBPM = maxBPM
        self.sampleCount = sampleCount
        // Normalize to exactly one entry per zone so every reader can index by ordinal without a
        // bounds check, and so `totalZoneSeconds` can never sum an entry no zone owns.
        var seconds = Array(zoneSeconds.prefix(HeartRateZone.allCases.count))
        seconds.append(contentsOf: Array(repeating: 0, count: HeartRateZone.allCases.count - seconds.count))
        self.zoneSeconds = seconds
        self.zoneModel = zoneModel
    }

    private enum CodingKeys: String, CodingKey {
        case averageBPM, maxBPM, sampleCount, zoneSeconds, zoneModel
    }

    /// Written out rather than synthesized so decoding runs the same normalization as construction.
    /// These records come off disk (`SDWorkoutHeartRateSeries.summaryJSON`, `WorkoutLog`), and a
    /// synthesized decoder would assign `zoneSeconds` verbatim — leaving the one invariant every
    /// reader relies on holding only for summaries this process happened to build itself.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            averageBPM: try container.decodeIfPresent(Int.self, forKey: .averageBPM),
            maxBPM: try container.decodeIfPresent(Int.self, forKey: .maxBPM),
            sampleCount: try container.decode(Int.self, forKey: .sampleCount),
            zoneSeconds: try container.decodeIfPresent([TimeInterval].self, forKey: .zoneSeconds) ?? [],
            zoneModel: try container.decodeIfPresent(HeartRateZoneModelSnapshot.self, forKey: .zoneModel)
        )
    }

    /// Whether this summary describes real measured heart rate. A summary with no samples is not
    /// evidence, and nothing user-facing should render from it.
    var hasEvidence: Bool { sampleCount > 0 && averageBPM != nil }

    func seconds(in zone: HeartRateZone) -> TimeInterval {
        zoneSeconds.indices.contains(zone.rawValue - 1) ? zoneSeconds[zone.rawValue - 1] : 0
    }

    /// Seconds per zone in Z1…Z5 order, paired with the zone, for a summary readout.
    var secondsByZoneOrdered: [(zone: HeartRateZone, seconds: TimeInterval)] {
        HeartRateZone.allCases.map { ($0, seconds(in: $0)) }
    }

    var totalZoneSeconds: TimeInterval { zoneSeconds.reduce(0, +) }

    /// The compact instrument readout used on both heart-rate cards ("AVG 142 · MAX 171 BPM").
    var readout: String? {
        guard let averageBPM, let maxBPM else { return nil }
        return "AVG \(averageBPM) · MAX \(maxBPM) BPM"
    }
}

/// A `HeartRateZoneModel` frozen into a persistable record.
///
/// `HeartRateZoneModel` is deliberately not `Codable` itself: its `method` is *derived* from whether
/// a resting HR is present, so a decoder able to set the two independently could mint a model whose
/// method contradicts its inputs. Rehydrating through the model's own initializer re-derives the
/// method from the same rule the live resolver uses, and the stored `method` stays the record of
/// what was actually applied.
struct HeartRateZoneModelSnapshot: Codable, Equatable, Sendable {
    let maxHR: Int
    let restingHR: Int?
    let lthr: Int?
    let method: HeartRateZoneModel.Method

    init(_ model: HeartRateZoneModel) {
        maxHR = model.maxHR
        restingHR = model.restingHR
        lthr = model.lthr
        method = model.method
    }

    var model: HeartRateZoneModel {
        HeartRateZoneModel(maxHR: maxHR, restingHR: restingHR, lthr: lthr)
    }
}
