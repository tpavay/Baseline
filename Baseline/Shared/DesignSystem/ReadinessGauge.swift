import SwiftUI

/// The semicircular readiness gauge — the app's hero instrument. A full 180° gray track is
/// always visible (it must read as a dial, never a floating arc fragment); the filled portion
/// is proportional to the score; the number sits in the dial's mouth with the band word under
/// it. Fill color carries meaning: band colors = calibrated confidence, violet = provisional
/// ("calibrating"), per the score-treatment rule.
struct ReadinessGauge: View {
    let score: Int?
    let fill: Color
    let label: String
    var size: CGFloat = 220
    /// Animates the number counting up and the arc sweeping on appear (the reveal moment).
    var animated: Bool = false

    @State private var shown: Double = 0

    private var target: Double { Double(min(max(score ?? 0, 0), 100)) }

    var body: some View {
        ZStack {
            SemicircleArc(fraction: 1)
                .stroke(BaselineColor.line, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            SemicircleArc(fraction: shown / 100)
                .stroke(fill, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .shadow(color: fill.opacity(0.45), radius: 12)

            VStack(spacing: 6) {
                Text(score == nil ? "—" : "\(Int(shown.rounded()))")
                    .font(.bMono(size * 0.3, .bold))
                    .foregroundStyle(BaselineColor.textHi)
                    .contentTransition(.numericText())
                if !label.isEmpty {
                    InstrumentLabel(label, color: fill, tracking: 3)
                }
            }
            .offset(y: size * 0.1)
        }
        .frame(width: size, height: size * 0.62)
        .onAppear {
            if animated {
                withAnimation(.easeOut(duration: 1.1)) { shown = target }
            } else {
                shown = target
            }
        }
        .onChange(of: score) { _, _ in
            withAnimation(.easeOut(duration: 0.5)) { shown = target }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readiness \(score.map(String.init) ?? "calibrating"), \(label)")
    }
}

/// 180° arc from the left end of the dial sweeping right, drawn in the top portion of its rect.
private struct SemicircleArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2, rect.height) - 6
        let center = CGPoint(x: rect.midX, y: rect.maxY - 4)
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(180 + 180 * min(max(fraction, 0), 1)),
            clockwise: false
        )
        return path
    }
}

/// The guidance chip that pairs with the gauge: state → what to do about it.
struct GuidanceChip: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold).italic())
                    .foregroundStyle(BaselineColor.textHi)
                if let subtitle {
                    Text(subtitle)
                        .font(.bMono(10))
                        .tracking(1)
                        .foregroundStyle(BaselineColor.textFaint)
                        .textCase(.uppercase)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BaselineColor.surface)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BaselineColor.line, lineWidth: 1))
        )
    }
}
