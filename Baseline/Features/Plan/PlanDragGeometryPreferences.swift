import Observation
import SwiftUI

/// The finger's offset from where the lifted session started, and nothing else.
///
/// It is deliberately not part of `PlanView`'s `@State`: the drag callback fires at touch frequency,
/// and a `@State` write there would rebuild the whole seven-day grid - every day group, swipe row,
/// context menu and `GeometryReader` - once per frame to move one floating overlay. Held in an
/// `@Observable` box instead, only the small view that actually reads `translation` re-renders, while
/// the insertion indicator and day locks keep updating through `dragState` when the target changes.
@MainActor
@Observable
final class PlanDragMotion {
    var translation: CGSize = .zero
}

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
