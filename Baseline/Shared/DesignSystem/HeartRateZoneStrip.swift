import SwiftUI

/// Segment geometry for `HeartRateZoneStrip` — pure so the layout math is unit-testable without a
/// view. Each zone's width is proportional to its BPM span (evenly-spaced zone fractions make these
/// near-equal, but proportional widths stay honest if the boundary table ever changes), laid out
/// across the available width minus the inter-segment gaps.
struct HeartRateZoneStripLayout: Equatable {
    let widths: [CGFloat]

    init(rows: [HeartRateZonePreview.Row], width: CGFloat, spacing: CGFloat) {
        let count = rows.count
        guard count > 0, width > 0 else { widths = Array(repeating: 0, count: count); return }
        let usable = max(width - spacing * CGFloat(count - 1), 0)
        let spans = rows.map { CGFloat(max($0.upperBPM - $0.lowerBPM + 1, 1)) }
        let total = spans.reduce(0, +)
        widths = total > 0 ? spans.map { usable * $0 / total }
                           : Array(repeating: usable / CGFloat(count), count: count)
    }
}

/// Compact, always-visible Z1–Z5 spectrum bar: the live edit→zones feedback for the settings screen
/// (and the seed of the Slice-3 live spectrum). Pure view over a `HeartRateZoneModel` — it reads the
/// model's shared boundaries via `HeartRateZonePreview`, so it can never drift from `zone(forBPM:)`.
/// Shows the five colored segments with Z-labels and the boundary BPMs, which recompute as the model
/// changes.
struct HeartRateZoneStrip: View {
    let model: HeartRateZoneModel

    private static let segmentSpacing: CGFloat = 2

    private var rows: [HeartRateZonePreview.Row] { HeartRateZonePreview(model: model).rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let layout = HeartRateZoneStripLayout(rows: rows, width: geo.size.width,
                                                      spacing: Self.segmentSpacing)
                HStack(spacing: Self.segmentSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(row.zone.color)
                            .frame(width: layout.widths[index])
                            .overlay(
                                Text(row.zone.displayName)
                                    .font(.bMono(9, .bold))
                                    .foregroundStyle(BaselineColor.base)
                                    .opacity(layout.widths[index] > 22 ? 0.85 : 0)
                            )
                    }
                }
            }
            .frame(height: 16)

            // Spectrum endpoints — the live numbers that move as max / resting change.
            HStack {
                Text("\(rows.first?.lowerBPM ?? 0)")
                Spacer()
                Text("\(model.maxHR)")
            }
            .font(.bMono(10, .medium))
            .foregroundStyle(BaselineColor.textFaint)
        }
    }
}
