import Foundation
import Testing
@testable import Baseline

/// A controllable Health body-mass store: scripted authorization, a settable latest sample, and
/// a record of every save - so the recorder is exercised without a live `HKHealthStore`.
@MainActor
private final class FakeBodyMassStore: BodyMassHealthStore {
    var bodyMassAuthorization: BodyMassAuthorization = .authorized
    /// What authorization becomes after the permission sheet - models the athlete's choice.
    var authorizationAfterRequest: BodyMassAuthorization = .authorized
    var latest: Double?
    var saveError: Error?

    private(set) var requestCount = 0
    private(set) var saved: [BodyMassSaveRequest] = []

    func requestBodyMassAuthorization() async {
        requestCount += 1
        bodyMassAuthorization = authorizationAfterRequest
    }

    func latestBodyMassKilograms() async -> Double? { latest }

    func saveBodyMass(_ request: BodyMassSaveRequest) async throws {
        if let saveError { throw saveError }
        saved.append(request)
    }
}

@MainActor
@Suite("Morning weight entry")
struct MorningWeightEntryTests {

    private let store = FakeBodyMassStore()
    private let defaults: UserDefaults
    private let calendar: Calendar

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "morning-weight-\(UUID().uuidString)"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        calendar = cal
    }

    private var recorder: MorningWeightRecorder {
        MorningWeightRecorder(health: store, defaults: defaults, calendar: calendar)
    }

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour))!
    }

    // MARK: - Units (never mis-unit an entered number)

    @Test("An imperial entry converts to canonical kilograms - the typed number is never stored as kg")
    func imperialEntryConverts() throws {
        let unit = UnitSystem.imperial.displayUnit(metric: .load, exercise: nil)
        let kg = try #require(MetricFormat.parse("180", .load, unit: unit))
        #expect(abs(kg - 180 * MetricConvert.kgPerPound) < 0.0001)
        #expect(abs(kg - 81.6466) < 0.001)
        #expect(kg != 180)   // the failure mode this guards: lb stored as kg
    }

    @Test("A metric entry stays exactly what was typed")
    func metricEntryIsCanonical() throws {
        let unit = UnitSystem.metric.displayUnit(metric: .load, exercise: nil)
        #expect(try #require(MetricFormat.parse("82.5", .load, unit: unit)) == 82.5)
    }

    @Test("Display round-trips: a canonical weight shown then re-parsed lands on the same value")
    func displayRoundTrips() throws {
        for system in UnitSystem.allCases {
            let unit = system.displayUnit(metric: .load, exercise: nil)
            let shown = MetricFormat.editText(81.6466, .load, unit: unit)
            let back = try #require(MetricFormat.parse(shown, .load, unit: unit))
            #expect(abs(back - 81.6466) < 0.05, "unit system \(system)")
        }
    }

    @Test("The display unit follows the athlete's unit system, the same door as every load")
    func displayUnitFollowsSetting() {
        #expect(UnitSystem.metric.displayUnit(metric: .load, exercise: nil) == .kilograms)
        #expect(UnitSystem.imperial.displayUnit(metric: .load, exercise: nil) == .pounds)
    }

    // MARK: - Validation

    @Test("The accepted range rejects typos and impossible weights, in canonical kilograms")
    func validationRange() {
        #expect(MorningWeightPolicy.isValid(kilograms: 30))
        #expect(MorningWeightPolicy.isValid(kilograms: 82.5))
        #expect(MorningWeightPolicy.isValid(kilograms: 300))
        #expect(!MorningWeightPolicy.isValid(kilograms: 29.9))
        #expect(!MorningWeightPolicy.isValid(kilograms: 300.1))
        #expect(!MorningWeightPolicy.isValid(kilograms: 0))
        #expect(!MorningWeightPolicy.isValid(kilograms: -80))
        #expect(!MorningWeightPolicy.isValid(kilograms: .nan))
        #expect(!MorningWeightPolicy.isValid(kilograms: .infinity))
    }

    // MARK: - Skip path

    @Test("Skipping writes nothing: prefill alone never saves, requests, or invents a value")
    func skipWritesNothing() async {
        store.latest = nil
        let prefill = await recorder.prefillKilograms(fallback: nil)
        #expect(prefill == nil)          // no known weight → empty field, never a made-up number
        #expect(store.saved.isEmpty)
        #expect(store.requestCount == 0) // skipping must not even prompt for Health access
    }

    // MARK: - Authorized write

    @Test("An authorized entry writes one body-mass sample with the value, date, provenance, and per-day identity")
    func authorizedWrite() async throws {
        let date = day(2026, 7, 23)
        let outcome = await recorder.record(kilograms: 81.6, on: date)
        #expect(outcome == .savedToHealth)
        let sample = try #require(store.saved.first)
        #expect(store.saved.count == 1)
        #expect(sample.kilograms == 81.6)
        #expect(sample.date == date)
        #expect(sample.wasUserEntered)   // provenance: typed, never machine-measured
        #expect(sample.syncIdentifier == "com.tylerpavay.Baseline.morning-weight.2026-07-23")
        #expect(sample.syncVersion == 1)
    }

    // MARK: - Duplicate resistance

    @Test("Retrying the same value on the same day writes nothing new")
    func retryIsIdempotent() async {
        let date = day(2026, 7, 23)
        let recorder = recorder
        #expect(await recorder.record(kilograms: 81.6, on: date) == .savedToHealth)
        #expect(await recorder.record(kilograms: 81.6, on: date) == .alreadySaved)
        #expect(store.saved.count == 1)
    }

    @Test("Re-entering a different value the same day replaces via the same sync identifier, higher version")
    func reentryReplacesInsteadOfDuplicating() async throws {
        let date = day(2026, 7, 23)
        let recorder = recorder
        #expect(await recorder.record(kilograms: 81.6, on: date) == .savedToHealth)
        #expect(await recorder.record(kilograms: 82.0, on: date) == .savedToHealth)
        let second = try #require(store.saved.last)
        #expect(store.saved.count == 2)
        #expect(second.syncIdentifier == store.saved.first?.syncIdentifier)
        #expect(second.syncVersion == 2)   // same identity + higher version → Health replaces
    }

    @Test("A new day gets its own identity and starts back at version 1")
    func newDayNewIdentity() async throws {
        let recorder = recorder
        _ = await recorder.record(kilograms: 81.6, on: day(2026, 7, 23))
        _ = await recorder.record(kilograms: 81.6, on: day(2026, 7, 24))
        let second = try #require(store.saved.last)
        #expect(store.saved.count == 2)   // same value, different day → a real new sample
        #expect(second.syncIdentifier == "com.tylerpavay.Baseline.morning-weight.2026-07-24")
        #expect(second.syncVersion == 1)
    }

    // MARK: - Authorization paths

    @Test("A not-yet-asked athlete is prompted exactly once, then the write proceeds")
    func requestsOnFirstSave() async {
        store.bodyMassAuthorization = .notDetermined
        store.authorizationAfterRequest = .authorized
        #expect(await recorder.record(kilograms: 81.6, on: day(2026, 7, 23)) == .savedToHealth)
        #expect(store.requestCount == 1)
        #expect(store.saved.count == 1)
    }

    @Test("Declining the permission sheet keeps the entry and writes nothing")
    func declinedSheetIsGraceful() async {
        store.bodyMassAuthorization = .notDetermined
        store.authorizationAfterRequest = .denied
        let recorder = recorder
        #expect(await recorder.record(kilograms: 81.6, on: day(2026, 7, 23)) == .healthDenied)
        #expect(store.saved.isEmpty)
        // The number is not lost: it prefills the next entry from Baseline's own cache.
        store.latest = nil
        #expect(await recorder.prefillKilograms() == 81.6)
    }

    @Test("Previously denied access short-circuits - no re-prompt, no write, no crash")
    func deniedShortCircuits() async {
        store.bodyMassAuthorization = .denied
        #expect(await recorder.record(kilograms: 81.6, on: day(2026, 7, 23)) == .healthDenied)
        #expect(store.requestCount == 0)
        #expect(store.saved.isEmpty)
    }

    @Test("No HealthKit on the device still keeps the entry locally")
    func unavailableIsGraceful() async {
        store.bodyMassAuthorization = .unavailable
        let recorder = recorder
        #expect(await recorder.record(kilograms: 90, on: day(2026, 7, 23)) == .healthUnavailable)
        #expect(store.saved.isEmpty)
        #expect(await recorder.prefillKilograms() == 90)
    }

    @Test("A failed Health save reports the error outcome and still caches the entry")
    func saveErrorIsGraceful() async {
        store.saveError = NSError(domain: "test", code: 1)
        let recorder = recorder
        #expect(await recorder.record(kilograms: 81.6, on: day(2026, 7, 23)) == .healthError)
        #expect(store.saved.isEmpty)
        #expect(await recorder.prefillKilograms() == 81.6)
        // The failure left no dedup bookkeeping, so a retry actually writes.
        store.saveError = nil
        #expect(await recorder.record(kilograms: 81.6, on: day(2026, 7, 23)) == .savedToHealth)
        #expect(store.saved.count == 1)
    }

    // MARK: - Prefill precedence

    @Test("Prefill prefers Health's latest, then the last entry here, then the profile fallback")
    func prefillPrecedence() async {
        let recorder = recorder
        // Nothing known anywhere → only the fallback.
        #expect(await recorder.prefillKilograms(fallback: 79) == 79)
        // A previous entry outranks the fallback.
        _ = await recorder.record(kilograms: 82, on: day(2026, 7, 22))
        #expect(await recorder.prefillKilograms(fallback: 79) == 82)
        // Health's latest (any app) outranks both.
        store.latest = 81.2
        #expect(await recorder.prefillKilograms(fallback: 79) == 81.2)
    }
}
