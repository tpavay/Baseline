import SwiftUI

/// Frame collection for Plan View's custom long-press drag gesture.
///
/// Preferences keep geometry observational: layout reports where rows are, while the pure
/// `PlanDragReorderModel` decides which insertion target that geometry represents.
enum PlanDragGeometryPreferences {
    struct SessionFrames: PreferenceKey {
        static let defaultValue: [UUID: CGRect] = [:]

        static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
        }
    }

    struct DayFrames: PreferenceKey {
        static let defaultValue: [Date: CGRect] = [:]

        static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
        }
    }
}
