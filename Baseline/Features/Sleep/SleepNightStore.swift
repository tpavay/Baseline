import Foundation

/// Where canonical nights land. Protocol-first so the ingestion pipeline never sees the storage
/// technology — Slice 2 swaps in a SwiftData-backed implementation without touching the engine
/// or orchestrator.
@MainActor
protocol SleepNightStore: AnyObject {
    func night(for date: Date) -> SleepNight?
    func upsert(_ night: SleepNight)
    /// All stored nights, oldest first.
    func allNights() -> [SleepNight]
}

/// The Slice 1 implementation — in-memory only, keyed by the night's recovery day.
@MainActor
final class InMemorySleepNightStore: SleepNightStore {
    private var nightsByDate: [Date: SleepNight] = [:]

    func night(for date: Date) -> SleepNight? {
        nightsByDate[date]
    }

    func upsert(_ night: SleepNight) {
        nightsByDate[night.date] = night
    }

    func allNights() -> [SleepNight] {
        nightsByDate.values.sorted { $0.date < $1.date }
    }
}
