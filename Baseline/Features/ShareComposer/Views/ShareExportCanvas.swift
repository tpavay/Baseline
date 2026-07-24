import SwiftUI

/// Static render of the composed share, used by `ImageRenderer` at export resolution.
///
/// It mirrors the editing canvas using normalized sticker positions plus the same proportional
/// `canvasScale`, so output stays WYSIWYG.
struct ShareExportCanvas: View {
    let viewModel: ShareComposerViewModel
    let size: CGSize

    var body: some View {
        let canvasScale = size.width / 390

        ZStack {
            ShareCardBackground(background: viewModel.background)

            VStack(alignment: .leading, spacing: 0) {
                InstrumentLabel("Workout complete", color: BaselineColor.textMid, tracking: 1.8)
                Text(viewModel.summary.title)
                    .font(.system(size: 44 * canvasScale, weight: .bold, design: .default))
                    .foregroundStyle(BaselineColor.textHi)
                    .lineLimit(3)
                    .minimumScaleFactor(0.45)
                    .padding(.top, 10 * canvasScale)
                Text(WorkoutPresentationFormatter.elapsedDuration(
                    from: viewModel.summary.startedAt,
                    to: viewModel.summary.finishedAt
                ))
                .font(.system(size: 16 * canvasScale, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(BaselineColor.textMid)
                .padding(.top, 16 * canvasScale)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 72 * canvasScale)
            .padding(.top, 118 * canvasScale)

            ForEach(viewModel.stickers) { sticker in
                let stats = viewModel.resolvedStats(for: sticker)
                if stats.isEmpty == false {
                    ShareStickerVisual(instance: sticker, stats: stats)
                        .scaleEffect(sticker.scale * canvasScale)
                        .rotationEffect(.radians(sticker.rotationRadians))
                        .position(x: sticker.position.x * size.width, y: sticker.position.y * size.height)
                }
            }

            VStack {
                Spacer()
                BaselineWordmark(size: 14 * canvasScale, color: BaselineColor.textHi.opacity(0.92))
                    .shadow(color: .black.opacity(0.45), radius: 4 * canvasScale, x: 0, y: 1)
                    .padding(.bottom, 36 * canvasScale)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

struct ShareCardBackground: View {
    let background: ShareComposerBackground

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
                        endRadius: 820
                    )
                )

            Rectangle()
                .fill(.black.opacity(0.08))
        }
    }
}
