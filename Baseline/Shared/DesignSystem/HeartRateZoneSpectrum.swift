import SwiftUI

/// Pure segment/marker/target geometry for `HeartRateZoneSpectrum` — the whole layout is unit-testable
/// without a view tree, and the view `body` only draws what this returns.
///
/// The five zones are laid out as **contiguous** fractional segments in the *same* position space as
/// `HeartRateZoneModel.position(forBPM:)`, so the marker (placed at `position · width`) always lands
/// inside the colored segment of the zone that BPM belongs to — the marker and the coloring can never
/// disagree. Fractional edges are derived from the model's shared `zoneLowerBounds` (not hard-coded),
/// so if that boundary table is ever retuned the segments follow it automatically.
struct HeartRateZoneSpectrumLayout: Equatable {

    /// One colored zone segment, positioned along the bar's width.
    struct Segment: Equatable {
        let zone: HeartRateZone
        let x: CGFloat
        let width: CGFloat
    }

    /// A contiguous outlined band spanning the planned target zone(s), in bar coordinates.
    struct TargetBand: Equatable {
        let x: CGFloat
        let width: CGFloat
    }

    let segments: [Segment]
    /// Marker centre x = clamped(position) · width. Monotonic in position, clamped to `[0, width]`.
    let markerX: CGFloat
    /// The planned target band spanning the target zone(s) — from the low zone's leading edge to the
    /// high zone's trailing edge — or nil when no (valid) target is supplied. A single-zone target is
    /// just a one-segment band, so the view draws one continuous outline for either case.
    let targetBand: TargetBand?

    /// - Parameters:
    ///   - position: 0…1 marker position across the whole Z1→Z5 span (from `position(forBPM:)`).
    ///     Clamped here so an out-of-range value pins to an end rather than escaping the bar.
    ///   - targetZones: optional planned zone range (each bound 1…5; a single zone is `n...n`).
    ///     nil or a range with no overlap of 1…5 yields no band.
    ///   - width: available bar width.
    init(position: Double, targetZones: ClosedRange<Int>?, width: CGFloat) {
        // Fractional left edges of z1…z5 within the span, derived from the model's shared boundary
        // table. Rebased so Z1's bottom (`bounds[0]`) sits at 0 and Z5's top (1.0·maxHR) at 1 — the
        // exact transform `position(forBPM:)` applies, which is why `position` indexes these cleanly.
        let bounds = HeartRateZoneModel.zoneLowerBounds
        let base = bounds.first ?? 0
        let span = 1.0 - base
        var edges: [CGFloat] = bounds.map { span > 0 ? CGFloat(($0 - base) / span) : 0 }
        edges.append(1.0) // trailing edge = top of Z5

        let usableWidth = max(width, 0)
        segments = HeartRateZone.allCases.enumerated().map { index, zone in
            let leading = edges[index] * usableWidth
            let trailing = edges[index + 1] * usableWidth
            return Segment(zone: zone, x: leading, width: max(trailing - leading, 0))
        }

        let clamped = min(max(position, 0), 1)
        markerX = CGFloat(clamped) * usableWidth

        // Clamp the requested range into 1…5; span from the low segment's leading edge to the high
        // segment's trailing edge. A single zone (n...n) collapses to that one segment's rect.
        if let targetZones {
            let lo = max(targetZones.lowerBound, 1), hi = min(targetZones.upperBound, HeartRateZone.allCases.count)
            if lo <= hi {
                let low = segments[lo - 1], high = segments[hi - 1]
                targetBand = TargetBand(x: low.x, width: max((high.x + high.width) - low.x, 0))
            } else {
                targetBand = nil
            }
        } else {
            targetBand = nil
        }
    }
}

/// The hero live component: a full-width Z1→Z5 colored spectrum with the **current** zone emphasized,
/// a **marker** at the athlete's live position, and an optional **planned target-zone** outline —
/// deliberately "not just a dot". Pure over `(currentZone, position, targetZone)`; all geometry comes
/// from `HeartRateZoneSpectrumLayout`, so `body` only draws.
///
/// Emphasis vs. target are intentionally different visual languages so they never read as the same
/// thing: the current zone is *filled and taller*, the target zone is a *hairline outline*. When no
/// live position is available (`position == nil`) the marker is hidden and the segments dim — the
/// spectrum still communicates the zones, but claims no live reading.
struct HeartRateZoneSpectrum: View {
    /// The live zone to emphasize, or nil when there is no fresh reading (dims the whole bar).
    var currentZone: HeartRateZone?
    /// Live marker position 0…1, or nil to hide the marker (no live reading).
    var position: Double?
    /// Optional planned target zone range (each bound 1…5; a single zone is `n...n`) to outline.
    var targetZones: ClosedRange<Int>?
    /// Accessible summary spoken by VoiceOver (current zone + BPM, or a no-signal reason).
    var accessibilitySummary: String

    private let baseHeight: CGFloat = 18
    private let currentHeight: CGFloat = 30
    private let segmentSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let layout = HeartRateZoneSpectrumLayout(position: position ?? 0,
                                                     targetZones: targetZones, width: width)
            ZStack(alignment: .bottomLeading) {
                segmentsLayer(layout)
                if let band = layout.targetBand {
                    targetOutline(band)
                }
                if position != nil {
                    marker(at: layout.markerX)
                }
            }
            .frame(height: currentHeight, alignment: .bottom)
        }
        .frame(height: currentHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate zones")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: - Layers

    private func segmentsLayer(_ layout: HeartRateZoneSpectrumLayout) -> some View {
        ForEach(layout.segments, id: \.zone) { segment in
            let isCurrent = segment.zone == currentZone
            let inset = segmentSpacing / 2
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(segment.zone.color)
                // Dim non-current zones (and the whole bar when there is no current zone) so the
                // live zone reads at a glance; the current zone stays full-strength and taller.
                .opacity(fillOpacity(isCurrent: isCurrent))
                .frame(width: max(segment.width - segmentSpacing, 0),
                       height: isCurrent ? currentHeight : baseHeight)
                .overlay(alignment: .bottom) {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(BaselineColor.textHi.opacity(0.9), lineWidth: 1.5)
                            .frame(width: max(segment.width - segmentSpacing, 0), height: currentHeight)
                    }
                }
                .offset(x: segment.x + inset)
        }
    }

    /// Planned target band: a hairline dashed outline in the neutral text color, spanning the whole
    /// target zone range. Visually distinct from the current-zone emphasis (a filled, taller,
    /// high-contrast bar) so target and current never read as the same thing. Per design review it is
    /// the *only* target indicator — there is no target text label.
    private func targetOutline(_ band: HeartRateZoneSpectrumLayout.TargetBand) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius + 1, style: .continuous)
            .strokeBorder(BaselineColor.textHi.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            .frame(width: max(band.width - segmentSpacing + 4, 0), height: currentHeight + 4)
            .offset(x: band.x + segmentSpacing / 2 - 2, y: 2)
    }

    /// The live position marker — a vertical needle with a cap, echoing the `BaselineMeter` motif.
    private func marker(at x: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(BaselineColor.textHi)
                .frame(width: 3, height: currentHeight + 6)
                .shadow(color: BaselineColor.base.opacity(0.6), radius: 2)
            Circle()
                .fill(BaselineColor.textHi)
                .frame(width: 8, height: 8)
                .offset(y: -3)
        }
        .offset(x: x - 1.5, y: -3)
    }

    private func fillOpacity(isCurrent: Bool) -> Double {
        if currentZone == nil { return 0.5 }   // no live reading — dim the whole spectrum
        return isCurrent ? 1 : 0.4
    }
}

// MARK: - Previews

#if DEBUG
private func spectrumPreview(current: HeartRateZone?, position: Double?, target: ClosedRange<Int>?) -> some View {
    let summary = position != nil && current != nil
        ? "Current zone \(current!.displayName) \(current!.title)"
        : "No live zone"
    return HeartRateZoneSpectrum(currentZone: current, position: position,
                                 targetZones: target, accessibilitySummary: summary)
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(BaselineColor.base)
}

#Preview("Spectrum · Z3 current · dark") {
    spectrumPreview(current: .z3, position: 0.5, target: nil).preferredColorScheme(.dark)
}
#Preview("Spectrum · Z3 current · Z4 target · dark") {
    spectrumPreview(current: .z3, position: 0.5, target: 4...4).preferredColorScheme(.dark)
}
#Preview("Spectrum · Z2 current · Z1–Z2 target · dark") {
    spectrumPreview(current: .z2, position: 0.28, target: 1...2).preferredColorScheme(.dark)
}
#Preview("Spectrum · Z1 current · light") {
    spectrumPreview(current: .z1, position: 0.05, target: nil).preferredColorScheme(.light)
}
#Preview("Spectrum · no reading · dark") {
    spectrumPreview(current: nil, position: nil, target: 3...3).preferredColorScheme(.dark)
}
#endif
