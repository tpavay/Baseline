import Foundation

/// Shared, pure formatting for sleep durations/clock times so the chart, the presentation model, and
/// tests all print identical quantities (mirrors `SleepInsights`' private formatter, hoisted for reuse).
/// The compact "8h 32m" shape is the approved redesign's duration style, used consistently on the
/// Today card, the detail screen, and the hypnogram legend.
enum SleepFormat {
    /// Minutes → "38m" / "1h 12m" / "2h", rounded to the nearest minute.
    static func minutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60
        let m = total % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
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
        /// Nothing was scorable (manual entry, or a source that can't be scored) - lead with the raw
        /// evidence (duration), never a "0 of 0" numeral that reads as a zero score (AC-3).
        case notScored(duration: String?, caption: String)
    }

    struct ComponentRow: Equatable, Identifiable {
        var kind: SleepComponent.Kind
        var title: String
        var value: String         // "50 / 50" or "Not observed"
        /// The Apple-style human reading of the component ("8h 32m - at your sleep goal",
        /// "1h 54m off your 14-day average", "10 wake-ups · 24m awake"). Empty when unavailable.
        var subtitle: String
        var fraction: Double      // value/max, 0 when unavailable
        var isAvailable: Bool
        var id: SleepComponent.Kind { kind }
    }

    struct Stat: Equatable, Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    /// Footer strings tying sleep to today's decision (AC-4). `influence` is the *weighted* share of
    /// the blend - never phrased as a cause; `cap` is the separate causal statement when a sleep cap
    /// actually bound the result.
    struct Footer: Equatable {
        var influence: String?
        var cap: String?
        var note: String?
    }

    var headline: Headline
    /// The Apple-post-26.2 score band word ("OK", "High", …); nil when no score was published.
    var bandLabel: String?
    /// "Today, Jul 23" / "Tue, Jul 21" under the band; empty when the night date is unknown.
    var dateLabel: String
    var components: [ComponentRow]
    var stageEvidenceCaption: String
    var comparisons: [Stat]
    var flags: [String]
    var insights: [String]
    var provenance: [Stat]
    var footer: Footer

    // MARK: - Build

    /// - Parameters:
    ///   - analysis: the derived night analysis (the single source of the scored numbers).
    ///   - decision: today's decision result, when this night fed it - drives the influence/cap footer.
    ///   - resolvedSource: the canonical night's resolved source, for provenance.
    ///   - lastSyncAt: last Health sync instant, for provenance.
    ///   - nightDate: the night's wake day, for the headline date label.
    ///   - referenceDate: "now", for the Today-vs-weekday phrasing (injected so tests stay pure).
    init(analysis: SleepAnalysis,
         decision: DecisionEngine.Result? = nil,
         resolvedSource: SleepSource = .none,
         lastSyncAt: Date? = nil,
         nightDate: Date? = nil,
         referenceDate: Date = .now,
         calendar: Calendar = .current) {
        self.headline = Self.headline(analysis, resolvedSource: resolvedSource)
        self.bandLabel = analysis.score.map { SleepScoreBand(score: $0).label }
        self.dateLabel = Self.dateLabel(nightDate, referenceDate: referenceDate, calendar: calendar)
        self.components = Self.components(analysis)
        self.stageEvidenceCaption = "Stages are evidence only - they never move the score."
        self.comparisons = Self.comparisons(analysis)
        self.flags = Self.flags(analysis.flags)
        self.insights = SleepInsights.rules(for: analysis)
        self.provenance = Self.provenance(analysis, resolvedSource: resolvedSource, lastSyncAt: lastSyncAt)
        self.footer = Self.footer(analysis, decision: decision)
    }

    // MARK: - Sections

    private static func headline(_ a: SleepAnalysis, resolvedSource: SleepSource) -> Headline {
        if let score = a.score { return .score(score) }
        // Nothing scorable (manual, or a source with no scorable component): a "0 of 0 pts" numeral
        // would read as a zero score, so lead with the raw evidence instead (AC-3).
        if a.possiblePoints == 0 {
            let caption: String
            if case .manual = resolvedSource { caption = "Manual entry · not scored" }
            else { caption = "Not scored" }
            return .notScored(duration: a.asleepHours.map(SleepFormat.hours), caption: caption)
        }
        return .partial(observed: a.observedPoints, possible: a.possiblePoints,
                        coveragePercent: Int((a.quality.coverage * 100).rounded()))
    }

    private static func dateLabel(_ nightDate: Date?, referenceDate: Date, calendar: Calendar) -> String {
        guard let nightDate else { return "" }
        // Anchor formatting to the injected calendar's timezone so the label matches the same-day
        // check (and stays deterministic under test).
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        let monthDay = nightDate.formatted(style.month(.abbreviated).day())
        if calendar.isDate(nightDate, inSameDayAs: referenceDate) {
            return "Today, \(monthDay)"
        }
        let weekday = nightDate.formatted(style.weekday(.abbreviated))
        return "\(weekday), \(monthDay)"
    }

    private static func components(_ a: SleepAnalysis) -> [ComponentRow] {
        let titles: [SleepComponent.Kind: String] = [
            .duration: "Duration", .bedtimeConsistency: "Bedtime", .interruptions: "Interruptions"
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
                                subtitle: available ? subtitle(kind, a) : "",
                                fraction: fraction, isAvailable: available)
        }
    }

    /// The human reading under each component row. Every quantity is recomputed from analysis
    /// fields the engine scored from, so the copy can never drift from the numbers (mirrors
    /// `SleepInsights`' honesty rule).
    private static func subtitle(_ kind: SleepComponent.Kind, _ a: SleepAnalysis) -> String {
        switch kind {
        case .duration:
            guard let asleep = a.asleepHours else { return "" }
            let slept = SleepFormat.hours(asleep)
            guard let need = a.needHours else { return "\(slept) asleep" }
            if asleep >= need { return "\(slept) - at your sleep goal" }
            return "\(slept) - \(SleepFormat.hours(need - asleep)) short of your sleep goal"
        case .bedtimeConsistency:
            guard let shift = a.decisionEvidence.scheduleShiftMinutes else { return "" }
            let window = SleepEngine.Tunables.consistencyWindowDays
            if shift <= SleepEngine.Tunables.consistencyGraceMinutes {
                return "Close to your \(window)-day average"
            }
            return "\(SleepFormat.minutes(shift)) off your \(window)-day average"
        case .interruptions:
            var parts: [String] = []
            if let awakenings = a.awakenings {
                parts.append(awakenings == 1 ? "1 wake-up" : "\(awakenings) wake-ups")
            }
            if let waso = a.wasoMinutes {
                parts.append("\(SleepFormat.minutes(waso)) awake")
            }
            return parts.joined(separator: " · ")
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
            case .shortNight(let hours): "Short night - \(SleepFormat.hours(hours))"
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
            // Display-layer share of the weighted blend - descriptive, never causal (plan §8). A cap,
            // when it fires, is stated separately below as the actual limiter.
            let possible = Int((sleep.weight * 100).rounded())
            let weighted = Int((sleep.weight * Double(sleep.subscore)).rounded())
            influence = "Sleep domain: \(sleep.subscore) - weighted influence \(weighted) of \(possible) possible points"
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
