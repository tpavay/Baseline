import Foundation

/// Pure Z1…Z5 BPM ranges for the settings preview, derived straight from a `HeartRateZoneModel` so
/// the displayed bands can never drift from the resolver that classifies a live BPM.
///
/// Each zone's inclusive lower BPM is `⌈threshold⌉` of the model's own `zoneLowerBounds` fraction
/// (Karvonen reserve when resting HR is set, else %max). Because the model's `zone(forBPM:)` uses
/// `bpm < threshold`, that ceiling is exactly the lowest integer BPM the model assigns to the zone —
/// verified in tests against `zone(forBPM:)` rather than re-derived there. Z5 closes at `maxHR`.
struct HeartRateZonePreview: Equatable {

    struct Row: Equatable, Identifiable {
        let zone: HeartRateZone
        let lowerBPM: Int
        let upperBPM: Int
        var id: Int { zone.rawValue }

        /// "120–133" — the inclusive integer band shown next to the zone name.
        var rangeText: String { "\(lowerBPM)–\(upperBPM)" }
    }

    let rows: [Row]

    init(model: HeartRateZoneModel) {
        // Inclusive lower BPM for each zone from the model's shared fraction table.
        func lower(_ zone: HeartRateZone) -> Int {
            let fraction = HeartRateZoneModel.zoneLowerBounds[zone.rawValue - 1]
            let threshold: Double
            if let restingHR = model.restingHR {
                threshold = Double(restingHR) + fraction * Double(model.maxHR - restingHR)
            } else {
                threshold = fraction * Double(model.maxHR)
            }
            return Int(threshold.rounded(.up))
        }

        rows = HeartRateZone.allCases.map { zone in
            let lo = lower(zone)
            // Upper is one below the next zone's floor; Z5 is open-topped, closed at maxHR.
            let hi: Int
            if let next = HeartRateZone(rawValue: zone.rawValue + 1) {
                hi = max(lo, lower(next) - 1)
            } else {
                hi = max(lo, model.maxHR)
            }
            return Row(zone: zone, lowerBPM: lo, upperBPM: hi)
        }
    }
}
