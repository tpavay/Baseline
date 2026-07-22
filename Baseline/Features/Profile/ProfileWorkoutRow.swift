import SwiftUI

struct ProfileWorkoutRow: View {
    let scheduled: ScheduledWorkout
    let subtitle: String
    let action: () -> Void

    private var isCardioOnly: Bool {
        let exercises = scheduled.workout.allExercises
        return exercises.isEmpty == false && exercises.allSatisfy {
            [.cycling, .running, .erg].contains($0.definition.category)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: BaselineSpacing.xSmall) {
                VStack(alignment: .leading, spacing: BaselineSpacing.xxSmall) {
                    Text(scheduled.workout.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.textHi)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(BaselineColor.textMid)
                        .lineLimit(1)
                }

                Spacer(minLength: BaselineSpacing.xSmall)

                if isCardioOnly {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(BaselineColor.zoneBlue)
                        .frame(width: BaselineSize.icon)
                        .accessibilityHidden(true)
                } else {
                    MuscleMapView(workouts: [scheduled.workout], isCompact: true)
                        .frame(width: BaselineSize.avatar)
                        .accessibilityHidden(true)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BaselineColor.textFaint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, BaselineSpacing.row)
            .padding(.vertical, BaselineSpacing.medium)
            .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: BaselineRadius.row)
                    .fill(BaselineColor.surface.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: BaselineRadius.row)
                            .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: BaselineRadius.row))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens workout details")
    }
}
