import SwiftUI

/// Pure semicircular-gauge geometry for `HeartRateZoneGauge` — segment sweeps and the marker angle
/// are computed here, in degrees, so the whole layout is unit-testable without a view tree and is
/// resolution-independent (the view scales it onto whatever width it is given).
///
/// The five zones are laid out left (Z1) → right (Z5) across a 180° semicircle with a fixed angular
/// gap between neighbours. Each segment's sweep is **proportional to that zone's BPM span** in the
/// athlete's actual `HeartRateZoneModel` (Z1 span = Z2 floor − Z1 floor, …, Z5 span = maxHR − Z5
/// floor) — never equal fifths — so a zone covering more beats-per-minute occupies a visibly wider
/// arc. The marker maps a BPM *within its zone's own segment* (zone-local fraction → segment angle),
/// which guarantees the marker always sits inside the lit segment even though the gaps make the
/// overall angle scale piecewise — the marker and the zone coloring can never disagree.
struct HeartRateZoneGaugeLayout: Equatable {

    /// One zone's arc. Angles are "sweep degrees": 0 at the gauge's left end (bottom of Z1),
    /// 180 at its right end (top of Z5), increasing clockwise across the semicircle.
    struct Segment: Equatable {
        let zone: HeartRateZone
        let startDegrees: Double
        let endDegrees: Double

        var sweepDegrees: Double { endDegrees - startDegrees }
    }

    /// The angular gap between neighbouring segments, matched to the approved mock.
    static let defaultGapDegrees: Double = 6

    let segments: [Segment]

    /// Ascending BPM bounds the segments were built from: `[z1 floor, z2 floor, …, z5 floor, maxHR]`.
    /// Retained for the zone-local marker mapping.
    private let boundsBPM: [Double]

    /// Build the gauge from the athlete's actual zone model: floors from the model's shared
    /// `lowerBPM(for:)` accessor and the top from `maxHR`, so the arcs can never drift from the
    /// resolver that classifies a live BPM.
    init(model: HeartRateZoneModel, gapDegrees: Double = HeartRateZoneGaugeLayout.defaultGapDegrees) {
        self.init(
            zoneBoundsBPM: HeartRateZone.allCases.map { Double(model.lowerBPM(for: $0)) } + [Double(model.maxHR)],
            gapDegrees: gapDegrees
        )
    }

    /// - Parameter zoneBoundsBPM: six ascending BPM bounds (five zone floors + the Z5 top). A
    ///   non-increasing pair contributes a zero span (that segment collapses); if every span is zero
    ///   the segments fall back to equal sweeps so the gauge still renders a frame of reference.
    init(zoneBoundsBPM: [Double], gapDegrees: Double = HeartRateZoneGaugeLayout.defaultGapDegrees) {
        let zones = HeartRateZone.allCases
        var bounds = zoneBoundsBPM
        // Sanitize to an ascending sequence of the exact expected length so spans are never negative.
        if bounds.count != zones.count + 1 { bounds = Array(repeating: 0, count: zones.count + 1) }
        for index in 1..<bounds.count { bounds[index] = max(bounds[index], bounds[index - 1]) }
        boundsBPM = bounds

        let spans = (0..<zones.count).map { bounds[$0 + 1] - bounds[$0] }
        let totalSpan = spans.reduce(0, +)
        let weights = totalSpan > 0 ? spans.map { $0 / totalSpan } : spans.map { _ in 1.0 / Double(zones.count) }

        let gap = min(max(gapDegrees, 0), 180 / Double(zones.count))
        let usable = 180 - gap * Double(zones.count - 1)
        var cursor = 0.0
        segments = zip(zones, weights).map { zone, weight in
            let sweep = usable * weight
            defer { cursor += sweep + gap }
            return Segment(zone: zone, startDegrees: cursor, endDegrees: cursor + sweep)
        }
    }

    /// The marker's sweep angle for a live BPM: locate the zone whose `[floor, next floor)` band
    /// contains it (the same rule as `HeartRateZoneModel.zone(forBPM:)`), then interpolate the
    /// within-zone fraction across that segment's own arc. Below the Z1 floor pins to the gauge
    /// start, at or above maxHR to the gauge end.
    func markerDegrees(forBPM bpm: Int) -> Double {
        guard let first = segments.first, let last = segments.last,
              let low = boundsBPM.first, let high = boundsBPM.last else { return 0 }
        let value = Double(bpm)
        if value <= low { return first.startDegrees }
        if value >= high { return last.endDegrees }

        for (index, segment) in segments.enumerated() {
            let floor = boundsBPM[index]
            let ceiling = boundsBPM[index + 1]
            guard value < ceiling || segment.zone == .z5 else { continue }
            let fraction = ceiling > floor ? (value - floor) / (ceiling - floor) : 0
            return segment.startDegrees + fraction * segment.sweepDegrees
        }
        return last.endDegrees
    }
}

/// The redesigned live-HR hero: a semicircular Z1→Z5 zone gauge whose arcs wrap around nested center
/// content (the big BPM readout), with the current zone lit, the others dimmed, and a radial marker
/// line at the athlete's exact BPM position whose zone-colored glow pulses at the live heart rate.
///
/// All geometry comes from `HeartRateZoneGaugeLayout`, so `body` only draws. When there is no live
/// reading (`bpm == nil`) the marker is hidden and every segment dims — the gauge still communicates
/// the athlete's zone bands but claims no live position.
struct HeartRateZoneGauge<CenterContent: View>: View {
    /// The athlete's zone boundaries — segment widths and the marker angle derive from it.
    let model: HeartRateZoneModel
    /// The live BPM placing the marker (and pacing its pulse), or nil to hide the marker.
    var bpm: Int?
    /// The zone to light. nil dims the whole gauge (no live reading).
    var currentZone: HeartRateZone?
    /// Accessible summary spoken for the gauge (current zone + BPM, or a no-signal reason).
    var accessibilitySummary: String
    @ViewBuilder var centerContent: CenterContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Design-space constants from the approved mock (base width 220); the view scales them by
    // `width / designWidth` so the gauge renders identically at any size.
    private static var designWidth: CGFloat { 220 }
    private static var designHeight: CGFloat { 130 }
    private static var arcRadius: CGFloat { 95 }
    private static var arcLineWidth: CGFloat { 14 }
    private static var arcCenterY: CGFloat { 112 }
    private static var markerHalfLength: CGFloat { 16 }
    private static var markerMidRadius: CGFloat { 94 }
    private static var markerLineWidth: CGFloat { 3.5 }
    private static var centerContentY: CGFloat { 76 }
    private static var endLabelY: CGFloat { 120 }

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.width / Self.designWidth
            let layout = HeartRateZoneGaugeLayout(model: model)
            ZStack {
                arcs(layout, unit: unit)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Heart rate zones")
                    .accessibilityValue(accessibilitySummary)
                if let bpm {
                    marker(at: layout.markerDegrees(forBPM: bpm), bpm: bpm, unit: unit)
                        .accessibilityHidden(true)
                }
                endLabels(unit: unit)
                    .accessibilityHidden(true)
                centerContent
                    .position(x: geo.size.width / 2, y: Self.centerContentY * unit)
            }
        }
        .aspectRatio(Self.designWidth / Self.designHeight, contentMode: .fit)
    }

    // MARK: - Layers

    /// Five stroked arcs, butt-capped so the angular gaps read as clean radial slots (per the mock).
    private func arcs(_ layout: HeartRateZoneGaugeLayout, unit: CGFloat) -> some View {
        ZStack {
            ForEach(layout.segments, id: \.zone) { segment in
                GaugeArcShape(startDegrees: segment.startDegrees, endDegrees: segment.endDegrees)
                    .stroke(segment.zone.color,
                            style: StrokeStyle(lineWidth: Self.arcLineWidth * unit, lineCap: .butt))
                    .opacity(fillOpacity(isCurrent: segment.zone == currentZone))
            }
        }
    }

    /// The live-position marker: a bright radial tick crossing the arc band at the BPM's exact angle,
    /// glowing in the current zone's color. The glow pulses on the athlete's actual beat cadence
    /// (one cycle per 60/BPM seconds); with Reduce Motion it holds a steady mid glow instead.
    private func marker(at degrees: Double, bpm: Int, unit: CGFloat) -> some View {
        let glowColor = currentZone?.color ?? BaselineColor.textMid
        return Group {
            if reduceMotion {
                markerTick(at: degrees, glow: glowColor, intensity: 0.6, unit: unit)
            } else {
                TimelineView(.animation) { context in
                    let seconds = context.date.timeIntervalSinceReferenceDate
                    let beat = (sin(2 * .pi * seconds * Double(max(bpm, 1)) / 60) + 1) / 2
                    markerTick(at: degrees, glow: glowColor, intensity: beat, unit: unit)
                }
            }
        }
    }

    private func markerTick(at degrees: Double, glow: Color, intensity: Double, unit: CGFloat) -> some View {
        Capsule()
            .fill(BaselineColor.textHi)
            .frame(width: Self.markerLineWidth * unit, height: Self.markerHalfLength * 2 * unit)
            .shadow(color: glow.opacity(0.5 + 0.5 * intensity), radius: (2 + 7 * intensity) * unit)
            .opacity(0.8 + 0.2 * intensity)
            .position(x: Self.designWidth / 2 * unit, y: (Self.arcCenterY - Self.markerMidRadius) * unit)
            .rotationEffect(.degrees(degrees - 90),
                            anchor: UnitPoint(x: 0.5, y: Self.arcCenterY / Self.designHeight))
            .animation(.easeInOut(duration: 0.45), value: degrees)
    }

    /// "Z1" / "Z5" end anchors under the open ends of the semicircle, purely orienting (the summary
    /// carries the accessible meaning).
    private func endLabels(unit: CGFloat) -> some View {
        ForEach([(HeartRateZone.z1, -1.0), (HeartRateZone.z5, 1.0)], id: \.0) { zone, side in
            Text(zone.displayName)
                .font(.bMono(10, .medium)).tracking(1)
                .foregroundStyle(BaselineColor.textFaint)
                .position(x: (Self.designWidth / 2 + side * Self.arcRadius) * unit,
                          y: Self.endLabelY * unit)
        }
    }

    private func fillOpacity(isCurrent: Bool) -> Double {
        if currentZone == nil { return 0.35 }   // no live reading — dim the whole gauge
        return isCurrent ? 1 : 0.3
    }
}

/// One zone's arc as a strokeable shape. Sweep degrees (0 = left end, 180 = right end) convert to
/// screen angles by offsetting 180° — SwiftUI measures angles clockwise from +x with y down, so the
/// semicircle's left end is 180°, its top 270°, its right end 360°.
private struct GaugeArcShape: Shape {
    let startDegrees: Double
    let endDegrees: Double

    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 220
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: 112 * unit),
                    radius: 95 * unit,
                    startAngle: .degrees(180 + startDegrees),
                    endAngle: .degrees(180 + endDegrees),
                    clockwise: false)
        return path
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func gaugePreview(bpm: Int?, model: HeartRateZoneModel = HeartRateZoneModel(maxHR: 190, restingHR: 50)) -> some View {
    let zone = bpm.map { model.zone(forBPM: $0) }
    return HeartRateZoneGauge(
        model: model,
        bpm: bpm,
        currentZone: zone,
        accessibilitySummary: zone.map { "Current zone \($0.displayName) \($0.title)" } ?? "No live zone"
    ) {
        VStack(spacing: 4) {
            Text(bpm.map(String.init) ?? "--")
                .font(.bMono(64, .bold))
                .foregroundStyle(zone?.color ?? BaselineColor.textFaint)
            Text("BPM")
                .font(.bMono(11, .medium)).tracking(3)
                .foregroundStyle(BaselineColor.textFaint)
        }
    }
    .frame(width: 296)
    .padding(24)
    .background(BaselineColor.base)
}

#Preview("Gauge · Z3 · dark") { gaugePreview(bpm: 152).preferredColorScheme(.dark) }
#Preview("Gauge · Z1 low · dark") { gaugePreview(bpm: 112).preferredColorScheme(.dark) }
#Preview("Gauge · Z5 top · dark") { gaugePreview(bpm: 189).preferredColorScheme(.dark) }
#Preview("Gauge · no reading · dark") { gaugePreview(bpm: nil).preferredColorScheme(.dark) }
#endif
