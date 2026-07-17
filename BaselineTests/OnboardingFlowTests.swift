import Foundation
import Testing
@testable import Baseline

@Suite("Onboarding flow computation")
struct OnboardingFlowTests {

    private func draft(
        heart: Bool = true,
        source: HeartSource? = .strap,
        sleep: Bool = true,
        checkIn: Bool = true
    ) -> OnboardingDraft {
        var draft = OnboardingDraft()
        draft.config.heartReadingEnabled = heart
        draft.config.heartSource = source
        draft.config.sleepEnabled = sleep
        draft.config.checkInEnabled = checkIn
        return draft
    }

    @Test("Strap athlete walks the full flow, pairing included")
    func strapFlow() {
        let steps = OnboardingFlow.steps(for: draft(source: .strap))
        #expect(steps.contains(.heartSource))
        #expect(steps.contains(.strapPairing))
        #expect(steps.contains(.firstReading))
        // Value-first: the score reveal precedes auth, which precedes commitment.
        #expect(steps.firstIndex(of: .scoreReveal)! < steps.firstIndex(of: .auth)!)
        #expect(steps.firstIndex(of: .auth)! < steps.firstIndex(of: .commitment)!)
        #expect(steps.last == .reminder)
    }

    @Test("Camera athlete configures a source and takes the reading, but skips strap pairing")
    func cameraFlow() {
        let steps = OnboardingFlow.steps(for: draft(source: .camera))
        #expect(steps.contains(.heartSource))
        #expect(!steps.contains(.strapPairing))    // no BLE device to pair
        #expect(steps.contains(.firstReading))     // camera reading runs through the same engine
        #expect(steps.contains(.checkIn))
        #expect(steps.contains(.scoreReveal))
    }

    @Test("Heart reading off removes source, pairing, and reading — score still happens")
    func subjectiveOnlyFlow() {
        let steps = OnboardingFlow.steps(for: draft(heart: false, source: nil))
        #expect(!steps.contains(.heartSource))
        #expect(!steps.contains(.strapPairing))
        #expect(!steps.contains(.firstReading))
        #expect(steps.contains(.checkIn))
        #expect(steps.contains(.scoreReveal))
    }

    @Test("Check-in off removes the check-in step")
    func noCheckInFlow() {
        let steps = OnboardingFlow.steps(for: draft(checkIn: false))
        #expect(!steps.contains(.checkIn))
        #expect(steps.contains(.scoreReveal))
    }

    @Test("Profile calibration steps follow auth, in order")
    func profileStepsAfterAuth() {
        let steps = OnboardingFlow.steps(for: draft())
        let authIdx = steps.firstIndex(of: .auth)!
        let tail = Array(steps[authIdx...].prefix(6))
        #expect(tail == [.auth, .trainingExperience, .gender, .age, .height, .weight])
    }

    @Test("Experience + gender gate on selection; age/height/weight always advance")
    func profileGates() {
        var d = draft()
        d.experience = nil
        #expect(!OnboardingFlow.canAdvance(from: .trainingExperience, draft: d))
        d.experience = .dedicated
        #expect(OnboardingFlow.canAdvance(from: .trainingExperience, draft: d))

        d.biologicalSex = nil
        #expect(!OnboardingFlow.canAdvance(from: .gender, draft: d))
        d.biologicalSex = .male
        #expect(OnboardingFlow.canAdvance(from: .gender, draft: d))

        #expect(OnboardingFlow.canAdvance(from: .age, draft: d))
        #expect(OnboardingFlow.canAdvance(from: .height, draft: d))
        #expect(OnboardingFlow.canAdvance(from: .weight, draft: d))
    }

    @Test("Back from every step returns to its predecessor")
    func backNavigation() {
        let d = draft()
        let steps = OnboardingFlow.steps(for: d)
        for (i, step) in steps.enumerated() {
            let previous = OnboardingFlow.step(before: step, draft: d)
            #expect(previous == (i == 0 ? nil : steps[i - 1]))
        }
    }

    @Test("Advance walks the whole flow and terminates")
    func forwardWalk() {
        let d = draft()
        var current: OnboardingStep? = .welcome
        var visited = 0
        while let step = current, visited < 50 {
            visited += 1
            current = OnboardingFlow.step(after: step, draft: d)
        }
        #expect(current == nil)
        #expect(visited == OnboardingFlow.steps(for: d).count)
    }

    @Test("Gating: name, objective, attribution, formula validity, commitment")
    func gates() {
        var d = draft()
        d.name = ""
        #expect(!OnboardingFlow.canAdvance(from: .name, draft: d))
        d.name = "Tyler"
        #expect(OnboardingFlow.canAdvance(from: .name, draft: d))

        #expect(!OnboardingFlow.canAdvance(from: .objective, draft: d))
        d.objective = .preventInjury
        #expect(OnboardingFlow.canAdvance(from: .objective, draft: d))

        d.config.heartReadingEnabled = false
        d.config.sleepEnabled = false
        d.config.checkInEnabled = false
        #expect(!OnboardingFlow.canAdvance(from: .formula, draft: d))
        d.config.checkInEnabled = true
        #expect(OnboardingFlow.canAdvance(from: .formula, draft: d))

        #expect(!OnboardingFlow.canAdvance(from: .commitment, draft: d))
        d.committed = true
        #expect(OnboardingFlow.canAdvance(from: .commitment, draft: d))
    }

    @Test("Toggling config mid-flow reshapes the remaining steps")
    func reshaping() {
        var d = draft(source: .strap)
        // Apple Health always follows the formula; the heart-source step appears after it only
        // when the heart reading is enabled.
        #expect(OnboardingFlow.step(after: .appleHealth, draft: d) == .heartSource)
        d.config.heartReadingEnabled = false
        #expect(OnboardingFlow.step(after: .appleHealth, draft: d) == .firstReadingIntro)
    }
}

@Suite("Config-aware readiness score")
struct ReadinessScoreTests {

    @Test("Subjective raw-sum matches the spec formula")
    func subjectiveFormula() {
        #expect(ReadinessScore.subjectiveScore([3, 3, 3, 3]) == 50)   // all-neutral
        #expect(ReadinessScore.subjectiveScore([5, 5, 5, 5]) == 100)
        #expect(ReadinessScore.subjectiveScore([1, 1, 1, 1]) == 0)
        #expect(ReadinessScore.subjectiveScore([4, 4]) == 75)         // k adapts
        #expect(ReadinessScore.subjectiveScore([]) == nil)
    }

    @Test("Sleep score plateaus over 7–9h and penalizes short/long")
    func sleepMapping() {
        #expect(ReadinessScore.sleepScore(hours: 8) == 100)
        #expect(ReadinessScore.sleepScore(hours: 7.5) == 100)
        #expect(ReadinessScore.sleepScore(hours: 6)! < 100)
        #expect(ReadinessScore.sleepScore(hours: 5)! < ReadinessScore.sleepScore(hours: 6)!)
        #expect(ReadinessScore.sleepScore(hours: 11)! < 100)   // oversleep penalty
        #expect(ReadinessScore.sleepScore(hours: nil) == nil)  // no data drops out
        // Efficiency pulls a good duration down when poor.
        let poorEff = ReadinessScore.sleepScore(hours: 8, efficiency: 0.70)!
        #expect(poorEff < 100)
    }

    @Test("All-neutral check-in lands mid-amber (70), never red — an average day isn't a bad day")
    func neutralIsAmber() {
        let r = ReadinessScore.compute(.init(checkIn: [3, 3, 3, 3]))
        #expect(r.score == 70)
        #expect(r.band == .amber)
        #expect(r.calibrating)   // no HRV baseline → cold start
    }

    @Test("Green needs a worthwhile positive day; red needs a clearly bad one")
    func bandThresholds() {
        // All-4s (good across the board) → green; all-2s (poor) → red; all-3s (normal) → amber.
        #expect(ReadinessScore.compute(.init(checkIn: [4, 4, 4, 4])).band == .green)
        #expect(ReadinessScore.compute(.init(checkIn: [3, 3, 3, 3])).band == .amber)
        #expect(ReadinessScore.compute(.init(checkIn: [2, 2, 2, 2])).band == .red)
    }

    @Test("Sleep actually moves the score (the reported bug)")
    func sleepChangesScore() {
        // Same neutral check-in, but great vs terrible sleep must diverge.
        let greatSleep = ReadinessScore.compute(.init(sleepScore: 100, checkIn: [3, 3, 3, 3]))
        let poorSleep = ReadinessScore.compute(.init(sleepScore: 10, checkIn: [3, 3, 3, 3]))
        #expect(greatSleep.score > poorSleep.score)
    }

    @Test("HRV contributes and re-normalizes over present inputs")
    func hrvContributes() {
        let highHRV = ReadinessScore.compute(.init(lnRMSSD: log(90), checkIn: [3, 3, 3, 3]))
        let lowHRV = ReadinessScore.compute(.init(lnRMSSD: log(20), checkIn: [3, 3, 3, 3]))
        #expect(highHRV.score > lowHRV.score)
    }

    @Test("Empty inputs never crash — safe neutral-amber fallback")
    func emptyInputs() {
        let r = ReadinessScore.compute(.init())
        #expect(r.score == 70)
        #expect(r.band == .amber)
    }

    @Test("Extreme soreness/stress floors the band at amber")
    func subjectiveFloor() {
        // Great HRV + great sleep would be green, but soreness=1 caps at 79.
        let floored = ReadinessScore.compute(.init(
            lnRMSSD: log(95), sleepScore: 100, checkIn: [1, 5, 5, 1], soreness: 1, stress: 5
        ))
        #expect(floored.score <= 79)
        #expect(floored.band != .green)
    }

    @Test("HRV reading score maps lnRMSSD to 0-100 (higher HRV = higher score)")
    func hrvReadingScoreMapping() {
        let high = ReadinessScore.hrvReadingScore(lnRMSSD: log(120))  // strong athlete HRV
        let mid = ReadinessScore.hrvReadingScore(lnRMSSD: 3.8)        // population centre
        let low = ReadinessScore.hrvReadingScore(lnRMSSD: log(18))    // suppressed
        #expect(high > mid && mid > low)
        #expect((1...100).contains(high) && (1...100).contains(low))
        #expect(mid == 70)   // neutral lnRMSSD lands at the neutral score
    }

    @Test("Rolling baseline computes mean/SD/count; empty is nil")
    func rollingBaseline() {
        #expect(ReadinessScore.baseline(from: []) == nil)
        let flat = ReadinessScore.baseline(from: [log(50), log(50), log(50)])!
        #expect(flat.count == 3)
        #expect(abs(flat.mean - log(50)) < 1e-9)
        #expect(flat.sd < 1e-9)                       // identical values → ~0 SD
        let two = ReadinessScore.baseline(from: [1, 3])!
        #expect(two.mean == 2)
        #expect(abs(two.sd - 2.0.squareRoot()) < 1e-9) // sample SD of [1,3] = √2
    }

    @Test("Personal baseline engages at calibrationThreshold (4), not before")
    func baselineThreshold() {
        #expect(ReadinessScore.calibrationThreshold == 4)
        let lowBaseline = ReadinessScore.Baseline(mean: log(30), sd: 0.2, count: 4)
        let calibrated = ReadinessScore.hrvReadingScore(lnRMSSD: log(60), baseline: lowBaseline)
        let cold = ReadinessScore.hrvReadingScore(lnRMSSD: log(60),
            baseline: ReadinessScore.Baseline(mean: log(30), sd: 0.2, count: 3))
        // count 3 → still population frame; count 4 → personal frame (60 is far above a low
        // personal baseline, so it scores clearly higher).
        #expect(calibrated > cold)
    }

    @Test("Bands map correctly")
    func bands() {
        #expect(ReadinessScore.band(for: 85) == .green)
        #expect(ReadinessScore.band(for: 70) == .amber)
        #expect(ReadinessScore.band(for: 40) == .red)
    }
}

@Suite("Camera PPG signal processing")
struct PPGProcessorTests {

    @Test("Detects a clean 60 bpm synthetic pulse")
    func synthetic60bpm() {
        var p = PPGProcessor()
        // 60 bpm = 1 Hz. Sample at 30 fps for 8 s.
        let fps = 30.0, hz = 1.0
        for i in 0..<Int(fps * 8) {
            let t = Double(i) / fps
            // A finger-present bright field (~0.6) modulated by the pulse.
            let sample = 0.6 + 0.03 * sin(2 * .pi * hz * t)
            _ = p.ingest(sample: sample, at: t)
        }
        // Should have detected roughly one beat per second → ~7–8 IBIs near 1000 ms.
        #expect(p.ibis.count >= 5)
        if let hr = p.currentHR {
            #expect(hr >= 50 && hr <= 72)   // ≈60 bpm within tolerance
        }
    }

    @Test("Detects a pulse from a jittery ~15 fps stream (resampling)")
    func jittery15fps() {
        // The real camera delivers ~15 fps with timing jitter, not a clean 30 fps grid. The
        // resampler must still recover the beat. 66 bpm = 1.1 Hz.
        var p = PPGProcessor()
        let hz = 1.1
        var t = 0.0
        for i in 0..<200 {
            // ~15 fps with ±20 ms jitter (deterministic, seedless).
            let jitter = (Double((i * 37) % 40) - 20) / 1000.0
            t += 1.0 / 15.0 + jitter
            let sample = 0.7 + 0.02 * sin(2 * .pi * hz * t)
            _ = p.ingest(sample: sample, at: t)
        }
        #expect(p.ibis.count >= 5)
        let hr = p.currentHR ?? 0
        #expect(hr >= 56 && hr <= 76)   // ≈66 bpm within tolerance
    }

    @Test("Finger gate keys off red dominance (auto-WB torch-lit fingertip)")
    func fingerGate() {
        // Finger over torch with auto WB: bright red field (the HRV4Training solid-red circle).
        #expect(PPGProcessor.fingerPresent(red: 0.85, green: 0.25, blue: 0.20))
        #expect(PPGProcessor.fingerPresent(red: 0.55, green: 0.30, blue: 0.25))
        // No finger: balanced/grey or dark → rejected.
        #expect(!PPGProcessor.fingerPresent(red: 0.5, green: 0.5, blue: 0.5))    // grey scene
        #expect(!PPGProcessor.fingerPresent(red: 0.20, green: 0.15, blue: 0.10)) // too dark
    }
}
