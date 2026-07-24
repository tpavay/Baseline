import SwiftUI

/// Shared visual content for editing and export so the two canvases match.
struct ShareStickerVisual: View {
    let instance: ShareStickerInstance
    let stats: [ResolvedShareStat]

    var body: some View {
        if stats.count > 1 {
            ShareCompositeStatContent(
                stats: stats,
                layout: instance.layout,
                font: instance.font,
                color: instance.color,
                textBackground: instance.textBackground
            )
        } else if let stat = stats.first {
            ShareStatStickerContent(
                stat: stat,
                style: instance.style,
                font: instance.font,
                color: instance.color,
                textBackground: instance.textBackground
            )
        }
    }
}
