import CryptoKit
import Foundation

/// The pure sleep-ingestion core — normalized raw samples in, canonical `SleepNight`s out.
/// Like `DecisionEngine` it is a side-effect-free enum: no HealthKit, no persistence, no clock of
/// its own (time comes in through `Context`), so every rule is unit-testable from fixtures.
///
/// Pipeline per night: noon-to-noon assignment → multi-source precedence resolution (one winner,
/// never blended) → episode segmentation (primary vs naps, tracking gaps) → awakenings/WASO →
/// deterministic source fingerprint. See docs/implementation/sleep-engine.md §3/§5/§6.
enum SleepIngestionEngine {

    /// How samples normalize into episodes/nights. Bump when this file's rules change shape.
    static let factsSchemaVersion = 1

    // MARK: - Tunables (single source of truth)

    /// Untracked silence longer than this splits the night into separate episodes (split sleep,
    /// naps). Shorter silences stay inside one episode.
    static let episodeGapThreshold: TimeInterval = 60 * 60
    /// Untracked spans longer than this inside an episode are surfaced as tracking gaps —
    /// honest evidence the athlete sees instead of silently shortened sleep.
    static let trackedGapThreshold: TimeInterval = 5 * 60

    /// Everything time- or preference-dependent, injected so the engine stays deterministic.
    struct Context: Sendable {
        var calendar: Calendar
        /// User-selected preferred HealthKit source (Profile setting, post-v0) — precedence tier 1.
        var preferredSourceBundleID: String?
        /// When the samples were fetched — recorded on the night and fed to the stabilization rule.
        var lastSyncAt: Date
        var stabilization: SleepStabilizationRule

        init(calendar: Calendar = .current,
             preferredSourceBundleID: String? = nil,
             lastSyncAt: Date = Date(),
             stabilization: SleepStabilizationRule = SleepStabilizationRule()) {
            self.calendar = calendar
            self.preferredSourceBundleID = preferredSourceBundleID
            self.lastSyncAt = lastSyncAt
            self.stabilization = stabilization
        }
    }

    // MARK: - Night windows (noon-to-noon)

    /// The recovery day a sample/episode ending at `end` belongs to: ends before noon → that day
    /// (a midnight-spanning night lands on its wake day); ends at/after noon → the next day
    /// (an afternoon nap counts toward the next morning's recovery).
    static func nightDate(containing end: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: end)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        guard end >= noon else { return day }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }

    /// The half-open noon-to-noon window whose samples compose the night of `date` (a wake day).
    static func nightWindow(for date: Date, calendar: Calendar) -> DateInterval {
        let wakeDay = calendar.startOfDay(for: date)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: wakeDay) ?? wakeDay
        let start = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: previousDay) ?? previousDay
        let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: wakeDay) ?? wakeDay
        return DateInterval(start: start, end: end)
    }

    // MARK: - Entry points

    /// All canonical nights derivable from `samples`, oldest first. Nights with no asleep
    /// evidence simply don't appear — absence is never imputed.
    static func nights(from samples: [SleepSample], context: Context) -> [SleepNight] {
        let grouped = Dictionary(grouping: normalize(samples)) {
            nightDate(containing: $0.end, calendar: context.calendar)
        }
        return grouped.keys.sorted().compactMap {
            assemble(date: $0, normalized: grouped[$0] ?? [], context: context)
        }
    }

    /// The canonical night for one wake day, or nil when the window holds no asleep evidence.
    static func night(for date: Date, from samples: [SleepSample], context: Context) -> SleepNight? {
        let day = context.calendar.startOfDay(for: date)
        let relevant = normalize(samples).filter {
            nightDate(containing: $0.end, calendar: context.calendar) == day
        }
        return assemble(date: day, normalized: relevant, context: context)
    }

    // MARK: - Normalization

    /// Drops zero/negative-duration samples, removes exact duplicates, and sorts canonically —
    /// the shared front door for assembly and fingerprinting, so both see identical input.
    static func normalize(_ samples: [SleepSample]) -> [SleepSample] {
        var seen = Set<SleepSample>()
        var unique: [SleepSample] = []
        for sample in samples where sample.end > sample.start && seen.insert(sample).inserted {
            unique.append(sample)
        }
        return unique.sorted(by: canonicallyBefore)
    }

    private static func canonicallyBefore(_ l: SleepSample, _ r: SleepSample) -> Bool {
        if l.start != r.start { return l.start < r.start }
        if l.end != r.end { return l.end < r.end }
        if l.kind != r.kind { return l.kind.rawValue < r.kind.rawValue }
        if l.sourceBundleID != r.sourceBundleID { return l.sourceBundleID < r.sourceBundleID }
        return !l.isUserEntered && r.isUserEntered
    }

    // MARK: - Fingerprint

    /// Deterministic digest of the samples composing a canonical night: SHA-256 over a canonical
    /// serialization (source, entry method, kind, start, end — millisecond precision). Stable
    /// across process launches by construction, unlike `Hasher`'s per-launch seed.
    static func fingerprint(of samples: [SleepSample]) -> String {
        let canonical = normalize(samples).map { sample in
            let start = Int((sample.start.timeIntervalSince1970 * 1000).rounded())
            let end = Int((sample.end.timeIntervalSince1970 * 1000).rounded())
            return "\(sample.sourceBundleID)|\(sample.isUserEntered ? 1 : 0)|\(sample.kind.rawValue)|\(start)|\(end)"
        }
        .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Assembly

    private static func assemble(date: Date, normalized: [SleepSample], context: Context) -> SleepNight? {
        guard let winner = resolveSource(normalized, preferredBundleID: context.preferredSourceBundleID) else {
            return nil
        }
        var episodes = segment(stageIntervals(from: winner.samples, source: winner.source))
        guard let primaryIndex = primaryEpisodeIndex(in: episodes) else { return nil }
        episodes[primaryIndex].isPrimary = true
        let primary = episodes[primaryIndex]

        let asleepSpans = primary.intervals.filter { $0.stage.isAsleep }.map { (start: $0.start, end: $0.end) }
        let asleepSeconds = unionDuration(asleepSpans)

        // Awakenings/WASO are only observable from stage-capable sources; a generic or manual
        // source reporting "0 awakenings" would be manufactured confidence.
        var awakenings: Int?
        var wasoMinutes: Double?
        if winner.hasStages,
           let sleepOnset = asleepSpans.map(\.start).min(),
           let sleepEnd = asleepSpans.map(\.end).max() {
            let awakeSpans = primary.intervals.filter { $0.stage == .awake }
                .compactMap { interval -> (start: Date, end: Date)? in
                    let start = max(interval.start, sleepOnset)
                    let end = min(interval.end, sleepEnd)
                    return end > start ? (start, end) : nil
                }
            let merged = mergedSpans(awakeSpans)
            awakenings = merged.count
            wasoMinutes = merged.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60
        }

        let inBedSeconds = unionDuration(
            winner.samples.filter { $0.kind == .inBed }.map { (start: $0.start, end: $0.end) }
        )
        let wakeTime = primary.end
        let status: SleepAnalysisStatus = context.stabilization
            .isStabilized(wakeTime: wakeTime, lastSyncAt: context.lastSyncAt) ? .complete : .provisional

        return SleepNight(
            id: UUID(),
            date: date,
            episodes: episodes,
            bedtime: primary.start,
            wakeTime: wakeTime,
            asleepHours: asleepSeconds / 3600,
            inBedHours: inBedSeconds > 0 ? inBedSeconds / 3600 : nil,
            awakenings: awakenings,
            wasoMinutes: wasoMinutes,
            resolvedSource: winner.source,
            analysisStatus: status,
            sourceFingerprint: fingerprint(of: winner.samples),
            lastHealthKitSyncAt: context.lastSyncAt,
            lastSampleEndDate: winner.samples.map(\.end).max(),
            revision: 0,
            factsSchemaVersion: factsSchemaVersion
        )
    }

    // MARK: - Multi-source precedence (§6)

    private struct SourceCandidate {
        let source: SleepSource
        let samples: [SleepSample]
        let asleepSeconds: TimeInterval
        let hasStages: Bool
        let isAppleWatch: Bool
        let bundleID: String
    }

    private struct ResolvedSource {
        let source: SleepSource
        let samples: [SleepSample]
        let hasStages: Bool
    }

    /// Deterministic precedence: user-preferred → Apple Watch staged → other staged source →
    /// generic asleep → manual. Exactly one source wins; its samples alone compose the night —
    /// stage intervals from unrelated devices are never merged.
    private static func resolveSource(_ samples: [SleepSample], preferredBundleID: String?) -> ResolvedSource? {
        let manual = samples.filter(\.isUserEntered)
        let deviceGroups = Dictionary(grouping: samples.filter { !$0.isUserEntered }, by: \.sourceBundleID)

        let candidates: [SourceCandidate] = deviceGroups.compactMap { bundleID, group in
            let asleep = unionDuration(group.filter { $0.kind.isAsleep }.map { (start: $0.start, end: $0.end) })
            guard asleep > 0 else { return nil }   // a source must have recorded sleep to win
            return SourceCandidate(
                source: .healthKit(bundleID: bundleID),
                samples: group,
                asleepSeconds: asleep,
                hasStages: group.contains { $0.kind.isStagedSleep },
                // WHY this breadth: tier 2 is "staged data from the athlete's watch". Device
                // model "Watch" is the reliable Apple Watch marker; the com.apple.health bundle
                // prefix additionally catches Apple-written samples that arrive without device
                // metadata (iPhone-only Apple sleep is unstaged today, so the prefix can't
                // false-positive into this *staged* tier). A third-party watch app writing
                // staged data also ranks tier 2 via the "Watch" model — deliberately: it is
                // watch staged data, and ranking it one tier above other staged sources is
                // harmless.
                isAppleWatch: group.contains { $0.deviceModel == "Watch" } || bundleID.hasPrefix("com.apple.health"),
                bundleID: bundleID
            )
        }

        // Most recorded sleep wins within a tier; lexicographic bundle ID breaks exact ties so
        // the same inputs always resolve to the same source.
        func best(_ pool: [SourceCandidate]) -> SourceCandidate? {
            pool.min {
                $0.asleepSeconds != $1.asleepSeconds
                    ? $0.asleepSeconds > $1.asleepSeconds
                    : $0.bundleID < $1.bundleID
            }
        }

        let winner = preferredBundleID.flatMap { preferred in candidates.first { $0.bundleID == preferred } }
            ?? best(candidates.filter { $0.hasStages && $0.isAppleWatch })
            ?? best(candidates.filter(\.hasStages))
            ?? best(candidates)
        if let winner {
            return ResolvedSource(source: winner.source, samples: winner.samples, hasStages: winner.hasStages)
        }

        let manualAsleep = unionDuration(manual.filter { $0.kind.isAsleep }.map { (start: $0.start, end: $0.end) })
        guard manualAsleep > 0 else { return nil }
        return ResolvedSource(source: .manual, samples: manual, hasStages: false)
    }

    // MARK: - Intervals & episodes

    /// Winner samples → stage intervals, merging overlapping/touching same-stage spans (HealthKit
    /// can hold duplicate or overlapping writes from one source). `inBed` produces no interval.
    private static func stageIntervals(from samples: [SleepSample], source: SleepSource) -> [SleepStageInterval] {
        var spansByStage: [SleepStage: [(start: Date, end: Date)]] = [:]
        for sample in samples {
            guard let stage = sample.kind.stage else { continue }
            spansByStage[stage, default: []].append((sample.start, sample.end))
        }
        return spansByStage
            .flatMap { stage, spans in
                mergedSpans(spans).map { SleepStageInterval(stage: stage, start: $0.start, end: $0.end, source: source) }
            }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
    }

    /// Contiguous-session segmentation: silence beyond `episodeGapThreshold` starts a new episode;
    /// shorter silences beyond `trackedGapThreshold` are recorded as tracking gaps.
    private static func segment(_ intervals: [SleepStageInterval]) -> [SleepEpisode] {
        guard let first = intervals.first else { return [] }
        var episodes: [SleepEpisode] = []
        var current: [SleepStageInterval] = [first]
        var currentEnd = first.end
        var gaps: [DateInterval] = []

        func close() {
            episodes.append(SleepEpisode(
                id: UUID(),
                start: current[0].start,
                end: currentEnd,
                intervals: current,
                isPrimary: false,
                gaps: gaps
            ))
        }

        for interval in intervals.dropFirst() {
            let silence = interval.start.timeIntervalSince(currentEnd)
            if silence > episodeGapThreshold {
                close()
                current = [interval]
                currentEnd = interval.end
                gaps = []
            } else {
                if silence > trackedGapThreshold {
                    gaps.append(DateInterval(start: currentEnd, end: interval.start))
                }
                current.append(interval)
                currentEnd = max(currentEnd, interval.end)
            }
        }
        close()
        return episodes
    }

    /// The episode with the most asleep time is the primary overnight sleep; episodes are ordered
    /// by start, so an exact tie goes to the earlier one — deterministic either way.
    private static func primaryEpisodeIndex(in episodes: [SleepEpisode]) -> Int? {
        var bestIndex: Int?
        var bestSeconds = 0.0
        for (index, episode) in episodes.enumerated() {
            let asleep = unionDuration(
                episode.intervals.filter { $0.stage.isAsleep }.map { (start: $0.start, end: $0.end) }
            )
            if asleep > bestSeconds {
                bestSeconds = asleep
                bestIndex = index
            }
        }
        return bestIndex
    }

    // MARK: - Span math

    /// Overlapping or touching spans collapsed into disjoint ones, sorted by start.
    private static func mergedSpans(_ spans: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        var merged: [(start: Date, end: Date)] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Total covered duration with overlaps counted once — so duplicate samples can never
    /// double-count asleep time.
    private static func unionDuration(_ spans: [(start: Date, end: Date)]) -> TimeInterval {
        mergedSpans(spans).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }
}
