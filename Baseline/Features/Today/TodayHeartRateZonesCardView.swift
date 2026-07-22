import SwiftUI

struct TodayHeartRateZonesCardView: View {
    let summary: TodayWeeklySummary
    let ranges: [HeartRateZone: String]

    var body: some View {
        BaselineCard {
            VStack(alignment: .leading, spacing: BaselineSpacing.medium) {
                HStack {
                    Text("HEART RATE ZONES")
                    Spacer(minLength: 0)
                    Text(headerDetail)
                }
                .baselineTypography(.instrumentLabel)
                .foregroundStyle(BaselineColor.textFaint)

                HStack(spacing: BaselineSpacing.cardContent) {
                    SegmentedRing(
                        segments: summary.heartRateZones.map {
                            .init(weight: max($0.seconds, 1), progress: $0.seconds > 0 ? 1 : 0, color: color(for: $0.zone))
                        },
                        diameter: BaselineSize.zoneRing,
                        lineWidth: BaselineSize.zoneRingLineWidth,
                        gapDegrees: BaselineSize.zoneRingGapDegrees,
                        trackColor: BaselineColor.line.opacity(0.9),
                        accessibilitySummary: ringAccessibility
                    ) {
                        VStack(spacing: BaselineSpacing.xxSmall) {
                            Text(mostUsedZone?.displayName ?? "-")
                                .baselineTypography(.instrumentValue)
                                .foregroundStyle(mostUsedZone.map { color(for: $0) } ?? BaselineColor.textMid)
                            Text(mostUsedZone == nil ? "NO DATA" : "MOST TIME")
                                .baselineTypography(.instrumentLabel)
                                .foregroundStyle(BaselineColor.textFaint)
                        }
                    }

                    VStack(spacing: BaselineSpacing.xSmall) {
                        ForEach(summary.heartRateZones) { zone in
                            TodayHeartRateZoneRowView(
                                summary: zone,
                                range: ranges[zone.zone] ?? "",
                                color: color(for: zone.zone)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var headerDetail: String {
        let bpm = summary.averageHeartRate.map { " · AVG \($0) BPM" } ?? ""
        return summary.heartRateDurationText.uppercased() + bpm
    }

    private var mostUsedZone: HeartRateZone? {
        summary.heartRateZones.filter { $0.seconds > 0 }.max { $0.seconds < $1.seconds }?.zone
    }

    private var ringAccessibility: String {
        summary.heartRateZones
            .map { "\($0.zone.displayName) \(TodayWeeklySummary.durationText($0.seconds))" }
            .joined(separator: ", ")
    }

    private func color(for zone: HeartRateZone) -> Color {
        switch zone {
        case .z1: BaselineColor.zoneBlue
        case .z2: BaselineColor.zoneGreen
        case .z3: BaselineColor.accent
        case .z4: BaselineColor.zoneAmber
        case .z5: BaselineColor.zoneRed
        }
    }
}

private struct TodayHeartRateZoneRowView: View {
    let summary: TodayHeartRateZoneSummary
    let range: String
    let color: Color

    var body: some View {
        HStack(spacing: BaselineSpacing.xSmall) {
            Capsule()
                .fill(color)
                .frame(width: BaselineSize.zoneMarkerWidth, height: BaselineSize.zoneMarkerHeight)
                .accessibilityHidden(true)
            Text(summary.zone.displayName)
                .baselineTypography(.instrumentLabel)
                .foregroundStyle(color)
                .frame(width: BaselineSize.zoneLabelWidth, alignment: .leading)
            Text(TodayWeeklySummary.durationText(summary.seconds))
                .baselineTypography(.instrumentMeta)
                .foregroundStyle(BaselineColor.textHi)
                .frame(width: BaselineSize.zoneTimeWidth, alignment: .leading)
            Text(range.isEmpty ? "NO RANGE" : "\(range) BPM")
                .baselineTypography(.instrumentMeta)
                .foregroundStyle(BaselineColor.textFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.zone.displayName), \(TodayWeeklySummary.durationText(summary.seconds)), \(range) beats per minute")
    }
}
