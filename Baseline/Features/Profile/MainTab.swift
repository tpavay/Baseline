import Foundation

/// The signed-in shell's tabs. `.today` hosts `TodayView`, whose home surface is the weekly
/// overview — hence the "Weekly" label. Ad-hoc training (the old Train tab) now starts from the
/// Plan tab's per-day add sheet, so training no longer needs its own tab.
enum MainTab: Hashable, CaseIterable {
    case today
    case plan
    case profile

    var title: String {
        switch self {
        case .today: "Weekly"
        case .plan: "Plan"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "clock.arrow.circlepath"
        case .plan: "list.bullet.rectangle"
        case .profile: "person.circle.fill"
        }
    }
}
