import Foundation

/// Where canonical nights land. Protocol-first so the ingestion pipeline never sees the storage
/// technology — Slice 2 swaps in a SwiftData-backed implementation without touching the engine
/// or orchestrator.
@MainActor
protocol SleepNightStore: AnyObject {
    func night(for date: Date) -> SleepNight?
    func upsert(_ night: SleepNight)
    /// Delete the canonical night for a recovery day — the outcome when a HealthKit deletion
    /// delta leaves a night with no composing samples at all.
    func remove(for date: Date)
    /// Recovery days of stored nights composed from any of these sample UUIDs — the
    /// deletion-delta → night mapping (`HKDeletedObject` carries only a UUID).
    func nightDates(containingSampleUUIDs uuids: [UUID]) -> [Date]
    /// All stored nights, oldest first.
    func allNights() -> [SleepNight]
}

/// The in-memory implementation, keyed by the night's recovery day.
@MainActor
final class InMemorySleepNightStore: SleepNightStore {
    private var nightsByDate: [Date: SleepNight] = [:]

    func night(for date: Date) -> SleepNight? {
        nightsByDate[date]
    }

    func upsert(_ night: SleepNight) {
        nightsByDate[night.date] = night
    }

    func remove(for date: Date) {
        nightsByDate[date] = nil
    }

    func nightDates(containingSampleUUIDs uuids: [UUID]) -> [Date] {
        guard !uuids.isEmpty else { return [] }
        let deleted = Set(uuids)
        return nightsByDate.values
            .filter { !deleted.isDisjoint(with: $0.composingSampleUUIDs) }
            .map(\.date)
    }

    func allNights() -> [SleepNight] {
        nightsByDate.values.sorted { $0.date < $1.date }
    }
}
