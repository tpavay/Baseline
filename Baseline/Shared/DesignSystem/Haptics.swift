import UIKit

/// Centralized haptics (Ascend pattern) so screens never scatter raw generators.
@MainActor
enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let notification = UINotificationFeedbackGenerator()

    /// Card/toggle selections.
    static func select() {
        selection.selectionChanged()
        selection.prepare()
    }

    /// Step advances and button taps.
    static func tap() {
        light.impactOccurred()
        light.prepare()
    }

    /// Milestones (formula locked, reminder set).
    static func milestone() {
        medium.impactOccurred()
        medium.prepare()
    }

    static func success() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    /// A strong, unmistakable confirming buzz — the camera reading locking on and starting.
    static func heavyStart() {
        heavy.impactOccurred(intensity: 1.0)
        notification.notificationOccurred(.success)
        heavy.prepare()
    }

    /// The reading-finished moment: a heavy impact then a success chime, paired with the bell.
    static func readingComplete() {
        heavy.impactOccurred(intensity: 1.0)
        notification.notificationOccurred(.success)
        heavy.prepare()
    }

    /// The score-reveal moment: three light pulses, then success.
    static func celebrate() async {
        for _ in 0..<3 {
            light.impactOccurred()
            try? await Task.sleep(for: .milliseconds(70))
        }
        notification.notificationOccurred(.success)
    }
}
