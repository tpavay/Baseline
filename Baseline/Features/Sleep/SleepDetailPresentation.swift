import Foundation

/// Shared, pure formatting for sleep durations/clock times so the chart, the presentation model, and
/// tests all print identical quantities (mirrors `SleepInsights`' private formatter, hoisted for reuse).
enum SleepFormat {
    /// Minutes → "38 min" / "1 h 12 m" / "2 h", rounded to the nearest minute.
    static func minutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60
        let m = total % 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return "\(h) h" }
        return "\(h) h \(m) m"
    }

    /// Hours → the same "h/m" shape via `minutes`.
    static func hours(_ hours: Double) -> String { minutes(hours * 60) }

    /// A 0…1 fraction → whole-percent string ("62%").
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}

/// Pure analysis → display mapping for `SleepDetailView` (plan §9, AC-2/3/4). Business/formatting
/// logic lives here, not in `body`: the view reads these already-formatted sections. Deterministic and
/// view-tree-free, so `SleepDetailPresentationTests` pins every string without rendering.
struct SleepDetailPresentation: Equatable {

    /// The headline is a real 0–100 score only when every component was observed; otherwise the honest
    /// observed/possible points + coverage, never a fabricated number (AC-3).
    enum Headline: Equatable {
        case score(Int)
        case partial(observed: Int, possible: Int, coveragePercent: Int)
    }

    struct Badge: Equatable {
        var status: String        // "Provisional" / "Revised" / "Complete"
        var reliability: String   // "High reliability" / "Low reliability (manual)" …
        var isProvisional: Bool
    }

    struct ComponentRow: Equatable, Identifiable {
        var kind: SleepComponent.Kind
        var title: String
        var value: String         // "42 / 50" or "Not observed"
        var fraction: Double      // value/max, 0 when unavailable
        var isAvailable: Bool
        var id: SleepComponent.Kind { kind }
    }

    struct Stat: Equatable, Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    struct StageEvidenceRow: Equatable, Identifiable {
        var label: String
        var duration: String
        var share: String         // "27% of sleep"
        var fraction: Double
        var id: String { label }
    }

    /// Footer strings tying sleep to today's decision (AC-4). `influence` is the *weighted* share of
    /// the blend — never phrased as a cause; `cap` is the separate causal statement when a sleep cap
    /// actually bound the result.
    struct Footer: Equatable {
        var influence: String?
        var cap: String?
        var note: String?
    }

    var headline: Headline
    var badge: Badge
    var stats: [Stat]
    var components: [ComponentRow]
    var stageEvidence: [StageEvidenceRow]
    var stageEvidenceCaption: String
    var comparisons: [Stat]
    var flags: [String]
    var insights: [String]
    var provenance: [Stat]
    var footer: Footer

    // MARK: - Build

    /// - Parameters:
    ///   - analysis: the derived night analysis (the single source of the scored numbers).
    ///   - decision: today's decision result, when this night fed it — drives the influence/cap footer.
    ///   - resolvedSource: the canonical night's resolved source, for provenance.
    ///   - lastSyncAt: last Health sync instant, for provenance.
    init(analysis: SleepAnalysis,
         decision: DecisionEngine.Result? = nil,
         resolvedSource: SleepSource = .none,
         lastSyncAt: Date? = nil) {
        self.headline = Self.headline(analysis)
        self.badge = Self.badge(analysis, resolvedSource: resolvedSource)
        self.stats = Self.stats(analysis)
        self.components = Self.components(analysis)
        self.stageEvidence = Self.stageEvidence(analysis.additionalEvidence)
        self.stageEvidenceCaption = "Stage estimates are evidence only — they never move the score."
        self.comparisons = Self.comparisons(analysis)
        self.flags = Self.flags(analysis.flags)
        self.insights = SleepInsights.rules(for: analysis)
        self.provenance = Self.provenance(analysis, resolvedSource: resolvedSource, lastSyncAt: lastSyncAt)
        self.footer = Self.footer(analysis, decision: decision)
    }

    // MARK: - Sections

    private static func headline(_ a: SleepAnalysis) -> Headline {
        if let score = a.score { return .score(score) }
        return .partial(observed: a.observedPoints, possible: a.possiblePoints,
                        coveragePercent: Int((a.quality.coverage * 100).rounded()))
    }

    private static func badge(_ a: SleepAnalysis, resolvedSource: SleepSource) -> Badge {
        let status: String
        switch a.quality.status {
        case .provisional: status = "Provisional"
        case .complete: status = "Complete"
        case .revised: status = "Revised"
        }
        return Badge(status: status,
                     reliability: reliabilityLabel(a.quality.reliability, resolvedSource: resolvedSource),
                     isProvisional: a.quality.status == .provisional)
    }

    /// Reliability is a source-class trust band, not a score. Manual self-reports are explicitly
    /// low-reliability (AC-3) even when their coverage is high.
    private static func reliabilityLabel(_ reliability: Double, resolvedSource: SleepSource) -> String {
        if case .manual = resolvedSource { return "Low reliability (manual entry)" }
        if case .none = resolvedSource { return "Source unknown" }
        if reliability >= 0.9 { return "High reliability (staged wearable)" }
        if reliability >= 0.5 { return "Medium reliability (phone estimate)" }
        return "Low reliability"
    }

    private static func stats(_ a: SleepAnalysis) -> [Stat] {
        var rows: [Stat] = []
        rows.append(Stat(label: "Time asleep", value: a.asleepHours.map(SleepFormat.hours) ?? "Not observed"))
        if let waso = a.wasoMinutes {
            let awakenings = a.awakenings.map { " · \($0) awakening\($0 == 1 ? "" : "s")" } ?? ""
            rows.append(Stat(label: "Awake in bed", value: SleepFormat.minutes(waso) + awakenings))
        }
        let gap = a.additionalEvidence.gapMinutes
        if gap >= 1 { rows.append(Stat(label: "Tracking gap", value: SleepFormat.minutes(gap))) }
        return rows
    }

    private static func components(_ a: SleepAnalysis) -> [ComponentRow] {
        let titles: [SleepComponent.Kind: String] = [
            .duration: "Duration", .bedtimeConsistency: "Consistency", .interruptions: "Interruptions"
        ]
        let order: [SleepComponent.Kind] = [.duration, .bedtimeConsistency, .interruptions]
        return order.map { kind in
            let c = a.component(kind)
            let available = c?.isAvailable ?? false
            let value = available
                ? "\(Int((c?.value ?? 0).rounded())) / \(Int(c?.max ?? 0))"
                : "Not observed"
            let fraction = (available && (c?.max ?? 0) > 0) ? (c!.value / c!.max) : 0
            return ComponentRow(kind: kind, title: titles[kind] ?? "", value: value,
                                fraction: fraction, isAvailable: available)
        }
    }

    private static func stageEvidence(_ e: SleepStageEvidence) -> [StageEvidenceRow] {
        [("REM", e.remMinutes, e.remFraction),
         ("Deep", e.deepMinutes, e.deepFraction),
         ("Core", e.coreMinutes, e.coreFraction)].map { label, minutes, fraction in
            StageEvidenceRow(label: label,
                             duration: SleepFormat.minutes(minutes),
                             share: "\(Int((fraction * 100).rounded()))% of sleep",
                             fraction: fraction)
        }
    }

    private static func comparisons(_ a: SleepAnalysis) -> [Stat] {
        var rows: [Stat] = []
        if let acute = a.vsBaseline.acute7Mean {
            rows.append(Stat(label: "7-day average", value: SleepFormat.hours(acute)))
        }
        if let chronic = a.vsBaseline.chronic30Mean {
            rows.append(Stat(label: "30-day average", value: SleepFormat.hours(chronic)))
        }
        if a.vsBaseline.debt14Hours >= 0.1 {
            rows.append(Stat(label: "14-day sleep debt", value: SleepFormat.hours(a.vsBaseline.debt14Hours)))
        }
        return rows
    }

    private static func flags(_ flags: [SleepFlag]) -> [String] {
        flags.map { flag in
            switch flag {
            case .bestIn(let days): "Longest night in \(days) days"
            case .worstIn(let days): "Shortest night in \(days) days"
            case .scheduleShift(let minutes): "Bedtime shifted \(SleepFormat.minutes(minutes))"
            case .shortNight(let hours): "Short night — \(SleepFormat.hours(hours))"
            }
        }
    }

    private static func provenance(_ a: SleepAnalysis, resolvedSource: SleepSource, lastSyncAt: Date?) -> [Stat] {
        var rows: [Stat] = []
        rows.append(Stat(label: "Source", value: sourceLabel(resolvedSource)))
        rows.append(Stat(label: "Coverage", value: SleepFormat.percent(a.quality.coverage)))
        if let lastSyncAt {
            rows.append(Stat(label: "Last sync",
                             value: lastSyncAt.formatted(.relative(presentation: .named))))
        }
        return rows
    }

    private static func sourceLabel(_ source: SleepSource) -> String {
        switch source {
        case .healthKit: "Apple Health"
        case .manual: "Manual entry"
        case .none: "Unknown"
        }
    }

    // MARK: - Influence / cap footer (AC-4)

    private static func footer(_ a: SleepAnalysis, decision: DecisionEngine.Result?) -> Footer {
        guard let decision else {
            return Footer(influence: nil, cap: nil,
                          note: "This night isn't part of today's readiness decision.")
        }
        var influence: String?
        if let sleep = decision.domains.first(where: { $0.domain == .sleep }) {
            // Display-layer share of the weighted blend — descriptive, never causal (plan §8). A cap,
            // when it fires, is stated separately below as the actual limiter.
            let possible = Int((sleep.weight * 100).rounded())
            let weighted = Int((sleep.weight * Double(sleep.subscore)).rounded())
            influence = "Sleep domain: \(sleep.subscore) — weighted influence \(weighted) of \(possible) possible points"
        }

        var cap: String?
        let sleepCaps = decision.appliedCaps.filter { $0.domain == .sleep }
        if let sleepCap = sleepCaps.map(\.cap).min() {
            let binding = decision.appliedCaps.map(\.cap).min()
            cap = sleepCap == binding
                ? "Today's readiness was capped by short sleep."
                : "Short sleep would cap readiness, but another factor bound today lower."
        }
        return Footer(influence: influence, cap: cap, note: influence == nil && cap == nil
                      ? "Sleep didn't limit today's readiness."
                      : nil)
    }
}
