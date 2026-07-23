import Foundation
import Testing
@testable import Baseline

/// The pure semicircular-gauge geometry: five Z1→Z5 segments across 180° whose sweeps are
/// **proportional to each zone's BPM span** in the athlete's model (never equal fifths), separated by
/// a fixed angular gap, plus the zone-local BPM→angle marker mapping that keeps the marker inside the
/// lit segment.
struct HeartRateZoneGaugeLayoutTests {

    private let gap = HeartRateZoneGaugeLayout.defaultGapDegrees
    private let eps = 0.0001

    /// Deliberately non-uniform zone floors (spans 20 / 20 / 15 / 10 / 25 BPM) — the case the gauge
    /// exists for: a wider-BPM zone must get a proportionally wider arc.
    private let nonUniformBounds: [Double] = [100, 120, 140, 155, 165, 190]

    // MARK: - Segments

    @Test func segmentsSpanTheSemicircleInZoneOrderWithGaps() {
        let layout = HeartRateZoneGaugeLayout(zoneBoundsBPM: nonUniformBounds)
        #expect(layout.segments.count == 5)
        #expect(layout.segments.map(\.zone) == HeartRateZone.allCases)

        // First starts at the left end (0°), last ends at the right end (180°), and each segment
        // starts exactly one gap after the previous one ends.
        #expect(abs(layout.segments.first!.startDegrees) < eps)
        #expect(abs(layout.segments.last!.endDegrees - 180) < eps)
        for index in 1..<layout.segments.count {
            let previous = layout.segments[index - 1]
            #expect(abs(previous.endDegrees + gap - layout.segments[index].startDegrees) < eps)
        }
    }

    @Test func sweepsAreProportionalToEachZonesBPMSpan() {
        let layout = HeartRateZoneGaugeLayout(zoneBoundsBPM: nonUniformBounds)
        let spans: [Double] = [20, 20, 15, 10, 25]
        let usable = 180 - gap * 4
        for (segment, span) in zip(layout.segments, spans) {
            #expect(abs(segment.sweepDegrees - usable * span / 90) < eps)
        }
        // The explicit headline: Z5 (25 BPM) is visibly wider than Z4 (10 BPM) — not equal fifths.
        #expect(layout.segments[4].sweepDegrees > layout.segments[3].sweepDegrees + 10)
    }

    /// Built from a real model whose integer floors round unevenly (max 187, resting 53 → spans
    /// 14 / 13 / 14 / 13 / 13), the sweeps still track the exact BPM spans.
    @Test func modelInitDerivesSpansFromTheModelsOwnBoundaries() {
        let model = HeartRateZoneModel(maxHR: 187, restingHR: 53)
        let layout = HeartRateZoneGaugeLayout(model: model)

        let floors = HeartRateZone.allCases.map { Double(model.lowerBPM(for: $0)) } + [Double(model.maxHR)]
        let spans = (0..<5).map { floors[$0 + 1] - floors[$0] }
        let total = spans.reduce(0, +)
        let usable = 180 - gap * 4
        for (segment, span) in zip(layout.segments, spans) {
            #expect(abs(segment.sweepDegrees - usable * span / total) < eps)
        }
        // This model is genuinely non-uniform: Z1's arc is wider than Z2's.
        #expect(layout.segments[0].sweepDegrees > layout.segments[1].sweepDegrees + eps)
    }

    @Test func degenerateBoundsFallBackToEqualSweepsInsteadOfCollapsing() {
        let layout = HeartRateZoneGaugeLayout(zoneBoundsBPM: [150, 150, 150, 150, 150, 150])
        let usable = 180 - gap * 4
        for segment in layout.segments {
            #expect(abs(segment.sweepDegrees - usable / 5) < eps)
        }
    }

    // MARK: - Marker mapping (BPM → angle)

    @Test func markerClampsToTheGaugeEnds() {
        let layout = HeartRateZoneGaugeLayout(zoneBoundsBPM: nonUniformBounds)
        #expect(layout.markerDegrees(forBPM: 60) == 0)
        #expect(layout.markerDegrees(forBPM: 100) == 0)
        #expect(abs(layout.markerDegrees(forBPM: 190) - 180) < eps)
        #expect(abs(layout.markerDegrees(forBPM: 240) - 180) < eps)
    }

    @Test func markerSitsAtTheZoneLocalFractionOfItsSegment() {
        let layout = HeartRateZoneGaugeLayout(zoneBoundsBPM: nonUniformBounds)
        // 130 BPM is exactly halfway through Z2 (120…140) → the Z2 segment's midpoint.
        let z2 = layout.segments[1]
        #expect(abs(layout.markerDegrees(forBPM: 130) - (z2.startDegrees + z2.sweepDegrees / 2)) < eps)
        // A zone floor maps to that zone's segment start (the boundary belongs to the higher zone,
        // matching `HeartRateZoneModel.zone(forBPM:)`).
        #expect(abs(layout.markerDegrees(forBPM: 155) - layout.segments[3].startDegrees) < eps)
    }

    /// For every BPM the marker angle falls inside the arc of the zone the model assigns — the
    /// marker and the lit segment can never disagree, even though the gaps make the scale piecewise.
    @Test func markerAlwaysLandsInsideItsZonesSegment() {
        let model = HeartRateZoneModel(maxHR: 190, restingHR: 50)
        let layout = HeartRateZoneGaugeLayout(model: model)
        for bpm in stride(from: 121, through: 189, by: 2) {
            let zone = model.zone(forBPM: bpm)
            let segment = layout.segments[zone.rawValue - 1]
            let degrees = layout.markerDegrees(forBPM: bpm)
            #expect(degrees >= segment.startDegrees - eps)
            #expect(degrees <= segment.endDegrees + eps)
        }
    }

    @Test func markerIsMonotonicInBPM() {
        let layout = HeartRateZoneGaugeLayout(zoneBoundsBPM: nonUniformBounds)
        var previous = -Double.infinity
        for bpm in 90...200 {
            let degrees = layout.markerDegrees(forBPM: bpm)
            #expect(degrees >= previous)
            previous = degrees
        }
    }
}
