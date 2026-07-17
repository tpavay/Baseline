import Foundation
import Testing
@testable import Baseline

/// AC-1: `HeartRateZone` shape — five ordered cases, display names, and color tokens.
struct HeartRateZoneTests {

    @Test func hasFiveOrderedCases() {
        #expect(HeartRateZone.allCases == [.z1, .z2, .z3, .z4, .z5])
        #expect(HeartRateZone.allCases.map(\.rawValue) == [1, 2, 3, 4, 5])
    }

    @Test func orderingHolds() {
        #expect(HeartRateZone.z1 < HeartRateZone.z2)
        #expect(HeartRateZone.z2 < HeartRateZone.z3)
        #expect(HeartRateZone.z3 < HeartRateZone.z4)
        #expect(HeartRateZone.z4 < HeartRateZone.z5)
        #expect(HeartRateZone.allCases == HeartRateZone.allCases.sorted())
    }

    @Test func displayNames() {
        #expect(HeartRateZone.allCases.map(\.displayName) == ["Z1", "Z2", "Z3", "Z4", "Z5"])
    }

    @Test func everyZoneHasATitleAndColorToken() {
        for zone in HeartRateZone.allCases {
            #expect(!zone.title.isEmpty)
            #expect(!zone.colorToken.isEmpty)
        }
    }

    @Test func colorTokensFollowBlueToRedSpectrum() {
        #expect(HeartRateZone.z1.colorToken == "zoneBlue")
        #expect(HeartRateZone.z2.colorToken == "zoneGreen")
        #expect(HeartRateZone.z3.colorToken == "zoneAmber")
        #expect(HeartRateZone.z4.colorToken == "zoneOrange")   // 5th hue arrives with Slice 3 UI
        #expect(HeartRateZone.z5.colorToken == "zoneRed")
    }
}
