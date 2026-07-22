import Foundation

enum MainTab: Hashable {
    case today
    case plan
    case profile

    var title: String {
        switch self {
        case .today: "Today"
        case .plan: "Plan"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "circle.dotted"
        case .plan: "list.bullet.rectangle"
        case .profile: "person.crop.circle"
        }
    }
}
