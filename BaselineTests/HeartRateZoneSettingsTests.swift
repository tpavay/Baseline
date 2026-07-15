import Foundation
import Testing
@testable import Baseline

/// Slice-2 zone config: Tanaka default vs explicit override, validation that keeps a committed
/// config non-degenerate (AC-3/AC-4), honest method selection (AC-6), and a preview whose BPM ranges
/// equal the `HeartRateZoneModel` boundaries (AC-5). All inputs are controlled; no `Date()`.
struct HeartRateZoneSettingsTests {

    // MARK: - AC-3: max-HR default vs override

    @Test func maxHRDefaultsToTanakaWhenNoOverride() {
        let settings = HeartRateZoneSettings()
        // Tanaka(30) = 208 − 21 = 187, matching HeartRateZoneModel(age:).
        #expect(settings.resolvedMaxHR(ageYears: 30) == 187)
        #expect(settings.resolvedMaxHR(ageYears: 30) == HeartRateZoneModel(age: 30).maxHR)
    }

    @Test func explicitOverrideWinsAndIsNeverReplaced() {
        let settings = HeartRateZoneSettings(maxHROverride: 195)
        // Age 30 would estimate 187; the tested max wins regardless of age.
        #expect(settings.resolvedMaxHR(ageYears: 30) == 195)
        #expect(settings.resolvedMaxHR(ageYears: 60) == 195)
    }

    @Test func nilAgeUsesModelFallback() {
        #expect(HeartRateZoneSettings().resolvedMaxHR(ageYears: nil) == HeartRateZoneModel(age: nil).maxHR)
    }

    // MARK: - AC-6: method is honest about inputs

    @Test func methodIsHRRIffRestingSet() {
        #expect(HeartRateZoneSettings().method(ageYears: 30) == .percentMax)
        #expect(HeartRateZoneSettings(restingHR: 50).method(ageYears: 30) == .heartRateReserve)
        #expect(HeartRateZoneSettings(maxHROverride: 190, restingHR: 48).method(ageYears: 30) == .heartRateReserve)
    }

    @Test func outOfBandRestingDoesNotSilentlyBecomeHRR() {
        // Resting ≥ max is invalid, so it must not flip the method to HRR behind the athlete's back.
        let settings = HeartRateZoneSettings(maxHROverride: 120, restingHR: 120)
        #expect(settings.method(ageYears: 30) == .percentMax)
        #expect(settings.validatedRestingHR(ageYears: 30) == nil)
    }

    // MARK: - AC-4: validation keeps the model non-degenerate

    @Test func validConfigPasses() {
        #expect(HeartRateZoneSettings().validate(ageYears: 30) == nil)
        #expect(HeartRateZoneSettings(maxHROverride: 190, restingHR: 50, lthr: 168).validate(ageYears: 30) == nil)
    }

    @Test func rejectsRestingAtOrAboveMax() {
        // maxHROverride 120 (in range), resting 120 (in range) but not below max → the `restingHR <
        // maxHR` guard fires (the range check passes first, so this isolates the relationship rule).
        #expect(HeartRateZoneSettings(maxHROverride: 120, restingHR: 120).validate(ageYears: 30) == .restingNotBelowMax)
    }

    @Test func rejectsOutOfRangeMaxAndResting() {
        #expect(HeartRateZoneSettings(maxHROverride: 40).validate(ageYears: 30) == .maxHROutOfRange)
        #expect(HeartRateZoneSettings(maxHROverride: 300).validate(ageYears: 30) == .maxHROutOfRange)
        #expect(HeartRateZoneSettings(restingHR: 10).validate(ageYears: 30) == .restingHROutOfRange)
        #expect(HeartRateZoneSettings(restingHR: 190).validate(ageYears: 30) == .restingHROutOfRange)
    }

    @Test func rejectsLTHROutsideBand() {
        // Age 30 → max 187, band ⌈0.6·187⌉…187 = 113…187.
        #expect(HeartRateZoneSettings(lthr: 90).validate(ageYears: 30) == .lthrOutOfBand)
        #expect(HeartRateZoneSettings(lthr: 200).validate(ageYears: 30) == .lthrOutOfBand)
        #expect(HeartRateZoneSettings(lthr: 168).validate(ageYears: 30) == nil)
    }

    @Test func validatedModelRefusesInvalidConfig() {
        #expect(HeartRateZoneSettings(maxHROverride: 120, restingHR: 120).validatedModel(ageYears: 30) == nil)
        #expect(HeartRateZoneSettings(restingHR: 190).validatedModel(ageYears: 30) == nil)
    }

    @Test func validatedModelIsWellFormedZonesStrictlyIncreasing() {
        // Any committable config must yield strictly increasing zone floors (never degenerate).
        let configs = [
            HeartRateZoneSettings(),
            HeartRateZoneSettings(maxHROverride: 190),
            HeartRateZoneSettings(maxHROverride: 190, restingHR: 50),
            HeartRateZoneSettings(maxHROverride: 230, restingHR: 25, lthr: 200),
        ]
        for config in configs {
            let model = try! #require(config.validatedModel(ageYears: 30))
            let lowers = HeartRateZonePreview(model: model).rows.map(\.lowerBPM)
            for i in 1..<lowers.count { #expect(lowers[i] > lowers[i - 1]) }
        }
    }

    // MARK: - AC-5: preview ranges equal the model boundaries

    /// The preview must never re-derive zone math: every displayed BPM has to classify — via the
    /// model's own `zone(forBPM:)` — into exactly the zone it is shown under, and each boundary must
    /// be sharp (`lower − 1` falls into the previous zone).
    @Test func previewRangesMatchTheModel() {
        let models = [
            HeartRateZoneModel(maxHR: 200),                 // %max
            HeartRateZoneModel(maxHR: 185),                 // fractional %max thresholds
            HeartRateZoneModel(maxHR: 190, restingHR: 50),  // Karvonen
        ]
        for model in models {
            let rows = HeartRateZonePreview(model: model).rows
            #expect(rows.map(\.zone) == HeartRateZone.allCases)
            for row in rows {
                #expect(model.zone(forBPM: row.lowerBPM) == row.zone)
                #expect(model.zone(forBPM: row.upperBPM) == row.zone)
                if let previous = HeartRateZone(rawValue: row.zone.rawValue - 1) {
                    #expect(model.zone(forBPM: row.lowerBPM - 1) == previous)
                }
            }
            // Contiguous: each zone's upper is exactly one below the next zone's lower.
            for i in 1..<rows.count { #expect(rows[i].lowerBPM == rows[i - 1].upperBPM + 1) }
            // Z5 closes at maxHR.
            #expect(rows.last?.upperBPM == model.maxHR)
        }
    }

    @Test func previewHandComputedPercentMax() {
        let rows = HeartRateZonePreview(model: HeartRateZoneModel(maxHR: 200)).rows
        #expect(rows.map(\.lowerBPM) == [100, 120, 140, 160, 180])
        #expect(rows.map(\.upperBPM) == [119, 139, 159, 179, 200])
    }

    @Test func previewHandComputedKarvonen() {
        // maxHR 190, resting 50 → reserve 140. Lowers 120/134/148/162/176.
        let rows = HeartRateZonePreview(model: HeartRateZoneModel(maxHR: 190, restingHR: 50)).rows
        #expect(rows.map(\.lowerBPM) == [120, 134, 148, 162, 176])
        #expect(rows.map(\.upperBPM) == [133, 147, 161, 175, 190])
    }

    // MARK: - Shared boundary accessor (one formula, consumed by preview + strip)

    /// `lowerBPM(for:)` must agree with the classifier `zone(forBPM:)` at every boundary: the floor
    /// classifies into its own zone, and one below classifies into the previous zone (sharp divider).
    @Test func lowerBPMConsistentWithZoneForBPM() {
        let models = [
            HeartRateZoneModel(maxHR: 200),
            HeartRateZoneModel(maxHR: 185),
            HeartRateZoneModel(maxHR: 190, restingHR: 50),
            HeartRateZoneModel(age: 45, restingHR: 60),
        ]
        for model in models {
            for zone in HeartRateZone.allCases {
                let floor = model.lowerBPM(for: zone)
                #expect(model.zone(forBPM: floor) == zone)
                if let previous = HeartRateZone(rawValue: zone.rawValue - 1) {
                    #expect(model.zone(forBPM: floor - 1) == previous)
                }
            }
        }
    }

    // MARK: - Strip layout (pure geometry)

    @Test func stripLayoutWidthsProportionalAndFill() {
        let rows = HeartRateZonePreview(model: HeartRateZoneModel(maxHR: 200)).rows
        let width: CGFloat = 250
        let spacing: CGFloat = 2
        let layout = HeartRateZoneStripLayout(rows: rows, width: width, spacing: spacing)
        #expect(layout.widths.count == 5)
        // Widths (+ inter-segment gaps) fill the available width.
        let total = layout.widths.reduce(0, +) + spacing * CGFloat(rows.count - 1)
        #expect(abs(total - width) < 0.001)
        #expect(layout.widths.allSatisfy { $0 > 0 })
    }

    @Test func stripLayoutHandlesZeroWidth() {
        let rows = HeartRateZonePreview(model: HeartRateZoneModel(maxHR: 200)).rows
        let layout = HeartRateZoneStripLayout(rows: rows, width: 0, spacing: 2)
        #expect(layout.widths == [0, 0, 0, 0, 0])
    }
}
