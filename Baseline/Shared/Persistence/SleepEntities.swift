import Foundation
import SwiftData

/// SwiftData **persistence adapters** for the Sleep domain (plan §7). Storage only — the value
/// types in `Baseline/Features/Sleep/` are canonical; `SwiftDataSleepRepository` maps between
/// them. Engines and UI never touch these.
///
/// CloudKit-safe per CLAUDE.md: no `@Attribute(.unique)`, every stored property has a default or
/// is optional, no SwiftData relationships (UUID keys only). Scalars that may evolve use the
/// optional-backing + computed-accessor pattern from day one — adding a non-optional scalar to a
/// live @Model crashes existing rows (see memory: swiftdata-new-enum-field-crash).

@Model final class SDSleepNight {
    var id: UUID = UUID()
    /// Canonical, timezone-tolerant day key: `yyyymmdd` of the wake day *as assembled*. Lookups
    /// key on this, not on the `date` instant — after a timezone change, startOfDay instants for
    /// the same calendar day differ by hours, and instant-keyed lookups would duplicate nights.
    var dayKey: Int = 0
    /// The wake day's startOfDay instant in the calendar the night was assembled under.
    var date: Date = Date.distantPast
    /// The full episode/interval structure as ONE Codable blob (`[SleepEpisode]`), encoded with
    /// `SleepCoding`'s pinned date strategy — same blob tradeoff as `Workout` logs.
    var episodesJSON: Data = Data()
    var bedtime: Date?
    var wakeTime: Date?
    var asleepHours: Double?
    var inBedHours: Double?
    var awakenings: Int?
    var wasoMinutes: Double?
    /// `SleepSource` blob. nil or unreadable decodes to `.none` — honest degradation, never a
    /// fabricated device source.
    var resolvedSourceJSON: Data?
    var analysisStatusRaw: String = SleepAnalysisStatus.provisional.rawValue
    var sourceFingerprint: String = ""
    /// `[UUID]` blob — the winning source's HealthKit sample UUIDs, so deletion deltas (which
    /// carry only UUIDs) can be mapped back to the nights they composed (AC-5).
    var composingSampleUUIDsJSON: Data?
    var lastHealthKitSyncAt: Date?
    var lastSampleEndDate: Date?
    var revisionBacking: Int?
    var factsSchemaVersionBacking: Int?
    // Reserved for Slice 3 (plan §7's three-way versioning): the derived-analysis blob and its
    // independent versions. Declared now so the schema is stable; never populated in Slice 2.
    var analysisJSON: Data?
    var aggregationVersionBacking: Int?
    var scoreAlgorithmVersionBacking: Int?

    init(id: UUID = UUID(), dayKey: Int = 0, date: Date = Date.distantPast,
         episodesJSON: Data = Data(), bedtime: Date? = nil, wakeTime: Date? = nil,
         asleepHours: Double? = nil, inBedHours: Double? = nil,
         awakenings: Int? = nil, wasoMinutes: Double? = nil,
         resolvedSourceJSON: Data? = nil,
         analysisStatusRaw: String = SleepAnalysisStatus.provisional.rawValue,
         sourceFingerprint: String = "", composingSampleUUIDsJSON: Data? = nil,
         lastHealthKitSyncAt: Date? = nil, lastSampleEndDate: Date? = nil,
         revisionBacking: Int? = nil, factsSchemaVersionBacking: Int? = nil) {
        self.id = id; self.dayKey = dayKey; self.date = date
        self.episodesJSON = episodesJSON; self.bedtime = bedtime; self.wakeTime = wakeTime
        self.asleepHours = asleepHours; self.inBedHours = inBedHours
        self.awakenings = awakenings; self.wasoMinutes = wasoMinutes
        self.resolvedSourceJSON = resolvedSourceJSON
        self.analysisStatusRaw = analysisStatusRaw
        self.sourceFingerprint = sourceFingerprint
        self.composingSampleUUIDsJSON = composingSampleUUIDsJSON
        self.lastHealthKitSyncAt = lastHealthKitSyncAt; self.lastSampleEndDate = lastSampleEndDate
        self.revisionBacking = revisionBacking; self.factsSchemaVersionBacking = factsSchemaVersionBacking
    }

    /// Optional-backing accessors: a row written before these fields existed reads as a valid
    /// first-revision night instead of crashing or lying.
    var revision: Int {
        get { revisionBacking ?? 0 }
        set { revisionBacking = newValue }
    }

    /// Rows predating the field can only be schema v1 — the version that lacked it.
    var factsSchemaVersion: Int {
        get { factsSchemaVersionBacking ?? 1 }
        set { factsSchemaVersionBacking = newValue }
    }
}

/// One anchored-query cursor per sample-type query (plan §5: the cursor is per query, never per
/// night). `anchorData` is an `NSKeyedArchiver` secure-coding archive of the `HKQueryAnchor`;
/// only `HealthService` ever unarchives it.
@Model final class SDSleepSyncState {
    var id: UUID = UUID()
    var queryKey: String = ""
    var anchorData: Data?
    var updatedAt: Date = Date.distantPast

    init(id: UUID = UUID(), queryKey: String = "", anchorData: Data? = nil, updatedAt: Date = Date.distantPast) {
        self.id = id; self.queryKey = queryKey; self.anchorData = anchorData; self.updatedAt = updatedAt
    }
}

/// The Sleep store schema. Deliberately NOT registered on the app's ModelContainer in this
/// slice — registration (and any migration wiring) lands with Slice 4, so the running app
/// cannot reach the store yet. Referenced from tests only until then.
enum SleepSchema {
    static let models: [any PersistentModel.Type] = [SDSleepNight.self, SDSleepSyncState.self]
}
