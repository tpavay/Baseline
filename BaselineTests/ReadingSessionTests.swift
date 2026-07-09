import Foundation
import Testing
@testable import Baseline

/// A controllable heart-signal source for driving `ReadingSession` deterministically.
private final class MockHeartSource: HeartSignalSource {
    var rrIntervals: [Double] = []
    var currentHR: Int = 0
    var captureStatus: String = "mock"
    var hasSignal: Bool = false
    private(set) var capturing = false
    func startReadingCapture() { capturing = true }
    func stopReadingCapture() { capturing = false }
}

@MainActor
@Suite("Reading session phase machine")
struct ReadingSessionTests {

    // The tick loop only runs when the test awaits; these tests drive transitions synchronously and
    // never await, so `hasSignal` stays false and the loop never auto-advances mid-assertion.
    private func makeSession(countdown: TimeInterval = 6) -> (ReadingSession, MockHeartSource) {
        let src = MockHeartSource()
        let session = ReadingSession(
            type: .morning, duration: 150, countdownDuration: countdown,
            usesLivePreview: true, source: src
        )
        return (session, src)
    }

    @Test("Intro parks until dismissIntro, which then starts capture + the countdown")
    func introFlow() {
        let (session, src) = makeSession()
        session.start(showIntro: true)
        #expect(session.phase == .intro)
        #expect(src.capturing == false)      // no torch/capture while the intro is up
        session.dismissIntro()
        #expect(session.phase == .countdown) // countdown begins immediately on GOT IT
        #expect(src.capturing == true)
        session.stop()
    }

    @Test("No-intro start begins the countdown immediately, then reading")
    func countdownFlow() {
        let (session, src) = makeSession(countdown: 6)
        session.start()
        #expect(session.phase == .countdown)  // straight into the countdown
        #expect(src.capturing == true)
        #expect(session.countdownRemaining >= 5 && session.countdownRemaining <= 6)

        session.beginReading()
        #expect(session.phase == .reading)
        #expect(session.remaining == 150)     // fresh window, elapsed 0
        session.stop()
    }

    @Test("No result exists before the reading finishes")
    func noResultBeforeComplete() {
        let (session, _) = makeSession()
        session.start()
        session.beginReading()
        #expect(session.result == nil)
        session.stop()
    }

    @Test("dismissIntro is a no-op outside the intro phase")
    func phaseGuards() {
        let (session, _) = makeSession()
        session.start()                    // .countdown
        session.dismissIntro()             // ignored (not in intro)
        #expect(session.phase == .countdown)
        session.beginReading()             // .reading
        #expect(session.phase == .reading)
        session.stop()
    }

    @Test("lastBeatIntervalMs reflects the newest R-R interval")
    func lastBeatInterval() {
        let (session, src) = makeSession()
        #expect(session.lastBeatIntervalMs == nil)
        src.rrIntervals = [900, 1000, 1100]
        #expect(session.lastBeatIntervalMs == 1100)
    }
}
