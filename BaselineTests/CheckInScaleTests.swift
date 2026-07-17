import Foundation
import Testing
@testable import Baseline

struct CheckInScaleTests {

    // 5 = most recovered, regardless of which visual end that is.
    @Test func orientationEndsAreBestAndWorst() {
        // Mood / energy: best on the right.
        #expect(CheckInComponent.mood.scale.oriented(displayIndex: 0) == 1)          // Angry (left)
        #expect(CheckInComponent.mood.scale.oriented(displayIndex: 4) == 5)          // Happy (right)
        #expect(CheckInComponent.energy.scale.oriented(displayIndex: 0) == 1)        // Exhausted (left)
        #expect(CheckInComponent.energy.scale.oriented(displayIndex: 4) == 5)        // Full of energy (right)

        // Soreness / stress: best on the LEFT (none), worst on the right.
        #expect(CheckInComponent.soreness.scale.oriented(displayIndex: 0) == 5)      // None (left) = best
        #expect(CheckInComponent.soreness.scale.oriented(displayIndex: 5) == 1)      // Extremely sore (right)
        #expect(CheckInComponent.stress.scale.oriented(displayIndex: 0) == 5)        // None (left) = best
        #expect(CheckInComponent.stress.scale.oriented(displayIndex: 3) == 1)        // High (right)
    }

    @Test func orientedValuesStayInScoringRange() {
        for c in CheckInComponent.allCases {
            for i in 0..<c.scale.count {
                let v = c.scale.oriented(displayIndex: i)
                #expect(v >= 1 && v <= 5)
            }
        }
    }

    @Test func displayIndexRoundTrips() {
        for c in CheckInComponent.allCases {
            let scale = c.scale
            for i in 0..<scale.count {
                #expect(scale.displayIndex(forOriented: scale.oriented(displayIndex: i)) == i)
            }
        }
    }

    @Test func labelsMatchSteps() {
        // Soreness "extremely sore" sits at the worst-recovery value (oriented 1).
        #expect(CheckInComponent.soreness.scale.label(forOriented: 1).contains("Extremely sore"))
        // Mood best carries the happy emoji.
        #expect(CheckInComponent.mood.scale.label(forOriented: 5).contains("Happy"))
        #expect(CheckInComponent.mood.scale.label(forOriented: 5).contains("😄"))
    }

    @Test func stepCountsMatchSpec() {
        #expect(CheckInComponent.soreness.scale.count == 6)
        #expect(CheckInComponent.energy.scale.count == 5)
        #expect(CheckInComponent.mood.scale.count == 5)
        #expect(CheckInComponent.stress.scale.count == 4)
        #expect(CheckInComponent.sleepQuality.scale.count == 5)
    }

    // Sleep quality shows in the check-in only when Health sleep isn't already covering it.
    @Test func visibleComponentsGateSleepOnHealth() {
        var config = ReadinessConfig()
        config.checkInComponents = [.soreness, .mood, .sleepQuality]

        config.sleepEnabled = true
        #expect(!config.visibleCheckInComponents.contains(.sleepQuality))

        config.sleepEnabled = false
        #expect(config.visibleCheckInComponents.contains(.sleepQuality))
    }
}
