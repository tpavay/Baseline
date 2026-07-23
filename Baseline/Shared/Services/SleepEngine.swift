import Foundation

/// The **pure** sleep scoring & comparison engine (plan §4). Canonical `SleepNight` facts + history
/// in, a derived `SleepAnalysis` out. No SwiftData, no HealthKit, no SwiftUI, no `Date()`, nothing
/// invented — the same inputs always yield the same analysis, so it is fully unit-testable without a
/// view tree or store (house rule, mirrors `DecisionEngine`/`ReadinessScore`).
///
/// Scoring is Apple-aligned: **duration 50 / bedtime consistency 30 / interruptions 20**. Stage
/// proportions never enter the score (round-2 correction, AC-3) — they are surfaced as
/// `additionalEvidence` only. Partial nights never renormalize: a component that cannot be observed
/// drops out of both `observedPoints` and `possiblePoints`, and `score` stays nil (AC-2).
enum SleepEngine {

    // MARK: - Versions (independent of the facts schema; see plan §7)

    /// How nights aggregate into windows/comparisons. Bump when window math changes.
    static let aggregationVersion = 1
    /// The scoring math. Bump when component curves/weights change.
    /// v2: components round individually before summing, so the visible component rows always sum
    /// to the headline score (v1 rounded the unrounded sum, letting the rows disagree by 1).
    static let scoreAlgorithmVersion = 2

    /// Default sleep need when Slice 4 has not wired `ReadinessConfig` yet.
    static let defaultNeed: Duration = .seconds(8 * 3600)

    // MARK: - Tunables (single source of truth)

    /// All thresholds and curve shapes live here so the scoring is auditable in one place and tests
    /// pin against named constants, not magic numbers.
    ///
    /// **Provenance (binding product language):** the component *weights* — duration 50 / bedtime
    /// consistency 30 / interruptions 20 — are **Apple-aligned** (Apple's published component
    /// weighting), never "Apple-equivalent." The *curves* are **Baseline internal heuristics**:
    /// Apple has not published the duration-taper shape (here: zero at 50 % of need) or the
    /// interruption split (WASO 12 / awakenings 8 with grace bands). All are v1 tunables carried
    /// under `scoreAlgorithmVersion`, so history can be recomputed if they are retuned.
    enum Tunables {
        // Duration (0–50): full at ≥ need, linear taper to zero at half the need. The floor is
        // proportional to the individual's goal (need/2) rather than a fixed clock value, keeping
        // the curve goal-relative — a 6 h night is a bigger deficit against a 9 h need than an 8 h
        // one. Below half-need, sleep earns no duration credit.
        static let durationMaxPoints = 50.0
        static let durationFloorFraction = 0.5

        // Bedtime consistency (0–30): full within a grace band around the rolling circular mean,
        // linear taper to zero at the outer bound. Unavailable below `consistencyMinNights` (AC-2).
        static let consistencyMaxPoints = 30.0
        static let consistencyMinNights = 5
        static let consistencyWindowDays = 14
        static let consistencyGraceMinutes = 30.0
        static let consistencyZeroMinutes = 210.0

        // Interruptions (0–20): split into a WASO term (12) and an awakening-count term (8). Each
        // is full within a grace band and tapers to zero at its outer bound. Unavailable when the
        // source carries no awake-stage evidence (manual/generic — AC-2).
        static let interruptionsMaxPoints = 20.0
        static let wasoMaxPoints = 12.0
        static let wasoGraceMinutes = 20.0
        static let wasoZeroMinutes = 90.0
        static let awakeningsMaxPoints = 8.0
        static let awakeningsGraceCount = 1.0
        static let awakeningsZeroCount = 6.0

        // Comparison windows (AC-5).
        static let acuteWindowDays = 7
        static let chronicWindowDays = 30
        static let debtWindowDays = 14

        // Flags (AC-6).
        static let flagMinNights = 14
        static let scheduleShiftThresholdMinutes = 90.0
        static let shortNightFloorHours = 6.0

        // Interruption burden normalization for the decision hand-off (AC-9): WASO minutes over
        // this reference reads as a fully-saturated burden of 1.0.
        static let interruptionBurdenReferenceMinutes = 60.0
    }

    private static let secondsPerDay = 86_400.0
    private static let minutesPerDay = 1_440.0

    // MARK: - Entry point

    static func analyze(night: SleepNight,
                        history: [SleepNight],
                        need: Duration = SleepEngine.defaultNeed) -> SleepAnalysis {
        let needHours = hours(from: need)

        // Prior recorded nights, strictly before this night, most-recent first. Count-and-day-gap
        // windowing (never impute) is done per metric below.
        let priors = history
            .filter { dayGap(from: $0.date, to: night.date) >= 1 }
            .sorted { dayGap(from: $0.date, to: night.date) < dayGap(from: $1.date, to: night.date) }

        let duration = durationComponent(night: night, needHours: needHours)
        let consistency = consistencyStatistics(night: night, priors: priors)
        let bedtimeComponent = bedtimeConsistencyComponent(night: night, consistency: consistency)
        let interruptions = interruptionsComponent(night: night)

        let components = [duration, bedtimeComponent, interruptions]
        // Round each component before summing (v2): every UI shows the components as rounded
        // integers, so the published total must be the sum of exactly those integers - rounding the
        // unrounded sum instead can disagree with the visible rows by 1 (e.g. 49.4 + 16.4 + 11.4).
        let observedPoints = components.filter(\.isAvailable)
            .map { Int($0.value.rounded()) }
            .reduce(0, +)
        let possiblePoints = Int(components.filter(\.isAvailable).map(\.max).reduce(0, +))
        let allObserved = components.allSatisfy(\.isAvailable)
        let score = allObserved ? observedPoints : nil

        let evidence = stageEvidence(night: night)
        let quality = evidenceQuality(night: night, consistency: consistency, gapMinutes: evidence.gapMinutes)
        let comparison = comparison(night: night, priors: priors, needHours: needHours)
        let flags = flags(night: night, priors: priors, consistency: consistency, needHours: needHours)
        let decisionEvidence = decisionEvidence(night: night, consistency: consistency, needHours: needHours)

        return SleepAnalysis(
            observedPoints: observedPoints,
            possiblePoints: possiblePoints,
            score: score,
            needHours: needHours,
            asleepHours: night.asleepHours,
            wasoMinutes: night.wasoMinutes,
            awakenings: night.awakenings,
            components: components,
            additionalEvidence: evidence,
            quality: quality,
            vsBaseline: comparison,
            consistency: consistency,
            flags: flags,
            decisionEvidence: decisionEvidence,
            aggregationVersion: aggregationVersion,
            scoreAlgorithmVersion: scoreAlgorithmVersion
        )
    }

    // MARK: - Duration (0–50)

    private static func durationComponent(night: SleepNight, needHours: Double) -> SleepComponent {
        // AC-2b: a manual (or unknown) source never enters a duration-scoring path — its duration is
        // persisted as evidence but earns zero scored points, so a manual night is score == nil /
        // observed 0 / possible 0. The single manual route stays the subjective thumbs→85/35
        // fallback `DecisionEngine` owns (Slice 4); a duration-only manual score would be a second
        // manual path and break the Slice 4 readiness-parity guarantee.
        guard isDeviceSourced(night), let asleep = night.asleepHours, asleep > 0, needHours > 0 else {
            return SleepComponent(kind: .duration, value: 0, max: Tunables.durationMaxPoints, isAvailable: false)
        }
        let floor = needHours * Tunables.durationFloorFraction
        let fraction = ((asleep - floor) / (needHours - floor)).clamped(to: 0...1)
        let value = Tunables.durationMaxPoints * fraction
        return SleepComponent(kind: .duration, value: value, max: Tunables.durationMaxPoints, isAvailable: true)
    }

    // MARK: - Bedtime consistency (0–30)

    private static func bedtimeConsistencyComponent(night: SleepNight,
                                                    consistency: SleepConsistency) -> SleepComponent {
        // A manual night carries a self-reported bedtime, not a device-observed one — the contract
        // makes manual nights duration-only (AC-2). Consistency is scored only for device sources.
        guard isDeviceSourced(night),
              consistency.isAvailable,
              let mean = consistency.bedtimeMeanSecondsOfDay,
              let bedtime = night.bedtime else {
            return SleepComponent(kind: .bedtimeConsistency, value: 0,
                                  max: Tunables.consistencyMaxPoints, isAvailable: false)
        }
        let deviation = deviationMinutes(secondsOfDay(bedtime, anchoredTo: night.date), mean)
        let value = taper(deviation,
                          grace: Tunables.consistencyGraceMinutes,
                          zero: Tunables.consistencyZeroMinutes,
                          max: Tunables.consistencyMaxPoints)
        return SleepComponent(kind: .bedtimeConsistency, value: value,
                              max: Tunables.consistencyMaxPoints, isAvailable: true)
    }

    // MARK: - Interruptions (0–20)

    private static func interruptionsComponent(night: SleepNight) -> SleepComponent {
        // Awakenings and WASO are set together by ingestion only for stage-capable sources; nil ⇒
        // the night carries no awake-stage evidence and interruptions cannot be observed (AC-2).
        guard let waso = night.wasoMinutes, let awakenings = night.awakenings else {
            return SleepComponent(kind: .interruptions, value: 0,
                                  max: Tunables.interruptionsMaxPoints, isAvailable: false)
        }
        let wasoPoints = taper(waso,
                               grace: Tunables.wasoGraceMinutes,
                               zero: Tunables.wasoZeroMinutes,
                               max: Tunables.wasoMaxPoints)
        let awakeningPoints = taper(Double(awakenings),
                                    grace: Tunables.awakeningsGraceCount,
                                    zero: Tunables.awakeningsZeroCount,
                                    max: Tunables.awakeningsMaxPoints)
        return SleepComponent(kind: .interruptions, value: wasoPoints + awakeningPoints,
                              max: Tunables.interruptionsMaxPoints, isAvailable: true)
    }

    // MARK: - Additional evidence (never scored)

    private static func stageEvidence(night: SleepNight) -> SleepStageEvidence {
        let primary = night.primaryEpisode
        let intervals = primary?.intervals ?? []
        func minutes(_ stage: SleepStage) -> Double {
            intervals.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration } / 60
        }
        let rem = minutes(.rem)
        let deep = minutes(.deep)
        let core = minutes(.core)
        let asleepMinutes = (night.asleepHours ?? 0) * 60
        func fraction(_ value: Double) -> Double { asleepMinutes > 0 ? value / asleepMinutes : 0 }
        let sleepOnset = intervals.filter { $0.stage.isAsleep }.map(\.start).min()
        let gapMinutes = (primary?.gaps ?? []).reduce(0) { $0 + $1.duration } / 60

        return SleepStageEvidence(
            remMinutes: rem,
            deepMinutes: deep,
            coreMinutes: core,
            remFraction: fraction(rem),
            deepFraction: fraction(deep),
            coreFraction: fraction(core),
            sleepOnset: sleepOnset,
            finalWake: primary?.end,
            gapMinutes: gapMinutes
        )
    }

    // MARK: - Evidence quality

    private static func evidenceQuality(night: SleepNight,
                                        consistency: SleepConsistency,
                                        gapMinutes: Double) -> SleepEvidenceQuality {
        var reasons: [SleepReason] = []

        // Coverage: fraction of the primary window actually tracked. A complete manual entry (one
        // block, no gaps) is high coverage; a night full of tracking gaps is low. Independent of
        // score-component availability (AC-4).
        let coverage: Double
        if let primary = night.primaryEpisode, (night.asleepHours ?? 0) > 0 {
            let windowMinutes = primary.end.timeIntervalSince(primary.start) / 60
            coverage = windowMinutes > 0 ? (1 - gapMinutes / windowMinutes).clamped(to: 0...1) : 1
            if gapMinutes > 0 { reasons.append(.trackingGap) }
        } else {
            coverage = 0
            reasons.append(.noDuration)
        }

        // Reliability: source class.
        let reliability: Double
        switch night.resolvedSource {
        case .manual:
            reliability = 0.3
            reasons.append(.manualEntry)
        case .none:
            reliability = 0.0
            reasons.append(.unknownSource)
        case .healthKit:
            if hasStageEvidence(night) {
                reliability = 1.0
            } else {
                reliability = 0.6
                reasons.append(.genericSource)
            }
        }

        if night.wasoMinutes == nil { reasons.append(.noStageEvidenceForInterruptions) }
        if !consistency.isAvailable { reasons.append(.insufficientHistoryForConsistency) }
        if night.analysisStatus == .provisional { reasons.append(.provisionalNight) }

        let status: SleepEvidenceQuality.Status
        switch night.analysisStatus {
        case .provisional: status = .provisional
        case .complete: status = .complete
        case .revised: status = .revised
        }

        return SleepEvidenceQuality(coverage: coverage, reliability: reliability,
                                    status: status, reasons: reasons)
    }

    /// True when the night's resolved source is a device (HealthKit), not a manual/absent source.
    private static func isDeviceSourced(_ night: SleepNight) -> Bool {
        if case .healthKit = night.resolvedSource { return true }
        return false
    }

    /// A staged source carries at least one specific (non-generic, non-awake) sleep stage.
    private static func hasStageEvidence(_ night: SleepNight) -> Bool {
        (night.primaryEpisode?.intervals ?? []).contains {
            $0.stage == .core || $0.stage == .deep || $0.stage == .rem
        }
    }

    // MARK: - Comparison (AC-5)

    private static func comparison(night: SleepNight,
                                   priors: [SleepNight],
                                   needHours: Double) -> SleepComparison {
        func mean(days: Int) -> Double? {
            let values = priors
                .filter { (1...days).contains(dayGap(from: $0.date, to: night.date)) }
                .compactMap(\.asleepHours)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        // Debt over the trailing window ending on (and including) this night. Only recorded nights
        // below need contribute; missing nights are never imputed as a fabricated deficit (AC-5).
        let debtNights = ([night] + priors)
            .filter { (0..<Tunables.debtWindowDays).contains(dayGap(from: $0.date, to: night.date)) }
        let debt = debtNights.compactMap(\.asleepHours)
            .reduce(0.0) { $0 + Swift.max(0, needHours - $1) }

        return SleepComparison(
            acute7Mean: mean(days: Tunables.acuteWindowDays),
            chronic30Mean: mean(days: Tunables.chronicWindowDays),
            debt14Hours: debt
        )
    }

    // MARK: - Consistency statistics

    private static func consistencyStatistics(night: SleepNight, priors: [SleepNight]) -> SleepConsistency {
        // Baseline is built from device-observed bedtimes only; a manual self-report shouldn't
        // define the rolling schedule (mirrors the component's device-source gate).
        let window = priors.filter {
            isDeviceSourced($0)
                && (1...Tunables.consistencyWindowDays).contains(dayGap(from: $0.date, to: night.date))
        }
        let bedtimes = window.compactMap { pair(for: $0, keyPath: \.bedtime) }
        let wakes = window.compactMap { pair(for: $0, keyPath: \.wakeTime) }
        let recorded = bedtimes.count
        let available = recorded >= Tunables.consistencyMinNights

        guard available else {
            return SleepConsistency(bedtimeMeanSecondsOfDay: nil, bedtimeStdMinutes: nil,
                                    wakeMeanSecondsOfDay: nil, wakeStdMinutes: nil,
                                    recordedNights: recorded, isAvailable: false)
        }
        let bedStats = circularStatistics(bedtimes)
        let wakeStats = circularStatistics(wakes)
        return SleepConsistency(
            bedtimeMeanSecondsOfDay: bedStats?.meanSecondsOfDay,
            bedtimeStdMinutes: bedStats?.stdMinutes,
            wakeMeanSecondsOfDay: wakeStats?.meanSecondsOfDay,
            wakeStdMinutes: wakeStats?.stdMinutes,
            recordedNights: recorded,
            isAvailable: true
        )
    }

    /// Seconds-of-day for a night's `keyPath` time, anchored to that night's own local-midnight
    /// `date`, so different-timezone nights still compare in local clock terms (no calendar needed).
    private static func pair(for night: SleepNight, keyPath: KeyPath<SleepNight, Date?>) -> Double? {
        guard let time = night[keyPath: keyPath] else { return nil }
        return secondsOfDay(time, anchoredTo: night.date)
    }

    // MARK: - Flags (AC-6)

    private static func flags(night: SleepNight,
                              priors: [SleepNight],
                              consistency: SleepConsistency,
                              needHours: Double) -> [SleepFlag] {
        var flags: [SleepFlag] = []

        // Comparative flags: suppressed below `flagMinNights` recorded nights; reported window
        // capped at the available history span. `bestIn`/`worstIn` fire only when this night is the
        // strict extreme across all available history (its window is the full recorded span).
        let recorded = priors.filter { $0.asleepHours != nil }
        if let asleep = night.asleepHours, recorded.count >= Tunables.flagMinNights {
            let priorAsleep = recorded.compactMap(\.asleepHours)
            let spanDays = recorded.map { dayGap(from: $0.date, to: night.date) }.max() ?? 0
            if let worst = priorAsleep.min(), asleep < worst {
                flags.append(.worstIn(days: spanDays))
            } else if let best = priorAsleep.max(), asleep > best {
                flags.append(.bestIn(days: spanDays))
            }
        }

        // Schedule shift: bedtime deviation beyond threshold. Needs the rolling mean (≥ 5 nights)
        // but is not gated by the 14-night comparative-flag suppression. Device sources only —
        // same reliability gate as the consistency component.
        if isDeviceSourced(night),
           consistency.isAvailable,
           let mean = consistency.bedtimeMeanSecondsOfDay,
           let bedtime = night.bedtime {
            let deviation = deviationMinutes(secondsOfDay(bedtime, anchoredTo: night.date), mean)
            if deviation > Tunables.scheduleShiftThresholdMinutes {
                flags.append(.scheduleShift(minutes: deviation))
            }
        }

        // Short night: absolute duration floor.
        if let asleep = night.asleepHours, asleep < Tunables.shortNightFloorHours {
            flags.append(.shortNight(hours: asleep))
        }

        return flags
    }

    // MARK: - Decision evidence (AC-9)

    private static func decisionEvidence(night: SleepNight,
                                         consistency: SleepConsistency,
                                         needHours: Double) -> SleepDecisionEvidence {
        // Duration deficit is a device-observed decision signal only. A manual night stays fully
        // nil here (AC-2b): Slice 4 must reach it through the subjective fallback, not a duration
        // deficit — otherwise the manual night feeds a second scoring route through `poorSleep`.
        let deficit = isDeviceSourced(night) ? night.asleepHours.map { Swift.max(0, needHours - $0) } : nil
        // Device-gated like the other two signals so AC-2b ("manual feeds no decision signal") holds
        // locally rather than depending on Slice 1's "WASO only on staged sources" invariant — a
        // future ingestion change attaching WASO to a non-staged source can't leak a burden here.
        let burden = isDeviceSourced(night)
            ? night.wasoMinutes.map { ($0 / Tunables.interruptionBurdenReferenceMinutes).clamped(to: 0...1) }
            : nil
        let shift: Double?
        if isDeviceSourced(night),
           consistency.isAvailable,
           let mean = consistency.bedtimeMeanSecondsOfDay,
           let bedtime = night.bedtime {
            shift = deviationMinutes(secondsOfDay(bedtime, anchoredTo: night.date), mean)
        } else {
            shift = nil
        }
        return SleepDecisionEvidence(durationDeficitHours: deficit,
                                     interruptionBurden: burden,
                                     scheduleShiftMinutes: shift)
    }

    // MARK: - Math helpers

    /// Points that stay at `max` up to `grace`, then taper linearly to 0 at `zero`.
    private static func taper(_ value: Double, grace: Double, zero: Double, max: Double) -> Double {
        guard zero > grace else { return value <= grace ? max : 0 }
        let over = Swift.max(0, value - grace)
        let fraction = (1 - over / (zero - grace)).clamped(to: 0...1)
        return max * fraction
    }

    /// Integer calendar-day gap between two local-midnight instants, DST-robust: startOfDay
    /// instants differ by an integer number of days ± the DST hour, so rounding the /86400 ratio
    /// recovers the exact day count (a 6 d 23 h gap rounds to 7) without a calendar.
    private static func dayGap(from earlier: Date, to later: Date) -> Int {
        Int((later.timeIntervalSince(earlier) / secondsPerDay).rounded())
    }

    /// Seconds since the night's own local midnight (`date`), wrapped into 0…86400 so an evening
    /// bedtime the day before wake reads as its clock time (23:00 → 82800) rather than a negative.
    ///
    /// WHY the fixed 86400: this is timezone/DST-naive on purpose. On the two DST-transition nights
    /// per year an instant recorded *after* the transition can drift by up to ±60 min versus a true
    /// Calendar wall-clock read. In practice bedtimes (pre-02:00) fall before the transition instant
    /// and read clean; the drift only bites late-morning wake times on those two nights. The bounded
    /// error is acceptable for Slice 3 because consistency mean/std are internal (not user-visible
    /// until Slice 5). NOTE: this is *separate* from the circular-distance correctness the score
    /// depends on — 11:50 PM vs 12:10 AM is 20 min apart via `deviationMinutes`'s circular min,
    /// regardless of this anchor. A Calendar-based seconds-of-day is a possible Slice 5 refinement.
    private static func secondsOfDay(_ instant: Date, anchoredTo anchor: Date) -> Double {
        let raw = instant.timeIntervalSince(anchor).truncatingRemainder(dividingBy: secondsPerDay)
        return (raw + secondsPerDay).truncatingRemainder(dividingBy: secondsPerDay)
    }

    /// Smallest circular distance between two seconds-of-day values, in minutes (handles the
    /// midnight wrap — 23:50 and 00:10 are 20 minutes apart, not 1420).
    private static func deviationMinutes(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: secondsPerDay)
        let circular = Swift.min(diff, secondsPerDay - diff)
        return circular / 60
    }

    private struct CircularStats { var meanSecondsOfDay: Double; var stdMinutes: Double }

    /// Circular mean + circular standard deviation of a set of seconds-of-day values. A naive
    /// arithmetic mean of clock times is wrong across midnight (23:30 & 00:30 → noon); the mean of
    /// unit vectors is not (→ midnight). Std from the resultant length R: σ = √(−2 ln R).
    private static func circularStatistics(_ secondsOfDay: [Double]) -> CircularStats? {
        guard !secondsOfDay.isEmpty else { return nil }
        let angles = secondsOfDay.map { $0 * 2 * .pi / secondsPerDay }
        let meanSin = angles.map(sin).reduce(0, +) / Double(angles.count)
        let meanCos = angles.map(cos).reduce(0, +) / Double(angles.count)
        let meanAngle = atan2(meanSin, meanCos)
        let normalizedAngle = (meanAngle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let mean = normalizedAngle / (2 * .pi) * secondsPerDay

        let resultant = (meanSin * meanSin + meanCos * meanCos).squareRoot()
        let stdRadians = resultant > 0 ? (-2 * Foundation.log(resultant)).squareRoot() : .pi
        let stdMinutes = stdRadians / (2 * .pi) * minutesPerDay
        return CircularStats(meanSecondsOfDay: mean, stdMinutes: stdMinutes)
    }

    private static func hours(from duration: Duration) -> Double {
        let comps = duration.components
        return (Double(comps.seconds) + Double(comps.attoseconds) / 1e18) / 3600
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
