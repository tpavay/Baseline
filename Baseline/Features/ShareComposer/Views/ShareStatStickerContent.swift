import SwiftUI

/// Renders a resolved stat in a reusable sticker style.
struct ShareStatStickerContent: View {
    let stat: ResolvedShareStat
    var style: ShareStickerStyle = .display
    var font: ShareStickerFont = .baseline
    var color: RGBAColor = .textHi
    var textBackground: ShareTextBackground = .none
    var baseValueSize: CGFloat = 40

    private var valueColor: Color { color.color }
    private var showsLabel: Bool { stat.kind != .workoutName && !stat.label.isEmpty }

    var body: some View {
        styledContent
            .shadow(color: .black.opacity(textBackground == .none ? 0.45 : 0), radius: 6, x: 0, y: 2)
            .padding(plateInsets)
            .background(plate)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(showsLabel ? "\(stat.label), \(stat.value)" : stat.value)
    }

    @ViewBuilder
    private var styledContent: some View {
        switch style {
        case .display:
            VStack(spacing: 3) {
                Text(stat.value)
                    .font(font.swiftUIFont(size: baseValueSize))
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.center)
                if showsLabel {
                    Text(stat.label)
                        .font(font.swiftUIFont(size: baseValueSize * 0.3))
                        .tracking(1.8)
                        .foregroundStyle(BaselineColor.accent)
                }
            }
        case .stacked:
            VStack(spacing: 4) {
                if showsLabel {
                    Text(stat.label)
                        .font(font.swiftUIFont(size: baseValueSize * 0.32))
                        .tracking(1.4)
                        .foregroundStyle(BaselineColor.accent.opacity(0.9))
                }
                Text(stat.value)
                    .font(font.swiftUIFont(size: baseValueSize * 0.82))
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.center)
            }
        case .chip:
            HStack(spacing: 8) {
                if showsLabel {
                    Text(stat.label)
                        .font(font.swiftUIFont(size: baseValueSize * 0.34))
                        .tracking(1)
                        .foregroundStyle(BaselineColor.accent)
                }
                Text(stat.value)
                    .font(font.swiftUIFont(size: baseValueSize * 0.38))
                    .foregroundStyle(valueColor)
            }
        }
    }

    private var plateInsets: EdgeInsets {
        switch textBackground {
        case .none:
            EdgeInsets()
        case .dark, .surface:
            EdgeInsets(
                top: baseValueSize * 0.28,
                leading: baseValueSize * 0.4,
                bottom: baseValueSize * 0.28,
                trailing: baseValueSize * 0.4
            )
        }
    }

    @ViewBuilder
    private var plate: some View {
        switch textBackground {
        case .none:
            EmptyView()
        case .dark:
            RoundedRectangle(cornerRadius: baseValueSize * 0.3, style: .continuous)
                .fill(BaselineColor.base.opacity(0.68))
        case .surface:
            RoundedRectangle(cornerRadius: baseValueSize * 0.3, style: .continuous)
                .fill(BaselineColor.surface.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: baseValueSize * 0.3, style: .continuous)
                        .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
                )
        }
    }
}
