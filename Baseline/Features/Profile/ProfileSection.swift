import Foundation

enum ProfileSection: String, CaseIterable, Identifiable {
    case workouts = "Workouts"
    case progress = "Progress"

    var id: Self { self }
}
