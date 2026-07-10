import Foundation
import Testing
@testable import Baseline

struct MetricsTests {

    @Test func canonicalUnits() {
        #expect(MetricType.distance.canonicalUnit == .meters)
        #expect(MetricType.load.canonicalUnit == .kilograms)
        #expect(MetricType.duration.canonicalUnit == .seconds)
    }

    @Test func distanceConvertsBothWays() {
        #expect(abs(MetricConvert.fromCanonical(1609.344, .distance, to: .miles) - 1.0) < 0.0001)
        #expect(abs(MetricConvert.fromCanonical(1000, .distance, to: .kilometers) - 1.0) < 0.0001)
        #expect(abs(MetricConvert.toCanonical(1, .distance, from: .miles) - 1609.344) < 0.0001)
        #expect(abs(MetricConvert.toCanonical(5, .distance, from: .kilometers) - 5000) < 0.0001)
    }

    @Test func loadConvertsKgPounds() {
        #expect(abs(MetricConvert.fromCanonical(100, .load, to: .pounds) - 220.462) < 0.01)
        #expect(abs(MetricConvert.toCanonical(225, .load, from: .pounds) - 102.058) < 0.01)
    }

    @Test func metricValuesStoreTypedAndEncodeAsObject() throws {
        var v = MetricValues()
        v[.distance] = 1000
        v.setInt(.reps, 8)
        #expect(v[.distance] == 1000)
        #expect(v.int(.reps) == 8)
        #expect(v.present.contains(.distance))
        // Canonical Codable round-trip; encodes as a keyed object, not an array.
        let data = try JSONEncoder().encode(v)
        #expect(String(data: data, encoding: .utf8)!.contains("distance"))
        #expect(try JSONDecoder().decode(MetricValues.self, from: data) == v)
    }
}

struct ExerciseCatalogTests {

    @Test func resolvesCasualLanguageToStableIds() {
        #expect(ExerciseCatalog.resolve("spin bike").id == "stationary_bike")
        #expect(ExerciseCatalog.resolve("Concept2 Bike").id == "bike_erg")
        #expect(ExerciseCatalog.resolve("rower").id == "row")
        #expect(ExerciseCatalog.resolve("farmers carry").id == "loaded_carry")
        #expect(ExerciseCatalog.resolve("Copenhagen").id == "isometric_hold")
    }

    @Test func unknownMovementFallsBackToGeneric() {
        #expect(ExerciseCatalog.resolve("kettlebell swing").id == "generic")
    }

    @Test func definitionsDeclareSupportedMetricsAndCategory() {
        let bike = ExerciseCatalog.definition(id: "stationary_bike")!
        #expect(bike.category == .cycling)
        #expect(bike.supported.contains(.distance))
        #expect(bike.defaults == [.duration, .distance])
        #expect(ExerciseCatalog.definition(id: "deadlift")?.category == .strength)
    }
}
