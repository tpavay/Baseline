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

    // MARK: - Context summary (the model's durable state — verification for the memory fix)

    @Test func contextSummarySurfacesSavedConstraintAndContext() {
        let t = tools(base: DecisionEngine.Inputs())
        t.dispatch(.upsertConstraint(id: nil, kind: .injury, location: "right achilles", severity: 2, affectsTraining: true))
        t.dispatch(.setSleep(hours: 4))
        let summary = t.contextSummary()
        #expect(summary.localizedCaseInsensitiveContains("achilles"))
        #expect(summary.contains("slept 4h"))
    }

    @Test func freshToolsOnSameStoreStillKnowTheConstraint() {
        // Starting a new conversation must not erase structured context.
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        AgentTools(store: store, base: DecisionEngine.Inputs())
            .dispatch(.upsertConstraint(id: nil, kind: .pain, location: "left calf", severity: 2, affectsTraining: true))
        // A brand-new AgentTools (i.e. a fresh chat) over the same store still sees it.
        let summary = AgentTools(store: store, base: DecisionEngine.Inputs()).contextSummary()
        #expect(summary.localizedCaseInsensitiveContains("calf"))
    }

    @Test func reMentioningAConstraintUpdatesInsteadOfDuplicating() {
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let t = AgentTools(store: store, base: DecisionEngine.Inputs())
        // "My right calf hurts" then "actually it's not limiting training" — same body part twice.
        t.dispatch(.upsertConstraint(id: nil, kind: .pain, location: "right calf", severity: 1, affectsTraining: true))
        t.dispatch(.upsertConstraint(id: nil, kind: .pain, location: "Right Calf", severity: 1, affectsTraining: false))
        #expect(store.activeConstraintRecords.count == 1)                 // folded, not duplicated
        #expect(store.activeConstraintRecords.first?.affectsTraining == false)
    }

    @Test func contextSummaryReportsCapabilities() {
        // With a health service present, the model is told Apple Health status + the connect action.
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let t = AgentTools(store: store, base: DecisionEngine.Inputs(), health: HealthService(), hrvConfigured: false)
        let summary = t.contextSummary()
        #expect(summary.localizedCaseInsensitiveContains("Apple Health"))
        #expect(summary.localizedCaseInsensitiveContains("HRV reading"))
        // Mapper accepts the action tool.
        #expect(ToolCallMapper.map(name: "open_apple_health_setup", input: [:]) == .openAppleHealthSetup)
    }

    @Test func contextSummaryDoesNotInventUnknowns() {
        let summary = tools(base: DecisionEngine.Inputs()).contextSummary()
        #expect(summary.localizedCaseInsensitiveContains("nothing"))   // says nothing is on file
        #expect(!summary.localizedCaseInsensitiveContains("achilles"))
        #expect(!summary.localizedCaseInsensitiveContains("slept"))
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
