import SwiftUI

/// The card's fixed branding chrome: the header block, the wordmark, and the background.
///
/// The editing preview and the export canvas render these same views, and every dimension here is a
/// multiple of `canvasScale` — 1 at the 390pt design width, 1080/390 at export size. That is what
/// makes the shared image the preview scaled up rather than a second layout with its own constants,
/// so a sticker positioned against the preview header lands in the same place in the export.
///
/// Type here is sized in points rather than through `BaselineTypography`, because a text style
/// resolves to a fixed point size that cannot scale with the canvas — the reason the two headers
/// diverged in the first place. This file is the one place that trade-off is made.
struct ShareCardHeader: View {
    let summary: WorkoutLogSummary
    let canvasScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WORKOUT COMPLETE")
                .font(.system(size: 12 * canvasScale, weight: .semibold, design: .monospaced))
                .tracking(1.8 * canvasScale)
                .foregroundStyle(BaselineColor.textMid)
            Text(summary.title)
                .font(.system(size: 26 * canvasScale, weight: .bold))
                .foregroundStyle(BaselineColor.textHi)
                .lineLimit(3)
                .minimumScaleFactor(0.45)
                .padding(.top, 8 * canvasScale)
            Text(WorkoutPresentationFormatter.elapsedDuration(from: summary.startedAt, to: summary.finishedAt))
                .font(.system(size: 11 * canvasScale, weight: .medium, design: .monospaced))
                .tracking(canvasScale)
                .foregroundStyle(BaselineColor.textMid)
                .padding(.top, 10 * canvasScale)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28 * canvasScale)
        .padding(.top, 48 * canvasScale)
        .accessibilityElement(children: .combine)
    }
}

struct ShareCardWordmark: View {
    let canvasScale: CGFloat

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            BaselineWordmark(size: 14 * canvasScale, color: BaselineColor.textHi.opacity(0.92))
                .shadow(color: .black.opacity(0.45), radius: 4 * canvasScale, x: 0, y: 1)
                .padding(.bottom, 24 * canvasScale)
        }
    }
}

struct ShareCardBackground: View {
    let background: ShareComposerBackground
    let canvasScale: CGFloat

    var body: some View {
        ZStack {
            switch background {
            case .amethyst:
                LinearGradient(
                    colors: [BaselineColor.base, BaselineColor.amethyst, BaselineColor.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .base:
                BaselineColor.base
            case .green:
                LinearGradient(
                    colors: [BaselineColor.base, BaselineColor.surface, BaselineColor.zoneGreen.opacity(0.34)],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
            }

            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [BaselineColor.accent.opacity(0.24), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 820 * canvasScale
                    )
                )

            Rectangle()
                .fill(.black.opacity(0.08))
        }
    }
}
