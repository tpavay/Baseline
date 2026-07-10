import Foundation
import Testing
@testable import Baseline

@MainActor
struct TrainingContextStoreTests {

    private func freshStore() -> TrainingContextStore {
        TrainingContextStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }

    @Test func dailyRollsOverOnNewDay() {
        let s = freshStore()
        s.setTimeAvailable(25)
        #expect(s.daily.timeAvailableMinutes == 25)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        s.rolloverIfNeeded(now: tomorrow)
        #expect(s.daily.timeAvailableMinutes == nil)      // fresh day → cleared
    }

    @Test func upsertCreatesThenUpdatesInPlace() {
        let s = freshStore()
        let id = s.upsertConstraint(kind: .injury, location: "Right hamstring", severity: 2)
        #expect(s.constraints.count == 1)
        s.upsertConstraint(id: id, kind: .injury, location: "Right hamstring", severity: 3)
        #expect(s.constraints.count == 1)                  // updated, not duplicated
        #expect(s.constraints.first?.severity == 3)
    }

    @Test func severityIsClamped() {
        let s = freshStore()
        s.upsertConstraint(kind: .pain, location: "Achilles", severity: 9)
        #expect(s.constraints.first?.severity == 3)
    }

    @Test func resolvedConstraintsDropOutOfActive() {
        let s = freshStore()
        let id = s.upsertConstraint(kind: .injury, location: "Knee", severity: 2)
        #expect(s.activeConstraints.count == 1)
        s.resolveConstraint(id: id)
        #expect(s.activeConstraints.isEmpty)               // gone for the engine
        #expect(s.constraints.count == 1)                  // but archived, not deleted
    }

    @Test func activeConstraintsMapForTheEngine() {
        let s = freshStore()
        s.upsertConstraint(kind: .injury, location: "Right Achilles", severity: 3)
        let mapped = s.activeConstraints
        #expect(mapped.count == 1)
        #expect(mapped.first?.location == "Right Achilles")
        #expect(mapped.first?.severity == 3)
        // And it gates a green body via the Decision Engine.
        let r = DecisionEngine.compute(DecisionEngine.Inputs(lnRMSSD: 5.0, energy: 5, mood: 5, stress: 5,
                                                             soreness: 5, constraints: mapped))
        #expect(r.score <= 45)
        #expect(r.primaryLimiter == .musculoskeletal)
    }

    @Test func statePersistsAcrossStores() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let s1 = TrainingContextStore(defaults: suite)
        s1.setTimeAvailable(40)
        s1.upsertConstraint(kind: .pain, location: "Lower back", severity: 1)
        let s2 = TrainingContextStore(defaults: suite)
        #expect(s2.daily.timeAvailableMinutes == 40)
        #expect(s2.constraints.count == 1)
        #expect(s2.constraints.first?.location == "Lower back")
    }
}
