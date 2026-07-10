import Foundation
import Testing
@testable import Baseline

struct ToolCallMapperTests {

    @Test func mapsSimpleCalls() {
        #expect(ToolCallMapper.map(name: "get_today", input: [:]) == .getToday)
        #expect(ToolCallMapper.map(name: "explain", input: [:]) == .explain)
        #expect(ToolCallMapper.map(name: "set_traveling", input: ["traveling": true]) == .setTraveling(true))
        #expect(ToolCallMapper.map(name: "set_illness", input: ["illness": true]) == .setIllness(true))
        #expect(ToolCallMapper.map(name: "set_note", input: ["note": "slept badly"]) == .setNote("slept badly"))
    }

    @Test func mapsRetrievalAndActionTools() {
        #expect(ToolCallMapper.map(name: "get_sleep", input: ["nights_ago": 1]) == .getSleep(nightsAgo: 1))
        #expect(ToolCallMapper.map(name: "get_sleep", input: [:]) == .getSleep(nightsAgo: 0))
        #expect(ToolCallMapper.map(name: "get_hrv_readings", input: ["limit": 5]) == .getHRVReadings(limit: 5))
        #expect(ToolCallMapper.map(name: "get_resting_heart_rate", input: ["days": 14]) == .getRestingHeartRate(days: 14))
        #expect(ToolCallMapper.map(name: "open_apple_health_setup", input: [:]) == .openAppleHealthSetup)
    }

    @Test func mapsSleepAndCheckIn() {
        #expect(ToolCallMapper.map(name: "set_sleep", input: ["hours": 6.5]) == .setSleep(hours: 6.5))
        #expect(ToolCallMapper.map(name: "set_sleep", input: ["hours": 4]) == .setSleep(hours: 4))
        #expect(ToolCallMapper.map(name: "set_sleep", input: ["hours": NSNull()]) == .setSleep(hours: nil))
        // Partial check-in: only the fields the athlete described.
        #expect(ToolCallMapper.map(name: "set_checkin", input: ["energy": 2, "stress": 1])
                == .setCheckIn(energy: 2, mood: nil, stress: 1, soreness: nil))
    }

    @Test func mapsTimeIncludingNullAndDouble() {
        #expect(ToolCallMapper.map(name: "set_time_available", input: ["minutes": 30]) == .setTimeAvailable(30))
        #expect(ToolCallMapper.map(name: "set_time_available", input: ["minutes": 30.0]) == .setTimeAvailable(30))
        #expect(ToolCallMapper.map(name: "set_time_available", input: ["minutes": NSNull()]) == .setTimeAvailable(nil))
    }

    @Test func mapsEquipmentArray() {
        #expect(ToolCallMapper.map(name: "set_equipment", input: ["equipment": ["gym", "barbell"]]) == .setEquipment(["gym", "barbell"]))
        #expect(ToolCallMapper.map(name: "set_equipment", input: ["equipment": NSNull()]) == .setEquipment(nil))
    }

    @Test func mapsUpsertConstraint() {
        let call = ToolCallMapper.map(name: "upsert_constraint",
                                      input: ["kind": "injury", "location": "right Achilles",
                                              "severity": 2, "affectsTraining": true])
        #expect(call == .upsertConstraint(id: nil, kind: .injury, location: "right Achilles",
                                          severity: 2, affectsTraining: true))
    }

    @Test func rejectsMalformedOrUnknown() {
        #expect(ToolCallMapper.map(name: "upsert_constraint", input: ["kind": "injury"]) == nil)          // no location
        #expect(ToolCallMapper.map(name: "upsert_constraint", input: ["location": "knee", "kind": "sprain",
                                                                      "severity": 1, "affectsTraining": true]) == nil) // bad kind
        #expect(ToolCallMapper.map(name: "resolve_constraint", input: ["id": "not-a-uuid"]) == nil)
        #expect(ToolCallMapper.map(name: "delete_everything", input: [:]) == nil)                          // unknown tool
    }
}
