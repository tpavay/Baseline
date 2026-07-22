import SwiftUI

/// Instrument design-system primitives for the established calm-precision direction.
/// Mono numerals for data, hairlines over fills, restrained color, and the
/// baseline-meter motif. Numerals use SF Mono (`.monospaced`); prose stays SF Pro.
/// Full spec + rationale: docs/design-system/instrument.md.

extension Font {
    /// Compatibility API for older call sites that still require an explicit size.
    /// New shared components should use `BaselineTypography` so Dynamic Type scales semantically.
    static func bMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Tiny uppercase mono label for fields/sections.
struct InstrumentLabel: View {
    let text: String
    var color: Color = BaselineColor.textFaint
    var tracking: CGFloat = 2
    init(_ text: String, color: Color = BaselineColor.textFaint, tracking: CGFloat = 2) {
        self.text = text
        self.color = color
        self.tracking = tracking
    }
    var body: some View {
        Text(text.uppercased())
            .font(BaselineTypography.instrumentLabel.font)
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

/// 1px hairline rule.
struct Hairline: View {
    var color: Color = BaselineColor.line
    var body: some View { Rectangle().fill(color).frame(height: BaselineSize.hairline) }
}

/// A labeled mono readout with a large value and caps label.
struct InstrumentStat: View {
    let value: String
    let label: String
    var size: CGFloat = 40
    var color: Color = BaselineColor.textHi
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.bMono(size, .bold))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            InstrumentLabel(label, tracking: 1)
        }
    }
}

/// Primary action with an accent fill, mono label, and soft glow.
struct InstrumentButtonStyle: ButtonStyle {
    var tint: Color = BaselineColor.accent
    var textColor: Color = BaselineColor.base
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .baselineTypography(.button)
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BaselineSpacing.medium)
            .frame(minHeight: BaselineSize.minimumTapTarget)
            .background(RoundedRectangle(cornerRadius: BaselineRadius.control, style: .continuous).fill(tint))
            .shadow(color: tint.opacity(0.4), radius: 18, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary action with a hairline outline and mono label.
struct InstrumentOutlineButtonStyle: ButtonStyle {
    var color: Color = BaselineColor.textMid
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .baselineTypography(.button)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BaselineSpacing.small)
            .frame(minHeight: BaselineSize.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: BaselineRadius.control, style: .continuous)
                    .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The signature "you vs your 7-day baseline" meter: a 0–100 zone scale (red/amber/green) with
/// tick marks, an optional shaded baseline band, and a glowing "TODAY" needle at `score`.
struct BaselineMeter: View {
    let score: Int
    var band: ClosedRange<Int>? = nil

    private func fraction(_ value: Int) -> CGFloat {
        CGFloat(min(max(value, 0), 100)) / 100
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let sx = fraction(score) * w
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    Rectangle().fill(BaselineColor.zoneRed.opacity(0.4)).frame(width: 0.6 * w)
                    Rectangle().fill(BaselineColor.zoneAmber.opacity(0.45)).frame(width: 0.2 * w)
                    Rectangle().fill(BaselineColor.zoneGreen.opacity(0.55))
                }
                .frame(height: 3)
                .offset(y: 52)

                ForEach([0, 20, 40, 60, 80, 100], id: \.self) { v in
                    Rectangle().fill(BaselineColor.line)
                        .frame(width: 1, height: 6)
                        .offset(x: fraction(v) * w - 0.5, y: 58)
                }

                if let band {
                    let bx = fraction(band.lowerBound) * w
                    let bw = (fraction(band.upperBound) - fraction(band.lowerBound)) * w
                    RoundedRectangle(cornerRadius: 2)
                        .fill(BaselineColor.textHi.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(BaselineColor.textFaint.opacity(0.5), lineWidth: 1))
                        .frame(width: bw, height: 24)
                        .offset(x: bx, y: 24)
                }

                Rectangle().fill(BaselineColor.zoneGreen)
                    .frame(width: 2, height: 30)
                    .offset(x: sx - 1, y: 20)
                Circle().fill(BaselineColor.zoneGreen)
                    .frame(width: 8, height: 8)
                    .shadow(color: BaselineColor.zoneGreen.opacity(0.7), radius: 8)
                    .offset(x: sx - 4, y: 14)
                Text("TODAY")
                    .font(.bMono(9, .medium)).tracking(1)
                    .foregroundStyle(BaselineColor.zoneGreen)
                    .frame(width: 60, alignment: .center)
                    .offset(x: sx - 30, y: 0)
            }
        }
        .frame(height: 70)
    }
}
