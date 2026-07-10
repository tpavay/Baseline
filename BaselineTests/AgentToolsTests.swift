import Foundation
import Testing
@testable import Baseline

@MainActor
struct AgentToolsTests {

    private func tools(base: DecisionEngine.Inputs) -> AgentTools {
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "tools-\(UUID().uuidString)")!)
        return AgentTools(store: store, base: base)
    }

    private var greenBase: DecisionEngine.Inputs {
        DecisionEngine.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5, soreness: 5)
    }

    @Test func checkInFromChatMovesOffNoEvidence() {
        // Day-one user with no HRV/sleep — "wiped out, super stressed" must produce a real plan,
        // not evaporate into a note. This is the conversation-first promise.
        let t = tools(base: DecisionEngine.Inputs())
        #expect(t.dispatch(.getToday).decision?.evidenceTier == DecisionEngine.EvidenceTier.none)
        let r = t.dispatch(.setCheckIn(energy: 1, mood: 2, stress: 1, soreness: nil))
        #expect(r.decision?.evidenceTier != DecisionEngine.EvidenceTier.none)
        #expect(r.decision?.domains.contains { $0.domain == .subjective } == true)
        #expect(r.text.contains("Check-in"))
    }

    @Test func reportedShortSleepCapsThePlan() {
        let t = tools(base: DecisionEngine.Inputs())
        let r = t.dispatch(.setSleep(hours: 4))
        #expect(r.decision?.appliedCaps.contains { $0.reason == "poorSleep" } == true)
        #expect(r.decision?.domains.contains { $0.domain == .sleep } == true)
    }

    @Test func emptyCheckInAsksRatherThanLogs() {
        let t = tools(base: DecisionEngine.Inputs())
        let r = t.dispatch(.setCheckIn(energy: nil, mood: nil, stress: nil, soreness: nil))
        #expect(r.decision == nil)                              // nothing logged
        #expect(r.text.localizedCaseInsensitiveContains("tell me"))
    }

    @Test func getTodayReturnsThePlan() {
        let r = tools(base: greenBase).dispatch(.getToday)
        #expect(r.plan != nil)
        #expect(r.decision?.band == .green)
        #expect(r.text.contains("Plan:"))
    }

    @Test func setTimeRecomputesWithNote() {
        let t = tools(base: greenBase)
        let r = t.dispatch(.setTimeAvailable(25))
        #expect(r.plan?.why.contains { $0.contains("25 min") } == true)
        #expect(r.text.contains("25 min"))
    }

    @Test func loggingAConstraintRerouteThePlan() {
        let t = tools(base: greenBase)
        let r = t.dispatch(.upsertConstraint(id: nil, kind: .injury, location: "Right Achilles",
                                             severity: 2, affectsTraining: true))
        #expect(r.plan?.type == .lowImpact)                                   // green body, rerouted
        #expect(r.plan?.avoid.contains { $0.localizedCaseInsensitiveContains("achilles") } == true)
    }

    @Test func nonTrainingConstraintDoesNotChangeThePlan() {
        let t = tools(base: greenBase)
        let r = t.dispatch(.upsertConstraint(id: nil, kind: .injury, location: "Left pinky",
                                             severity: 3, affectsTraining: false))
        #expect(r.decision?.band == .green)                                   // honored — no gate
    }

    @Test func upsertRejectsEmptyLocation() {
        let t = tools(base: greenBase)
        let r = t.dispatch(.upsertConstraint(id: nil, kind: .pain, location: "  ",
                                             severity: 2, affectsTraining: true))
        #expect(r.plan == nil)                                                // rejected, no mutation
        #expect(r.text.localizedCaseInsensitiveContains("location"))
    }

    @Test func illnessDowngradesThePlan() {
        let r = tools(base: greenBase).dispatch(.setIllness(true))
        #expect(r.decision?.band == .red)
        #expect(r.plan?.type == .activeRecovery)           // sick user no longer gets "intensity on"
    }

    @Test func resolvingMissingConstraintReportsFailure() {
        let r = tools(base: greenBase).dispatch(.resolveConstraint(id: UUID()))
        #expect(r.plan == nil)                             // nothing mutated
        #expect(r.text.localizedCaseInsensitiveContains("couldn't find"))
    }

    @Test func negativeTimeIsSanitizedInTheMessage() {
        let r = tools(base: greenBase).dispatch(.setTimeAvailable(-20))
        #expect(!r.text.contains("-20"))                   // no lie: stored 0, reports 0
        #expect(r.text.contains("0 min"))
    }

    @Test func explainDescribesLimiterAndAvoid() {
        // A capped day so there's a limiter to explain.
        let base = DecisionEngine.Inputs(lnRMSSD: 5.0, energy: 5, mood: 5, stress: 5, soreness: 1)
        let r = tools(base: base).dispatch(.explain)
        #expect(r.text.localizedCaseInsensitiveContains("limiter"))
        #expect(r.text.localizedCaseInsensitiveContains("avoid"))
    }
}
