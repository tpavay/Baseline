import SwiftUI

struct WorkoutHeartRateChart: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            guard samples.isEmpty == false else { return }
            let lower = max((samples.min() ?? 0) - 10, 0)
            let upper = max((samples.max() ?? 1) + 10, lower + 1)
            let plot = CGRect(
                x: BaselineSpacing.screen,
                y: BaselineSpacing.xSmall,
                width: max(size.width - BaselineSpacing.screen, 1),
                height: max(size.height - BaselineSpacing.xLarge, 1)
            )

            for fraction in [0.0, 0.5, 1.0] {
                let y = plot.maxY - plot.height * fraction
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(grid, with: .color(BaselineColor.line), lineWidth: BaselineSize.hairline)

                let label = Text("\(Int(lower + (upper - lower) * fraction))")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(BaselineColor.textFaint)
                context.draw(label, at: CGPoint(x: 0, y: y), anchor: .leading)
            }

            var line = Path()
            for (index, sample) in samples.enumerated() {
                let fraction = samples.count == 1 ? 0.5 : Double(index) / Double(samples.count - 1)
                let x = plot.minX + plot.width * fraction
                let normalized = (sample - lower) / (upper - lower)
                let y = plot.maxY - plot.height * normalized
                let point = CGPoint(x: x, y: y)
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }

            context.stroke(
                line,
                with: .color(BaselineColor.accent),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(height: BaselineSize.chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartAccessibilityLabel)
    }

    private var chartAccessibilityLabel: String {
        guard let average = samples.average, let maximum = samples.max() else { return "No heart-rate samples" }
        return "Heart rate, average \(Int(average.rounded())) beats per minute, maximum \(Int(maximum.rounded()))"
    }
}

private extension Collection where Element == Double {
    var average: Double? {
        isEmpty ? nil : reduce(0, +) / Double(count)
    }
}
