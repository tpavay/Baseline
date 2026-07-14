import Foundation

/// The Sleep Engine → Decision Engine integration seam (plan §8, Slice 4). Headless until go-live:
/// nothing here runs in the app unless a `SleepEvidenceProvider` is deliberately injected into the
/// decision assembly (`TodayEvidence.baseInputs` / `MorningReadinessScoreView`). With no provider the
/// app's sleep path is byte-identical to pre-slice (AC-5). The go-live switch is documented in
/// `docs/implementation/sleep-engine-go-live.md`.

// MARK: - Mapped engine inputs

/// The engine-sourced sleep contribution to a readiness decision. Produced by a
/// `SleepEvidenceProvider` from a canonical `SleepAnalysis`; consumed by `SleepDecisionSeam`. The
/// `snapshot` is the exact analysis used, frozen onto `ReadinessEntry` at decision time (AC-7).
struct SleepDecisionInputs: Sendable {
    var sleepScore: Double?
    var sleepHours: Double?
    var sleepConfidence: Double?
    var sleepDurationDeficit: Double?
    var sleepInterruptionBurden: Double?
    var sleepScheduleShift: Double?
    var snapshot: SleepAnalysis
}

extension SleepDecisionInputs {
    /// Map a derived `SleepAnalysis` → decision inputs (AC-4). `sleepScore` is published only when the
    /// analysis published one (all components observed — the no-renormalization rule); a manual or
    /// partial night yields `sleepScore == nil`, and the seam then uses the subjective fallback.
    init(analysis: SleepAnalysis) {
        let quality = analysis.quality
        // Certainty-eligible confidence: the resolved reliability when the coverage∧reliability bar
        // (coverage ≥ 0.7 ∧ reliability ≥ 0.5) is cleared, else 0. The decision engine gates sleep's
        // certainty contribution on this ≥ its threshold (AC-3). In practice a *published* score
        // comes only from a staged source (reliability 1.0, since interruptions need stage evidence),
        // so this reduces to the coverage ≥ 0.7 gate — but both dimensions are honored here so a
        // future scoring change can't silently let a low-reliability night raise certainty. A richer
        // graded-confidence surface is Slice 5.
        let clearsBar = quality.coverage >= 0.7 && quality.reliability >= 0.5
        let confidence = clearsBar ? quality.reliability : 0.0
        self.init(
            sleepScore: analysis.score.map(Double.init),
            sleepHours: analysis.asleepHours,
            sleepConfidence: confidence,
            sleepDurationDeficit: analysis.decisionEvidence.durationDeficitHours,
            sleepInterruptionBurden: analysis.decisionEvidence.interruptionBurden,
            sleepScheduleShift: analysis.decisionEvidence.scheduleShiftMinutes,
            snapshot: analysis
        )
    }
}

// MARK: - Provider

/// The injectable seam. Optionally supplied to the decision assembly; when absent the app's sleep
/// path is byte-identical to pre-slice (AC-5). Constructing and injecting one of these is the entire
/// go-live switch.
@MainActor
protocol SleepEvidenceProvider {
    /// The engine sleep inputs for the recovery day containing `date`, or nil when no canonical night
    /// exists (→ the caller keeps the legacy/manual path).
    func sleepInputs(on date: Date) -> SleepDecisionInputs?
}

/// Production provider: reads the canonical night + history from a `SleepRepository`, runs the pure
/// `SleepEngine` threading `need` from `ReadinessConfig` (default 8 h, AC-4), and maps the result.
///
/// Re-deriving here (rather than reading the repository's cached `analysis(for:)`) is deliberate:
/// `need` is user-set and must override the repository's default-need derivation, without mutating
/// its persisted cache. The night + history still come from the repository, so this remains a pure
/// projection of stored facts.
@MainActor
struct RepositorySleepEvidenceProvider: SleepEvidenceProvider {
    let repository: SleepRepository
    let need: Duration
    /// History depth fed to the engine — the full backfill span so comparison windows and notable-
    /// night flags are never silently capped (mirrors `SleepAnalysisDerivation.engine`).
    let historyWindowDays: Int

    init(repository: SleepRepository, need: Duration = SleepEngine.defaultNeed, historyWindowDays: Int = 90) {
        self.repository = repository
        self.need = need
        self.historyWindowDays = historyWindowDays
    }

    /// Convenience: thread `need` straight from a `ReadinessConfig` (default 8 h when unset).
    init(repository: SleepRepository, config: ReadinessConfig, historyWindowDays: Int = 90) {
        self.init(repository: repository, need: config.sleepNeed, historyWindowDays: historyWindowDays)
    }

    func sleepInputs(on date: Date) -> SleepDecisionInputs? {
        guard let night = repository.night(for: date) else { return nil }
        let history = repository.nights(lastDays: historyWindowDays, endingOn: date)
        let analysis = SleepEngine.analyze(night: night, history: history, need: need)
        return SleepDecisionInputs(analysis: analysis)
    }
}

// MARK: - The seam (pure, shared, testable)

/// The single expression of the sleep seam — pure and synchronous so both call sites
/// (`TodayEvidence.baseInputs`, `MorningReadinessScoreView.compute`) share it and the parity tests
/// (AC-5) can pin it without a view tree or async. Seam off → byte-identical to the pre-slice ladder.
enum SleepDecisionSeam {
    /// Legacy HealthKit summary shape (`HealthService.lastNightSleep`), adapted so the resolver stays
    /// pure. Seam-off only.
    struct HealthSleep: Equatable, Sendable { var hours: Double; var efficiency: Double? }
    /// The manual check-in fallback (typed hours or a thumb). Empty for `TodayEvidence`.
    struct ManualSleep: Equatable, Sendable {
        var hours: Double?
        var thumbsUp: Bool?
        static let none = ManualSleep(hours: nil, thumbsUp: nil)
    }

    /// Where sleep comes from this run.
    enum Source {
        case legacy(HealthSleep?)          // seam off: HealthKit summary, or nil when Health has none
        case engine(SleepDecisionInputs?)  // seam on: engine night, or nil when no canonical night
    }

    struct Result: Equatable, Sendable {
        var sleepScore: Double? = nil
        var sleepHours: Double? = nil
        var sleepConfidence: Double? = nil
        var sleepDurationDeficit: Double? = nil
        var sleepInterruptionBurden: Double? = nil
        var sleepScheduleShift: Double? = nil
        var snapshot: SleepAnalysis? = nil
    }

    static func resolve(_ source: Source, manual: ManualSleep) -> Result {
        switch source {
        case .legacy(let health):
            guard let health else { return manualFallback(manual) }
            // Byte-identical to the pre-slice automatic Health path.
            return Result(sleepScore: ReadinessScore.sleepScore(hours: health.hours, efficiency: health.efficiency),
                          sleepHours: health.hours)
        case .engine(let engine):
            guard let engine else { return manualFallback(manual) }
            // Score published (all components observed) → full structured inputs + snapshot.
            if engine.sleepScore != nil {
                return Result(sleepScore: engine.sleepScore,
                              sleepHours: engine.sleepHours,
                              sleepConfidence: engine.sleepConfidence,
                              sleepDurationDeficit: engine.sleepDurationDeficit,
                              sleepInterruptionBurden: engine.sleepInterruptionBurden,
                              sleepScheduleShift: engine.sleepScheduleShift,
                              snapshot: engine.snapshot)
            }
            // Score NOT published, but a *device* night with an observed duration still contributes
            // its duration/deficit so the `poorSleep` training-SAFETY cap can fire — a genuinely
            // short cold-start (< 5 nights → no consistency) or low-coverage device night must not
            // silently escape the cap the pre-slice `health.lastNightSleep()` path applied. The
            // discriminator is source + duration-observed, NOT score presence: `durationDeficitHours`
            // is non-nil only for a device-sourced night with asleep hours (`SleepEngine` gates it),
            // so it is exactly that signal. `sleepScore` stays nil (no renormalized score) and
            // `sleepConfidence` stays nil (no certainty credit without a published score); no snapshot
            // is frozen (nothing was decided from a published score). A manual/`.none` night has a nil
            // deficit and so falls through to the single subjective fallback below (AC-4 / AC-2b intact).
            if engine.sleepDurationDeficit != nil {
                return Result(sleepScore: nil,
                              sleepHours: engine.sleepHours,
                              sleepConfidence: nil,
                              sleepDurationDeficit: engine.sleepDurationDeficit,
                              sleepInterruptionBurden: engine.sleepInterruptionBurden,
                              sleepScheduleShift: engine.sleepScheduleShift,
                              snapshot: nil)
            }
            return manualFallback(manual)
        }
    }

    /// The pre-slice manual fallback: typed hours (scored like Health duration-only), else a thumb
    /// (85/35), else nothing. Identical values/ordering to the legacy `else if` ladder. This is the
    /// single manual path a manual/partial engine night resolves to (AC-4).
    private static func manualFallback(_ manual: ManualSleep) -> Result {
        if let hours = manual.hours {
            return Result(sleepScore: ReadinessScore.sleepScore(hours: hours), sleepHours: hours)
        }
        if let up = manual.thumbsUp {
            return Result(sleepScore: up ? 85 : 35)
        }
        return Result()
    }
}

extension DecisionEngine.Inputs {
    /// Fold a resolved sleep contribution into the inputs. In the seam-off legacy path the four new
    /// structured fields are nil, so this sets exactly what the pre-slice code set (AC-5).
    mutating func applySleep(_ r: SleepDecisionSeam.Result) {
        sleepScore = r.sleepScore
        sleepHours = r.sleepHours
        sleepConfidence = r.sleepConfidence
        sleepDurationDeficit = r.sleepDurationDeficit
        sleepInterruptionBurden = r.sleepInterruptionBurden
        sleepScheduleShift = r.sleepScheduleShift
    }
}

// MARK: - Decision snapshot

/// The sleep evidence a morning decision committed to — frozen onto `ReadinessEntry` (AC-7). Built
/// only when the seam published a score; the manual/legacy path produces none.
struct ReadinessSleepSnapshot: Sendable {
    var score: Int
    var confidence: Double?
    var analysis: SleepAnalysis
}

extension SleepDecisionSeam.Result {
    /// The persistable snapshot when this run committed an engine score; nil for the manual/legacy path.
    var readinessSnapshot: ReadinessSleepSnapshot? {
        guard let snapshot, let score = sleepScore else { return nil }
        return ReadinessSleepSnapshot(score: Int(score.rounded()), confidence: sleepConfidence, analysis: snapshot)
    }
}
