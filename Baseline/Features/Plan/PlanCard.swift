import SwiftUI

/// Structural actions a card can request; `PlanView` maps each to a versioned repository mutation.
enum PlanCardAction: Equatable {
    case open, duplicate, skip, unskip, delete, move(Date)
}

/// A compact disclosure row in the plan timeline. Tapping opens the workout detail, where starting and
/// logging live; plan-level organization remains available from the row's context menu.
struct ScheduledWorkoutCard: View {
    let scheduled: ScheduledWorkout
    let status: ScheduleStatus
    var weekDays: [Date] = []
    let onAction: (PlanCardAction) -> Void
    private let cal = Calendar.planWeek

    private var quiet: Bool { if case .completed = status { return true }; if case .skipped = status { return true }; return false }

    var body: some View {
        Button { onAction(.open) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scheduled.workout.title)
                        .font(.headline)
                        .foregroundStyle(quiet ? BaselineColor.textMid : BaselineColor.textHi)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if let (label, color) = PlanStatusStyle.chip(status) {
                            Text(label)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(color)
                        }
                        if let summaryLabel {
                            Text(summaryLabel)
                                .font(.caption)
                                .foregroundStyle(BaselineColor.textFaint)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.textFaint)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(quiet ? BaselineColor.surface.opacity(0.45) : BaselineColor.surface))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens workout details")
        .contextMenu {
            if !weekDays.isEmpty {
                Menu("Move to") {
                    ForEach(weekDays, id: \.self) { date in
                        Button(date.formatted(.dateTime.weekday(.wide))) { onAction(.move(date)) }
                            .disabled(cal.isDate(date, inSameDayAs: scheduled.date))
                    }
                }
            }
            Button("Duplicate") { onAction(.duplicate) }
            if scheduled.skipped {
                Button("Unskip") { onAction(.unskip) }
            } else {
                Button("Skip") { onAction(.skip) }
            }
            Button("Delete", role: .destructive) { onAction(.delete) }
        }
    }

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

    private var summaryLabel: String? {
        let parts = modalityLabels + [durationLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ").uppercased()
    }

    private var accessibilityLabel: String {
        let date = scheduled.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let statusLabel = PlanStatusStyle.chip(status)?.0
        return [date, scheduled.workout.title, statusLabel, summaryLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

// MARK: - Status → presentation

enum PlanStatusStyle {
    static func chip(_ s: ScheduleStatus) -> (String, Color)? {
        switch s {
        case .today(let modification): return todayChip(modification)
        case .inProgress: return ("IN PROGRESS", BaselineColor.accent)
        case .paused: return ("PAUSED", BaselineColor.zoneAmber)
        case .completed: return ("COMPLETED", BaselineColor.zoneGreen)
        case .skipped: return ("SKIPPED", BaselineColor.zoneAmber)
        case .missed: return ("MISSED", BaselineColor.zoneRed)
        case .planned: return nil
        case .modifiedIntent(let a): return ("\(a.rawValue.uppercased()) MODIFIED", BaselineColor.accent)
        }
    }
    private static func todayChip(_ modification: TodayModification) -> (String, Color)? {
        switch modification {
        case .asPlanned: return nil
        case .modified: return ("MODIFIED", BaselineColor.accent)
        case .constraintActive: return ("CONSTRAINT ACTIVE", BaselineColor.zoneAmber)
        case .swapSuggested: return ("SWAP SUGGESTED", BaselineColor.zoneAmber)
        case .reducedVolume(let p): return (p.map { "VOLUME −\($0)%" } ?? "REDUCED VOLUME", BaselineColor.zoneAmber)
        }
    }
    static func modalityLabel(_ c: ActivityCategory) -> String {
        switch c {
        case .cycling: "Bike"; case .running: "Run"; case .erg: "Erg"; case .strength: "Strength"
        case .carry: "Carry"; case .isometric: "Hold"; case .other: "Mixed"
        }
    }
}
