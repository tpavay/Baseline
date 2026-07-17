import CoreGraphics
import Testing
@testable import Baseline

/// AC-1/AC-2: the pure spectrum geometry. Segments partition the bar into five contiguous zones, the
/// marker sits at `position · width` (monotonic, clamped), and the optional target band is present
/// exactly when a valid target is supplied and located on that zone's segment.
struct HeartRateZoneSpectrumLayoutTests {

    private let width: CGFloat = 300
    private let eps: CGFloat = 0.0001

    // MARK: - AC-1: segments

    @Test func fiveContiguousSegmentsSpanFullWidth() {
        let layout = HeartRateZoneSpectrumLayout(position: 0, targetZones: nil, width: width)
        #expect(layout.segments.count == 5)
        #expect(layout.segments.map(\.zone) == HeartRateZone.allCases)

        // First starts at 0, last ends at width, each starts where the previous ends (contiguous).
        #expect(abs(layout.segments.first!.x) < eps)
        let last = layout.segments.last!
        #expect(abs(last.x + last.width - width) < eps)
        for i in 1..<layout.segments.count {
            let previous = layout.segments[i - 1]
            #expect(abs(previous.x + previous.width - layout.segments[i].x) < eps)
        }
    }

    @Test func evenlySpacedBoundsGiveEqualFifths() {
        // The shipped boundary table is evenly spaced, so each zone is one fifth of the bar.
        let layout = HeartRateZoneSpectrumLayout(position: 0, targetZones: nil, width: width)
        for segment in layout.segments {
            #expect(abs(segment.width - width / 5) < eps)
        }
    }

    @Test func segmentWidthsSumToFullWidth() {
        let layout = HeartRateZoneSpectrumLayout(position: 0, targetZones: nil, width: width)
        let total = layout.segments.reduce(0) { $0 + $1.width }
        #expect(abs(total - width) < eps)
    }

    // MARK: - AC-1: marker

    @Test func markerIsPositionTimesWidth() {
        #expect(abs(HeartRateZoneSpectrumLayout(position: 0.5, targetZones: nil, width: width).markerX - 150) < eps)
        #expect(abs(HeartRateZoneSpectrumLayout(position: 0.0, targetZones: nil, width: width).markerX - 0) < eps)
        #expect(abs(HeartRateZoneSpectrumLayout(position: 1.0, targetZones: nil, width: width).markerX - width) < eps)
    }

    @Test func markerClampsAtEnds() {
        #expect(HeartRateZoneSpectrumLayout(position: -0.5, targetZones: nil, width: width).markerX == 0)
        #expect(HeartRateZoneSpectrumLayout(position: 2.0, targetZones: nil, width: width).markerX == width)
    }

    @Test func markerIsMonotonicInPosition() {
        let positions = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
        let xs = positions.map { HeartRateZoneSpectrumLayout(position: $0, targetZones: nil, width: width).markerX }
        for i in 1..<xs.count {
            #expect(xs[i] >= xs[i - 1])
        }
    }

    /// Fed real model positions for increasing BPM, the marker only moves right — the honest link
    /// between BPM and the on-bar position.
    @Test func markerIsMonotonicInBPMViaModel() {
        let model = HeartRateZoneModel(maxHR: 190, restingHR: 50)
        let bpms = [100, 120, 140, 160, 180, 200]
        let xs = bpms.map {
            HeartRateZoneSpectrumLayout(position: model.position(forBPM: $0), targetZones: nil, width: width).markerX
        }
        for i in 1..<xs.count {
            #expect(xs[i] >= xs[i - 1])
        }
        // Clamped ends: below Z1 pins to 0, at/above max pins to the far edge.
        #expect(xs.first! == 0)
        #expect(abs(xs.last! - width) < eps)
    }

    /// The marker lands inside the colored segment of the zone that BPM belongs to (marker ↔ color
    /// can never disagree) — the invariant that makes the spectrum trustworthy.
    @Test func markerFallsInsideItsZonesSegment() {
        let model = HeartRateZoneModel(maxHR: 190, restingHR: 50)
        for bpm in stride(from: 121, through: 189, by: 4) {
            let zone = model.zone(forBPM: bpm)
            let layout = HeartRateZoneSpectrumLayout(position: model.position(forBPM: bpm),
                                                     targetZones: nil, width: width)
            let segment = layout.segments[zone.rawValue - 1]
            #expect(layout.markerX >= segment.x - eps)
            #expect(layout.markerX <= segment.x + segment.width + eps)
        }
    }

    // MARK: - AC-2: target band (single zone or a range)

    @Test func targetBandPresentOnlyWhenTargetSupplied() {
        #expect(HeartRateZoneSpectrumLayout(position: 0.5, targetZones: nil, width: width).targetBand == nil)
        // A single-zone target is an n...n band matching exactly that one segment.
        for zone in HeartRateZone.allCases {
            let layout = HeartRateZoneSpectrumLayout(position: 0.5, targetZones: zone.rawValue...zone.rawValue, width: width)
            let segment = layout.segments[zone.rawValue - 1]
            #expect(layout.targetBand?.x == segment.x)
            #expect(layout.targetBand?.width == segment.width)
        }
    }

    @Test func targetBandRectMatchesItsSegment() {
        let layout = HeartRateZoneSpectrumLayout(position: 0.5, targetZones: 4...4, width: width)
        let band = layout.targetBand
        let segment = layout.segments[3] // Z4
        #expect(band?.x == segment.x)
        #expect(band?.width == segment.width)
    }

    /// A multi-zone target ("live in Z1–Z2") spans one continuous band from the low zone's leading
    /// edge to the high zone's trailing edge.
    @Test func targetBandSpansAZoneRange() {
        let layout = HeartRateZoneSpectrumLayout(position: 0.5, targetZones: 1...2, width: width)
        let z1 = layout.segments[0], z2 = layout.segments[1]
        #expect(abs((layout.targetBand?.x ?? -1) - z1.x) < eps)
        #expect(abs((layout.targetBand?.width ?? -1) - (z2.x + z2.width - z1.x)) < eps)
    }

    @Test func targetBandClampsAndDropsFullyOutOfRange() {
        // Clamped into 1…5: 0…2 → Z1–Z2; 4…9 → Z4–Z5.
        let low = HeartRateZoneSpectrumLayout(position: 0.5, targetZones: 0...2, width: width)
        #expect(abs((low.targetBand?.width ?? -1) - 2 * width / 5) < eps)
        let high = HeartRateZoneSpectrumLayout(position: 0.5, targetZones: 4...9, width: width)
        #expect(abs((high.targetBand?.width ?? -1) - 2 * width / 5) < eps)
        // Entirely outside 1…5 → no band.
        #expect(HeartRateZoneSpectrumLayout(position: 0.5, targetZones: 7...9, width: width).targetBand == nil)
    }

    /// The target band is a distinct concept from the marker/current-zone: a target on a different
    /// zone than where the marker sits is fully supported (the two never collapse into one).
    @Test func targetCanDifferFromMarkerZone() {
        let model = HeartRateZoneModel(maxHR: 190, restingHR: 50)
        // Live in Z2, target Z4.
        let layout = HeartRateZoneSpectrumLayout(position: model.position(forBPM: 138),
                                                 targetZones: 4...4, width: width)
        let z4 = layout.segments[3]
        #expect(layout.targetBand?.x == z4.x)
        let markerZoneIndex = Int(layout.markerX / (width / 5))
        #expect(markerZoneIndex != 3)
    }
}
