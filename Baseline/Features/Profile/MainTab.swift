import Foundation

enum MainTab: Hashable, CaseIterable {
    case today
    case plan
    case train
    case profile

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .train: "Train"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "clock.arrow.circlepath"
        case .plan: "list.bullet.rectangle"
        case .train: "diamond.fill"
        case .profile: "person.circle.fill"
        }
    }
}
