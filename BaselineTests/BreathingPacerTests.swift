import Foundation
import Testing
@testable import Baseline

struct BreathingPacerTests {

    @Test func startsFullyExhaledOnInhale() {
        let s = BreathingPacer.state(atElapsed: 0)
        #expect(s.phase == .inhale)
        #expect(abs(s.scale - 0) < 0.0001)
    }

    @Test func midInhaleIsHalfScale() {
        let s = BreathingPacer.state(atElapsed: 2.5)
        #expect(s.phase == .inhale)
        #expect(abs(s.scale - 0.5) < 0.0001)   // smoothstep(0.5) == 0.5
    }

    @Test func turnToExhaleIsFullyInhaled() {
        let s = BreathingPacer.state(atElapsed: 5)
        #expect(s.phase == .exhale)
        #expect(abs(s.scale - 1) < 0.0001)
    }

    @Test func midExhaleIsHalfScale() {
        let s = BreathingPacer.state(atElapsed: 7.5)
        #expect(s.phase == .exhale)
        #expect(abs(s.scale - 0.5) < 0.0001)
    }

    @Test func cycleRepeatsEveryTenSeconds() {
        let a = BreathingPacer.state(atElapsed: 1)
        let b = BreathingPacer.state(atElapsed: 11)
        #expect(a.phase == b.phase)
        #expect(abs(a.scale - b.scale) < 0.0001)
    }
}
