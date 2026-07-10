import Foundation
import SwiftData

/// The kind of HRV reading. Both are quiet natural-breath reads — they differ only in length:
/// the morning ritual (2:30) vs. a quick snapshot (1:00) for frequent checks.
enum ReadingType: String, Codable, CaseIterable, Identifiable, Sendable {
    case morning
    case snapshot

    var id: String { rawValue }
    var duration: TimeInterval { self == .morning ? 150 : 60 }
    var title: String { self == .morning ? "Morning HRV reading" : "HRV snapshot" }
    var lengthLabel: String { self == .morning ? "2:30" : "1:00" }
    var blurb: String {
        self == .morning
            ? "Measure your readiness for the day."
            : "A quick HRV check, anytime."
    }
}

/// The morning reading length is a free duration (not fixed presets): 1:00 – 5:59, set with an
/// M:SS wheel. Stored as whole seconds on `AppSettings`.
enum ReadingLength {
    static let range = 60...359
    static let `default` = 150

    /// "M:SS" for a whole-second length.
    static func label(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Body position during the reading. Position materially affects HRV (a 70 ms reading lying down
/// isn't comparable to 70 ms standing), so it's logged per reading for trend accuracy + filtering.
/// The athlete sets it once; it defaults and rarely changes.
enum BodyPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case lyingDown
    case sitting
    case standing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lyingDown: "Lying down"
        case .sitting: "Sitting"
        case .standing: "Standing"
        }
    }
    var icon: String {
        switch self {
        case .lyingDown: "bed.double.fill"
        case .sitting: "figure.seated.side"
        case .standing: "figure.stand"
        }
    }
}

/// Finalized output of a completed reading, before it's persisted. Keeps SwiftData model
/// creation out of `ReadingSession` (which has no `ModelContext`).
/// Where a reading's beats came from — drives how it's captured, exported, and displayed.
enum ReadingSource: String, Codable, CaseIterable, Sendable {
    case camera
    case chestStrap

    var title: String {
        switch self {
        case .camera: "Camera"
        case .chestStrap: "Chest strap"
        }
    }
}

struct ReadingResult: Equatable, Sendable {
    var type: ReadingType
    var durationSeconds: Int
    var meanHR: Double
    var minHR: Int
    var maxHR: Int
    var rmssd: Double
    var lnRMSSD: Double
    var beatCount: Int
    /// Raw R-R intervals (ms) as detected — kept unmodified for diagnostics/export.
    var rrIntervalsMs: [Double]
    /// How many intervals the artifact-correction pass replaced, and the resulting quality rating.
    /// (The HRV numbers above are computed on the *corrected* series.)
    var artifacts: Int = 0
    var signalQuality: HRV.SignalQuality = .good
}

/// A saved HRV reading — the source of truth for history and (later) the readiness baseline.
/// CloudKit-safe per project rules: every property has a default, no `.unique`, no required
/// relationships. Designed to map cleanly to an App Entity later.
@Model
final class Reading {
    var id: UUID = UUID()
    var date: Date = Date.now
    var kind: ReadingType = ReadingType.snapshot
    var durationSeconds: Int = 60
    var meanHR: Double = 0
    var minHR: Int = 0
    var maxHR: Int = 0
    var rmssd: Double = 0
    var lnRMSSD: Double = 0
    var beatCount: Int = 0
    var rrIntervalsMs: [Double] = []
    var position: BodyPosition = BodyPosition.lyingDown

    // Fields added after the model shipped. Stored as *optional* backing so readings saved before
    // they existed decode as nil (SwiftData doesn't backfill non-optional defaults on old rows — a
    // non-optional enum would crash on the nil cast). Non-optional computed accessors give call
    // sites a clean value with a safe fallback.
    private var sourceRawValue: String?
    private var deviceNameValue: String?
    private var artifactsValue: Int?
    private var signalQualityRawValue: String?

    var source: ReadingSource {
        get { sourceRawValue.flatMap(ReadingSource.init(rawValue:)) ?? .chestStrap }
        set { sourceRawValue = newValue.rawValue }
    }
    var deviceName: String {
        get { deviceNameValue ?? "" }
        set { deviceNameValue = newValue }
    }
    var artifacts: Int {
        get { artifactsValue ?? 0 }
        set { artifactsValue = newValue }
    }
    var signalQuality: HRV.SignalQuality {
        get { signalQualityRawValue.flatMap(HRV.SignalQuality.init(rawValue:)) ?? .good }
        set { signalQualityRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        date: Date = .now,
        kind: ReadingType = .snapshot,
        durationSeconds: Int = 60,
        meanHR: Double = 0,
        minHR: Int = 0,
        maxHR: Int = 0,
        rmssd: Double = 0,
        lnRMSSD: Double = 0,
        beatCount: Int = 0,
        rrIntervalsMs: [Double] = [],
        position: BodyPosition = .lyingDown,
        source: ReadingSource = .chestStrap,
        deviceName: String = "",
        artifacts: Int = 0,
        signalQuality: HRV.SignalQuality = .good
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.meanHR = meanHR
        self.minHR = minHR
        self.maxHR = maxHR
        self.rmssd = rmssd
        self.lnRMSSD = lnRMSSD
        self.beatCount = beatCount
        self.rrIntervalsMs = rrIntervalsMs
        self.position = position
        self.source = source
        self.deviceName = deviceName
        self.artifacts = artifacts
        self.signalQuality = signalQuality
    }

    convenience init(result: ReadingResult, position: BodyPosition = .lyingDown,
                     source: ReadingSource = .chestStrap, deviceName: String = "", date: Date = .now) {
        self.init(
            date: date,
            kind: result.type,
            durationSeconds: result.durationSeconds,
            meanHR: result.meanHR,
            minHR: result.minHR,
            maxHR: result.maxHR,
            rmssd: result.rmssd,
            lnRMSSD: result.lnRMSSD,
            beatCount: result.beatCount,
            rrIntervalsMs: result.rrIntervalsMs,
            position: position,
            source: source,
            deviceName: deviceName,
            artifacts: result.artifacts,
            signalQuality: result.signalQuality
        )
    }
}
