import Testing
@testable import Baseline

/// The screen should stay awake only while actively logging a workout, so a user can glance at their
/// live heart rate without the display dimming or locking. Viewing a template or reviewing the
/// completed summary keeps normal idle behavior.
@MainActor
struct WorkoutKeepAwakeTests {
    @Test func keepsScreenAwakeWhileLogging() {
        #expect(WorkoutView.shouldKeepScreenAwake(for: .log))
    }

    @Test func allowsIdleOutsideLogging() {
        #expect(!WorkoutView.shouldKeepScreenAwake(for: .view))
        #expect(!WorkoutView.shouldKeepScreenAwake(for: .editTemplate))
        #expect(!WorkoutView.shouldKeepScreenAwake(for: .completed))
    }
}
