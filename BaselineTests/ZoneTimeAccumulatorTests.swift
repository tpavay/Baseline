import Foundation
import Testing
@testable import Baseline

/// AC-7 (unit): the pure seconds-in-zone accumulator, independent of any clock or BLE.
struct ZoneTimeAccumulatorTests {

    @Test func startsEmpty() {
        let acc = ZoneTimeAccumulator()
        #expect(acc.total == 0)
        for zone in HeartRateZone.allCases {
            #expect(acc.seconds(in: zone) == 0)
        }
    }

    @Test func creditAccumulatesPerZone() {
        var acc = ZoneTimeAccumulator()
        acc.credit(.z2, seconds: 3)
        acc.credit(.z2, seconds: 2)
        acc.credit(.z4, seconds: 5)
        #expect(acc.seconds(in: .z2) == 5)
        #expect(acc.seconds(in: .z4) == 5)
        #expect(acc.seconds(in: .z1) == 0)
        #expect(acc.total == 10)
    }

    @Test func nonPositiveDurationsIgnored() {
        var acc = ZoneTimeAccumulator()
        acc.credit(.z3, seconds: 0)
        acc.credit(.z3, seconds: -4)
        #expect(acc.seconds(in: .z3) == 0)
        #expect(acc.total == 0)
    }

    @Test func orderedReadoutCoversAllZones() {
        var acc = ZoneTimeAccumulator()
        acc.credit(.z5, seconds: 7)
        let ordered = acc.secondsByZoneOrdered
        #expect(ordered.map(\.zone) == HeartRateZone.allCases)
        #expect(ordered.last?.seconds == 7)
    }
}
