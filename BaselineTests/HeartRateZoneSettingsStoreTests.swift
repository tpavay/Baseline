import Foundation
import Testing
@testable import Baseline

/// AC-2: the local zone-settings store round-trips the config across re-init, defaults sensibly when
/// absent, and gates writes so a degenerate config can never be persisted. Uses an injected, isolated
/// `UserDefaults` suite (no `.standard`, no shared state) and a fixed injected age.
@MainActor
struct HeartRateZoneSettingsStoreTests {

    /// A private, isolated defaults suite; cleared so tests never bleed into each other or real prefs.
    private func makeDefaults() -> UserDefaults {
        let name = "hr-zone-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsWhenAbsent() {
        let store = HeartRateZoneSettingsStore(defaults: makeDefaults(), ageYears: { 30 })
        #expect(store.settings.isEmpty)
        #expect(store.settings.maxHROverride == nil)
        #expect(store.resolvedMaxHR == HeartRateZoneModel(age: 30).maxHR)   // Tanaka(30) = 187
        #expect(store.method == .percentMax)
        #expect(store.model != nil)
    }

    @Test func roundTripsAcrossReinit() {
        let defaults = makeDefaults()
        let config = HeartRateZoneSettings(maxHROverride: 190, restingHR: 50, lthr: 168)

        let writer = HeartRateZoneSettingsStore(defaults: defaults, ageYears: { 30 })
        #expect(writer.update(config))
        #expect(writer.settings == config)

        // A fresh store over the same defaults reloads the persisted config.
        let reader = HeartRateZoneSettingsStore(defaults: defaults, ageYears: { 30 })
        #expect(reader.settings == config)
        #expect(reader.resolvedMaxHR == 190)
        #expect(reader.method == .heartRateReserve)
    }

    @Test func writePersistsEachField() {
        let defaults = makeDefaults()
        let store = HeartRateZoneSettingsStore(defaults: defaults, ageYears: { 28 })
        #expect(store.update(HeartRateZoneSettings(maxHROverride: 200)))
        #expect(store.update(HeartRateZoneSettings(maxHROverride: 200, restingHR: 55)))

        let reloaded = HeartRateZoneSettingsStore(defaults: defaults, ageYears: { 28 })
        #expect(reloaded.settings.maxHROverride == 200)
        #expect(reloaded.settings.restingHR == 55)
    }

    @Test func gatedWriteRejectsInvalidAndKeepsPriorConfig() {
        let defaults = makeDefaults()
        let store = HeartRateZoneSettingsStore(defaults: defaults, ageYears: { 30 })
        let valid = HeartRateZoneSettings(maxHROverride: 190, restingHR: 50)
        #expect(store.update(valid))

        // resting ≥ max is refused; the prior valid config stands and nothing degenerate persists.
        #expect(store.update(HeartRateZoneSettings(maxHROverride: 120, restingHR: 120)) == false)
        #expect(store.settings == valid)

        let reloaded = HeartRateZoneSettingsStore(defaults: defaults, ageYears: { 30 })
        #expect(reloaded.settings == valid)
    }

    @Test func ageClosureFeedsMaxHRResolution() {
        // The store reads age through the injected closure, not Firestore or a stored value.
        var age = 30
        let store = HeartRateZoneSettingsStore(defaults: makeDefaults(), ageYears: { age })
        #expect(store.resolvedMaxHR == HeartRateZoneModel(age: 30).maxHR)
        age = 50
        #expect(store.resolvedMaxHR == HeartRateZoneModel(age: 50).maxHR)
    }
}
