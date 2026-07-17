import Foundation

/// Pure Z1…Z5 BPM ranges for the settings preview and the live spectrum, derived straight from a
/// `HeartRateZoneModel` so the displayed bands can never drift from the resolver that classifies a
/// live BPM.
///
/// Zone floors come from the model's shared `lowerBPM(for:)` accessor (one formula, consumed here
/// and by `HeartRateZoneStrip`); each upper is one below the next zone's floor, and Z5 closes at
/// `maxHR`.
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
        rows = HeartRateZone.allCases.map { zone in
            let lo = model.lowerBPM(for: zone)
            // Upper is one below the next zone's floor; Z5 is open-topped, closed at maxHR.
            let hi: Int
            if let next = HeartRateZone(rawValue: zone.rawValue + 1) {
                hi = max(lo, model.lowerBPM(for: next) - 1)
            } else {
                hi = max(lo, model.maxHR)
            }
            return Row(zone: zone, lowerBPM: lo, upperBPM: hi)
        }
    }
}
