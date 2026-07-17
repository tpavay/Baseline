import SwiftUI

/// Instrument design-system primitives — the chosen "recovery instrument, not a dashboard"
/// direction. Mono numerals for data, hairlines over fills, restrained color, the
/// baseline-meter motif. Numerals use SF Mono (`.monospaced`); prose stays SF Pro.
/// Full spec + rationale: docs/design-system/instrument.md.

extension Font {
    /// Monospaced numerals / labels — the instrument voice.
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
            .font(.bMono(11, .medium))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

/// 1px hairline rule.
struct Hairline: View {
    var color: Color = BaselineColor.line
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

/// A labeled mono readout (big value + caps label), left-aligned.
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

/// Primary action — accent fill, mono label, soft glow.
struct InstrumentButtonStyle: ButtonStyle {
    var tint: Color = BaselineColor.accent
    var textColor: Color = BaselineColor.base
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bMono(15, .bold))
            .tracking(1)
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint))
            .shadow(color: tint.opacity(0.4), radius: 18, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary action — hairline outline, mono label.
struct InstrumentOutlineButtonStyle: ButtonStyle {
    var color: Color = BaselineColor.textMid
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bMono(13, .bold))
            .tracking(1)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BaselineColor.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The signature "you vs your 7-day baseline" meter: a 0–100 zone scale (red/amber/green) with
/// tick marks, an optional shaded baseline band, and a glowing "TODAY" needle at `score`.
struct BaselineMeter: View {
    let score: Int
    var band: ClosedRange<Int>? = nil

    private func frac(_ v: Int) -> CGFloat { CGFloat(min(max(v, 0), 100)) / 100 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let sx = frac(score) * w
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
                        .offset(x: frac(v) * w - 0.5, y: 58)
                }

                if let band {
                    let bx = frac(band.lowerBound) * w
                    let bw = (frac(band.upperBound) - frac(band.lowerBound)) * w
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
