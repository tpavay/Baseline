import Foundation
import SwiftUI

struct MuscleMapView: View {
    let workouts: [Workout]
    var isCompact = false

    private var muscleWeights: [Muscle: Int] {
        workouts.reduce(into: [:]) { result, workout in
            for exercise in workout.allExercises {
                let setCount = max(exercise.prescription.sets.count, 1)
                for muscle in exercise.definition.primaryMuscles {
                    result[muscle, default: 0] += setCount * 2
                }
                for muscle in exercise.definition.secondaryMuscles {
                    result[muscle, default: 0] += setCount
                }
            }
        }
    }

    private var accessibilitySummary: String {
        let muscles = muscleWeights
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { $0.key.displayName }
        guard muscles.isEmpty == false else { return "No mapped muscle work" }
        return "Muscle map: " + muscles.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: isCompact ? BaselineSpacing.xxxSmall : BaselineSpacing.compact) {
            figure(region: .anterior, label: "FRONT")
            figure(region: .posterior, label: "BACK")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func figure(region: MuscleRegion, label: String) -> some View {
        VStack(spacing: BaselineSpacing.xxSmall) {
            if isCompact == false {
                InstrumentLabel(label, tracking: 1)
            }

            Canvas { context, size in
                drawFigure(in: &context, size: size, region: region)
            }
            .frame(height: isCompact ? BaselineSize.miniMuscleMapHeight : BaselineSize.muscleMapHeight)
        }
        .frame(maxWidth: .infinity)
    }

    private func drawFigure(in context: inout GraphicsContext, size: CGSize, region: MuscleRegion) {
        let parts = region == .anterior ? MuscleFigureStore.front : MuscleFigureStore.back
        guard parts.isEmpty == false else { return }
        let strongest = max(muscleWeights.values.max() ?? 1, 1)
        let viewBoxWidth: CGFloat = 724
        let viewBoxHeight: CGFloat = 1_448
        let scale = min(size.width / viewBoxWidth, size.height / viewBoxHeight)
        let sourceOffset: CGFloat = region == .posterior ? -viewBoxWidth : 0
        let transform = CGAffineTransform(
            translationX: (size.width - viewBoxWidth * scale) / 2 + sourceOffset * scale,
            y: (size.height - viewBoxHeight * scale) / 2
        ).scaledBy(x: scale, y: scale)

        for part in parts {
            let weight = muscleWeight(for: part.slug, region: region)
            let intensity = min(CGFloat(weight) / CGFloat(strongest), 1)
            for sourcePath in part.paths {
                let path = sourcePath.applying(transform)
                context.fill(path, with: .color(BaselineColor.textHi.opacity(0.82)))
                if weight > 0 {
                    context.fill(path, with: .color(BaselineColor.accent.opacity(0.3 + intensity * 0.7)))
                }
                context.stroke(
                    path,
                    with: .color(BaselineColor.base.opacity(0.58)),
                    lineWidth: max(2.5 * scale, 0.45)
                )
            }
        }
    }

    private func muscleWeight(for slug: String, region: MuscleRegion) -> Int {
        let muscles: [Muscle] = switch slug {
        case "chest": [.chest]
        case "obliques": [.obliques]
        case "abs": [.abdominals]
        case "biceps": [.biceps]
        case "triceps": [.triceps]
        case "neck": [.neck]
        case "trapezius": [.traps]
        case "deltoids": region == .anterior ? [.frontDelts, .sideDelts] : [.rearDelts, .sideDelts]
        case "adductors": [.adductors]
        case "quadriceps": [.quadriceps]
        case "tibialis", "calves": [.calves]
        case "forearm": [.forearms]
        case "upper-back": [.upperBack, .lats]
        case "lower-back": [.lowerBack]
        case "gluteal": [.glutes]
        case "hamstring": [.hamstrings]
        default: []
        }
        return muscles.reduce(muscleWeights[.fullBody, default: 0]) { partial, muscle in
            partial + muscleWeights[muscle, default: 0]
        }
    }
}

private struct MuscleFigurePart {
    let slug: String
    let paths: [Path]
}

private struct MuscleFigureAsset: Decodable {
    let slug: String
    let path: [String: [String]]
}

@MainActor
private enum MuscleFigureStore {
    static let front = load(named: "bodyFront")
    static let back = load(named: "bodyBack")

    private static func load(named name: String) -> [MuscleFigurePart] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let assets = try? JSONDecoder().decode([MuscleFigureAsset].self, from: data)
        else { return [] }

        return assets.map { asset in
            MuscleFigurePart(
                slug: asset.slug,
                paths: asset.path.values.flatMap { $0 }.compactMap(SVGPathParser.parse)
            )
        }
    }
}
