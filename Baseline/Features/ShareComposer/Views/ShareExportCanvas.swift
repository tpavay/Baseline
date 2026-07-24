import SwiftUI

/// Static render of the composed share, used by `ImageRenderer` at export resolution.
///
/// It is the editing canvas without the editing affordances: the same `ShareCardBackground`,
/// `ShareCardHeader`, and `ShareCardWordmark`, driven by the same proportional `canvasScale` and the
/// same normalized sticker positions, so the output stays WYSIWYG.
struct ShareExportCanvas: View {
    let viewModel: ShareComposerViewModel
    let size: CGSize

    var body: some View {
        let canvasScale = size.width / ShareCardMetrics.designWidth

        ZStack {
            ShareCardBackground(background: viewModel.background, canvasScale: canvasScale)

            ShareCardHeader(summary: viewModel.summary, canvasScale: canvasScale)

            ForEach(viewModel.stickers) { sticker in
                if let stat = viewModel.resolve(sticker) {
                    ShareStickerVisual(instance: sticker, stat: stat)
                        .scaleEffect(sticker.scale * canvasScale)
                        .rotationEffect(.radians(sticker.rotationRadians))
                        .position(x: sticker.position.x * size.width, y: sticker.position.y * size.height)
                }
            }

            ShareCardWordmark(canvasScale: canvasScale)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// The one design width every share-card dimension is proportional to.
enum ShareCardMetrics {
    static let designWidth: CGFloat = 390
    static let cornerRadius: CGFloat = 22
}
