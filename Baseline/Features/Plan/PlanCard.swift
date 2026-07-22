import SwiftUI

/// Structural actions a calendar row can request; `PlanView` maps each to a versioned repository mutation.
enum PlanCardAction: Equatable {
    case open, duplicate, skip, unskip, delete, move(Date)
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
}
