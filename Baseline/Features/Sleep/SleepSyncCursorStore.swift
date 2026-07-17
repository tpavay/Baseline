import Foundation

/// Persists one anchored-query cursor per sample-type query — the HealthKit delta stream position
/// (plan §5: the cursor is per query, never per night). The cursor is opaque `Data`; only
/// `HealthService` knows it wraps an `HKQueryAnchor`. Slice 2 adds a persisted implementation.
@MainActor
protocol SleepSyncCursorStore: AnyObject {
    func cursor(forKey key: String) -> Data?
    func setCursor(_ cursor: Data?, forKey key: String)
}

@MainActor
final class InMemorySleepSyncCursorStore: SleepSyncCursorStore {
    private var cursors: [String: Data] = [:]

    func cursor(forKey key: String) -> Data? {
        cursors[key]
    }

    func setCursor(_ cursor: Data?, forKey key: String) {
        cursors[key] = cursor
    }
}
