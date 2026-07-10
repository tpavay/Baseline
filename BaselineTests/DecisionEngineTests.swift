import Foundation
import Testing
@testable import Baseline

private typealias DE = DecisionEngine
private typealias PE = PlanningEngine

struct DecisionEngineTests {

    // MARK: - Blend + bands

    @Test func emptyInputsAreNeutralAmberLowCertainty() {
        let r = DE.compute(DE.Inputs())
        #expect(r.score == 70)
        #expect(r.band == .amber)
        #expect(r.certainty == .low)
        #expect(r.domains.isEmpty)
        #expect(r.primaryLimiter == nil)
    }

    @Test func allGoodReadsGreen() {
        let r = DE.compute(DE.Inputs(lnRMSSD: 5.0, sleepScore: 100,
                                     energy: 5, mood: 5, stress: 5, soreness: 5))
        #expect(r.band == .green)
        #expect(r.score >= 80)
    }

    @Test func neutralSubjectiveIsAmber70() {
        let r = DE.compute(DE.Inputs(energy: 3, mood: 3, stress: 3, soreness: 3))
        #expect(r.score == 70)
        #expect(r.band == .amber)
    }

    @Test func allLowReadsRed() {
        let r = DE.compute(DE.Inputs(lnRMSSD: 3.0, sleepScore: 20,
                                     energy: 1, mood: 1, stress: 1, soreness: 1))
        #expect(r.band == .red)
    }

    // MARK: - Domains present / absent + renormalization

    @Test func domainsAppearOnlyWhenPresent() {
        let r = DE.compute(DE.Inputs(lnRMSSD: 4.0, energy: 4))
        let present = Set(r.domains.map(\.domain))
        #expect(present.contains(.autonomic))
        #expect(present.contains(.subjective))
        #expect(!present.contains(.sleep))
        #expect(!present.contains(.trainingLoad))   // reserved: nil loadRatio → absent
    }

    @Test func reservedTrainingLoadDoesNotShiftScore() {
        // Absent training load must renormalize out — not act like a phantom 50.
        let base = DE.compute(DE.Inputs(lnRMSSD: 4.6, energy: 4))
        let withLoad = DE.compute(DE.Inputs(lnRMSSD: 4.6, energy: 4, loadRatio: 1.0))
        #expect(base.domains.allSatisfy { $0.domain != .trainingLoad })
        #expect(withLoad.domains.contains { $0.domain == .trainingLoad })
        // Adding a present-and-neutralish domain changes the score only modestly, never wildly.
        #expect(abs(base.score - withLoad.score) <= 12)
    }

    // MARK: - Caps + limiter

    @Test func severeSorenessCapsAndNamesLimiter() {
        let r = DE.compute(DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5, soreness: 1))
        #expect(r.score <= 60)
        #expect(r.primaryLimiter == .musculoskeletal)
        #expect(r.appliedCaps.contains { $0.reason == "severeSoreness" })
    }

    @Test func highLoadCapsAtSeventy() {
        let r = DE.compute(DE.Inputs(lnRMSSD: 5.0, energy: 5, loadRatio: 1.6))
        #expect(r.score <= 70)
        #expect(r.appliedCaps.contains { $0.reason == "highLoad" })
    }

    @Test func autonomicSuppressionCaps() {
        // Low HRV + elevated resting HR → suppression cap 50, autonomic limiter.
        let r = DE.compute(DE.Inputs(lnRMSSD: 3.0, restingHR: 72, energy: 5))
        #expect(r.score <= 50)
        #expect(r.primaryLimiter == .autonomic)
    }

    @Test func vagalSaturationIsNotCapped() {
        // Low HRV but LOW resting HR = saturation, softened — must NOT trip the suppression cap.
        let r = DE.compute(DE.Inputs(lnRMSSD: 3.4, restingHR: 42, energy: 5))
        #expect(!r.appliedCaps.contains { $0.reason == "autonomicSuppressed" })
    }

    @Test func bindingCapIsTheLowest() {
        // Two caps fire (soreness 60, stress 70); the binding one (60) sets score + limiter.
        let r = DE.compute(DE.Inputs(lnRMSSD: 5.0, energy: 5, mood: 5, stress: 1, soreness: 1))
        #expect(r.score <= 60)
        #expect(r.primaryLimiter == .musculoskeletal)
        #expect(r.appliedCaps.count >= 2)
    }

    // MARK: - Constraints

    @Test func highConstraintGatesEvenOnAGreenBody() {
        let injury = DE.Constraint(kind: .injury, location: "Right hamstring", severity: 3)
        let r = DE.compute(DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5,
                                     soreness: 5, constraints: [injury]))
        #expect(r.score <= 45)
        #expect(r.primaryLimiter == .musculoskeletal)
    }

    @Test func nonTrainingConstraintDoesNotMoveTheScore() {
        // A high-severity constraint the athlete says doesn't affect training must not cap or penalize.
        let noted = DE.Constraint(kind: .injury, location: "Left pinky", severity: 3, affectsTraining: false)
        let r = DE.compute(DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5,
                                     soreness: 5, constraints: [noted]))
        #expect(r.band == .green)
        #expect(!r.appliedCaps.contains { $0.reason == "injuryHigh" })
        #expect(r.primaryLimiter != .musculoskeletal)
    }

    // MARK: - Certainty

    @Test func certaintyRisesWithEvidence() {
        let baseline = ReadinessScore.Baseline(mean: 4.0, sd: 0.4, count: 10)
        let full = DE.compute(DE.Inputs(lnRMSSD: 4.2, hrvBaseline: baseline, restingHR: 50,
                                        sleepScore: 90, energy: 4, loadRatio: 1.0))
        #expect(full.certainty == .high)
        let thin = DE.compute(DE.Inputs(lnRMSSD: 4.2))
        #expect(thin.certainty == .low)
    }

    // MARK: - Planning

    @Test func greenDayProposesIntensity() {
        let d = DE.compute(DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5, soreness: 5))
        #expect(PE.plan(for: d).type == .hardIntensity)
    }

    @Test func redDayProposesActiveRecovery() {
        let d = DE.compute(DE.Inputs(lnRMSSD: 3.0, sleepScore: 20, energy: 1, mood: 1, stress: 1, soreness: 1))
        #expect(PE.plan(for: d).type == .activeRecovery)
    }

    @Test func constraintReroutesToLowImpactAndAvoidsIt() {
        // Recovered body + a real injury → preserve the day but drop the impact.
        let injury = DE.Constraint(kind: .injury, location: "Right Achilles", severity: 2)
        let d = DE.compute(DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5,
                                     soreness: 5, constraints: [injury]))
        let plan = PE.plan(for: d)
        #expect(plan.type == .lowImpact)
        #expect(plan.avoid.contains { $0.localizedCaseInsensitiveContains("achilles") })
    }

    @Test func guidanceNeverSaysChassis() {
        for band in [DE.Inputs(lnRMSSD: 5, energy: 5), DE.Inputs(energy: 3), DE.Inputs(energy: 1, soreness: 1)] {
            let plan = PE.plan(for: DE.compute(band))
            let text = ([plan.summary] + plan.why + plan.avoid).joined(separator: " ")
            #expect(!text.localizedCaseInsensitiveContains("chassis"))
        }
    }

    @Test func styleShiftsIntensity() {
        let d = DE.compute(DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5, soreness: 5))
        let conservative = PE.plan(for: d, style: .conservative).type
        let aggressive = PE.plan(for: d, style: .aggressive).type
        #expect(conservative != .hardIntensity || aggressive == .hardIntensity) // conservative pulls down
    }

    // MARK: - Daily context + PlanAssembler

    @Test func dailyContextAddsHonestNotes() {
        let d = DE.compute(DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5, soreness: 5))
        let short = PE.plan(for: d, daily: .init(timeAvailableMinutes: 25))
        #expect(short.why.contains { $0.contains("25 min") })
        let travel = PE.plan(for: d, daily: .init(traveling: true))
        #expect(travel.why.contains { $0.localizedCaseInsensitiveContains("traveling") })
    }

    @Test func illnessCapsToRecovery() {
        let r = DE.compute(DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5,
                                     soreness: 5, illness: true))
        #expect(r.score <= 40)
        #expect(r.appliedCaps.contains { $0.reason == "illness" })
        #expect(PE.plan(for: r).type == .activeRecovery)   // sick → recovery, never intensity
    }

    @Test func limitedEquipmentAddsANoteButFullGymDoesNot() {
        let base = DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5, soreness: 5)
        let limited = PlanAssembler.assemble(base: base, dailyContext: .init(equipment: ["bodyweight"]))
        #expect(limited.plan.why.contains { $0.localizedCaseInsensitiveContains("limited equipment") })
        let full = PlanAssembler.assemble(base: base, dailyContext: .init(equipment: ["gym", "barbell"]))
        #expect(!full.plan.why.contains { $0.localizedCaseInsensitiveContains("limited equipment") })
    }

    @Test func planAssemblerLayersContextOntoBase() {
        let base = DE.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5, soreness: 5)
        let constraint = DE.Constraint(kind: .injury, location: "Achilles", severity: 2)
        let ctx = TrainingContextStore.DailyContext(timeAvailableMinutes: 25, traveling: true)
        let out = PlanAssembler.assemble(base: base, dailyContext: ctx, constraints: [constraint])
        #expect(out.decision.constraints.count == 1)
        #expect(out.plan.type == .lowImpact)                                      // constraint reroutes
        #expect(out.plan.avoid.contains { $0.localizedCaseInsensitiveContains("achilles") })
        #expect(out.plan.why.contains { $0.contains("25 min") })                 // daily note layered on
    }
}
