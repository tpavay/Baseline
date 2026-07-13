import SwiftUI

/// One adaptive workout card in the timeline. Shares a structure across modalities; the summary line is
/// derived from the workout's content. Completed cards read quiet; today/active read prominent. Full
/// execution (logging) opens `onOpen`; the primary action runs the lifecycle.
struct ScheduledWorkoutCard: View {
    let scheduled: ScheduledWorkout
    let status: ScheduleStatus
    let onPrimary: () -> Void
    let onOpen: () -> Void
    var onComplete: () -> Void = {}
    var onSkip: () -> Void = {}
    @State private var expanded = false

    private var quiet: Bool { if case .completed = status { return true }; if case .skipped = status { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 10).fill(BaselineColor.surface).frame(width: 42, height: 42)
                    .overlay(Image(systemName: scheduled.workout.allExercises.first?.definition.category.glyph ?? "figure.strengthtraining.traditional")
                        .font(.system(size: 18)).foregroundStyle(quiet ? BaselineColor.textFaint : BaselineColor.textMid))
                VStack(alignment: .leading, spacing: 6) {
                    Text(scheduled.workout.title).font(.system(size: 18, weight: .bold)).italic()
                        .foregroundStyle(quiet ? BaselineColor.textMid : BaselineColor.textHi)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(modalityLabels, id: \.self) { chip($0, color: BaselineColor.accent) }
                        if let d = durationLabel { chip(d, color: BaselineColor.textFaint) }
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    if primaryLabel != nil { Button(primaryLabel!, action: onPrimary) }
                    if case .inProgress = status { Button("Complete", action: onComplete) }
                    if case .paused = status { Button("Complete", action: onComplete) }
                    Button("Open", action: onOpen)
                    Button("Skip", action: onSkip)
                } label: { Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(BaselineColor.textFaint).padding(6) }
            }
            if let (label, color) = PlanStatusStyle.chip(status) {
                Text(label).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(color)
            }
            if expanded { exerciseList }
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(BaselineColor.textFaint)
                }.buttonStyle(.plain)
                Spacer()
                if let label = primaryLabel {
                    Button(action: onPrimary) {
                        Text(label).font(.system(size: 15, weight: .bold))
                            .foregroundStyle(prominent ? Color(hex: 0x120B21) : BaselineColor.accent)
                            .padding(.horizontal, 20).frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 12).fill(prominent ? BaselineColor.textHi : BaselineColor.surface))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(quiet ? BaselineColor.surface.opacity(0.4) : BaselineColor.surface))
        .onTapGesture { onOpen() }
    }

    private var prominent: Bool {
        switch status { case .today, .inProgress, .paused, .missed: return true; default: return false }
    }
    private var primaryLabel: String? { PlanStatusStyle.primaryLabel(status) }

    private var modalityLabels: [String] {
        var seen = Set<ActivityCategory>(), out: [String] = []
        for ex in scheduled.workout.allExercises {
            let c = ex.definition.category
            if seen.insert(c).inserted { out.append(PlanStatusStyle.modalityLabel(c)) }
        }
        return Array(out.prefix(3))
    }

    private var durationLabel: String? {
        let total = AggregateProvider.contributions(of: scheduled.workout).first { $0.key == .duration }?.amount ?? 0
        return total > 0 ? PlanFormat.durationShort(Int(total)) : nil
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.4).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var exerciseList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(scheduled.workout.allExercises) { ex in
                HStack {
                    Text(ex.exerciseName).font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textHi)
                    Spacer()
                    Text("\(ex.prescription.sets.count)×").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
                }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(BaselineColor.base.opacity(0.5)))
    }
}

// MARK: - Status → presentation

enum PlanStatusStyle {
    static func chip(_ s: ScheduleStatus) -> (String, Color)? {
        switch s {
        case .today(let m): return todayChip(m)
        case .inProgress: return ("IN PROGRESS", BaselineColor.accent)
        case .paused: return ("PAUSED", BaselineColor.zoneAmber)
        case .completed: return ("COMPLETED", BaselineColor.zoneGreen)
        case .skipped: return ("SKIPPED", BaselineColor.zoneAmber)
        case .missed: return ("MISSED", BaselineColor.zoneRed)
        case .planned: return nil
        case .modifiedIntent(let a): return ("\(a.rawValue.uppercased()) MODIFIED", BaselineColor.accent)
        }
    }
    private static func todayChip(_ m: TodayModification) -> (String, Color) {
        switch m {
        case .asPlanned: return ("AS PLANNED", BaselineColor.zoneGreen)
        case .modified: return ("MODIFIED TODAY", BaselineColor.accent)
        case .constraintActive: return ("CONSTRAINT ACTIVE", BaselineColor.zoneAmber)
        case .swapSuggested: return ("SWAP SUGGESTED", BaselineColor.zoneAmber)
        case .reducedVolume(let p): return (p.map { "VOLUME −\($0)%" } ?? "REDUCED VOLUME", BaselineColor.zoneAmber)
        }
    }
    static func primaryLabel(_ s: ScheduleStatus) -> String? {
        switch s {
        case .today, .missed: return "Start Workout"
        case .inProgress, .paused: return "Resume"
        case .completed: return "View Log"
        case .planned, .modifiedIntent: return "Preview"
        case .skipped: return nil
        }
    }
    static func modalityLabel(_ c: ActivityCategory) -> String {
        switch c {
        case .cycling: "Bike"; case .running: "Run"; case .erg: "Erg"; case .strength: "Strength"
        case .carry: "Carry"; case .isometric: "Hold"; case .other: "Mixed"
        }
    }
}

