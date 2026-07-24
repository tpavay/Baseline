import SwiftUI

/// Shared visual content for editing and export so the two canvases match.
struct ShareStickerVisual: View {
    let instance: ShareStickerInstance
    let stat: ResolvedShareStat

    var body: some View {
        ShareStatStickerContent(
            stat: stat,
            style: instance.style,
            font: instance.font,
            color: instance.color,
            textBackground: instance.textBackground
        )
    }
}
