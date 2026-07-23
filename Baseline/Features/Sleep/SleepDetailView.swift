import SwiftUI

/// The sleep evidence screen pushed from Today's sleep card (approved redesign, screen 2). Explains
/// the night behind the readiness decision: score + band headline → Apple-style score breakdown
/// (with the inline ⓘ opening the About screen) → staged hypnogram → vs-you comparisons + flags →
/// descriptive insights → provenance → influence/cap footer.
///
/// All formatting/mapping is in `SleepDetailPresentation` (pure, tested); `body` only lays out
/// already resolved sections. The hypnogram needs the raw stage intervals, which live on the
/// `SleepNight`, so the view takes the night (facts) plus its `analysis` (derived) - the repository
/// holds both.
struct SleepDetailView: View {
    let night: SleepNight
    let analysis: SleepAnalysis
    var decision: DecisionEngine.Result?

    /// Built once when the view value is created, not on every property read - the mapping runs
    /// `SleepInsights.rules` + all formatting, so rebuilding it ~10× per body pass would be wasteful
    /// (house rule: expensive derived state outside `body`).
    private let model: SleepDetailPresentation

    init(night: SleepNight, analysis: SleepAnalysis, decision: DecisionEngine.Result? = nil) {
        self.night = night
        self.analysis = analysis
        self.decision = decision
        self.model = SleepDetailPresentation(analysis: analysis,
                                             decision: decision,
                                             resolvedSource: night.resolvedSource,
                                             lastSyncAt: night.lastHealthKitSyncAt,
                                             nightDate: night.date)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headline
                breakdownSection
                hypnogramSection
                comparisonsSection
                insightsSection
                provenanceSection
                footerSection
            }
            .padding(20)
            .padding(.bottom, 40)
        }
        .background(BaselineColor.base.ignoresSafeArea())
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
    }

    // MARK: - Headline

    @ViewBuilder private var headline: some View {
        switch model.headline {
        case .score(let score):
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(score)")
                        .font(.system(size: 50, weight: .heavy))
                        .foregroundStyle(BaselineColor.textHi)
                    Text("/ 100")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(BaselineColor.textFaint)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if let band = model.bandLabel {
                        Text(band)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(SleepScoreBand(score: score).color)
                    }
                    if !model.dateLabel.isEmpty {
                        Text(model.dateLabel.uppercased())
                            .font(.bMono(9, .semibold)).tracking(0.8)
                            .foregroundStyle(BaselineColor.textFaint)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(scoreAccessibilityLabel(score)))
        case .partial(let observed, let possible, let coverage):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(observed)").font(.system(size: 50, weight: .heavy)).foregroundStyle(BaselineColor.textHi)
                    Text("of \(possible) pts").font(.system(size: 17, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                }
                InstrumentLabel("Observed · \(coverage)% coverage")
                Text("Not enough evidence for a full score.")
                    .font(.system(size: 13)).foregroundStyle(BaselineColor.textMid)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(observed) of \(possible) possible points observed, \(coverage) percent coverage. Not enough evidence for a full score.")
        case .notScored(let duration, let caption):
            VStack(alignment: .leading, spacing: 2) {
                Text(duration ?? "No sleep recorded")
                    .font(.system(size: duration == nil ? 24 : 44, weight: .heavy))
                    .foregroundStyle(BaselineColor.textHi)
                    .fixedSize(horizontal: false, vertical: true)
                InstrumentLabel(caption)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(duration.map { "\($0) asleep, \(caption)" } ?? caption)
        }
    }

    private func scoreAccessibilityLabel(_ score: Int) -> String {
        var parts = ["Sleep score \(score) of 100"]
        if let band = model.bandLabel { parts.append(band) }
        if !model.dateLabel.isEmpty { parts.append(model.dateLabel) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Score breakdown (with the inline ⓘ → About)

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                InstrumentLabel("Score breakdown")
                Spacer()
                NavigationLink {
                    SleepScoreAboutView(score: analysis.score)
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(BaselineColor.accent)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("How your score works")
            }
            VStack(spacing: 0) {
                ForEach(model.components) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(row.isAvailable ? row.kind.color : BaselineColor.textFaint)
                                    .frame(width: 7, height: 7)
                                Text(row.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(row.isAvailable ? row.kind.color : BaselineColor.textFaint)
                            }
                            Spacer()
                            Text(row.value).font(.bMono(14, .medium))
                                .foregroundStyle(row.isAvailable ? BaselineColor.textHi : BaselineColor.textFaint)
                        }
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(.system(size: 12.5))
                                .foregroundStyle(BaselineColor.textMid)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ComponentBar(fraction: row.fraction,
                                     color: row.kind.color,
                                     available: row.isAvailable)
                            .padding(.top, 5)
                    }
                    .padding(.vertical, 13)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(componentAccessibilityLabel(row))
                    if row.id != model.components.last?.id {
                        Divider().overlay(BaselineColor.line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 3)
        .background(RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous)
            .fill(BaselineColor.surface))
    }

    private func componentAccessibilityLabel(_ row: SleepDetailPresentation.ComponentRow) -> String {
        row.subtitle.isEmpty
            ? "\(row.title): \(row.value)"
            : "\(row.title): \(row.value). \(row.subtitle)"
    }

    // MARK: - Overnight staged hypnogram

    private var hypnogramSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 12) {
                InstrumentLabel("Overnight · sleep stages")
                SleepHypnogramChart(intervals: night.primaryEpisode?.intervals ?? [],
                                    gaps: night.primaryEpisode?.gaps ?? [])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous)
                .fill(BaselineColor.surface))
            Text(model.stageEvidenceCaption)
                .font(.system(size: 11.5)).foregroundStyle(BaselineColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }

    // MARK: - Comparisons + flags

    @ViewBuilder private var comparisonsSection: some View {
        if !model.comparisons.isEmpty || !model.flags.isEmpty {
            sectionCard(title: "Vs your baseline") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.comparisons) { stat in
                        HStack {
                            Text(stat.label).font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                            Spacer()
                            Text(stat.value).font(.bMono(14, .bold)).foregroundStyle(BaselineColor.textHi)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(stat.label): \(stat.value)")
                    }
                    ForEach(model.flags, id: \.self) { flag in
                        HStack(spacing: 8) {
                            Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(BaselineColor.accent)
                            Text(flag).font(.system(size: 13, weight: .medium)).foregroundStyle(BaselineColor.textMid)
                        }
                        .accessibilityLabel("Notable: \(flag)")
                    }
                }
            }
        }
    }

    // MARK: - Insights

    @ViewBuilder private var insightsSection: some View {
        if !model.insights.isEmpty {
            sectionCard(title: "Notes") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.insights, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(BaselineColor.textFaint).frame(width: 4, height: 4).padding(.top, 7)
                            Text(line).font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Provenance

    private var provenanceSection: some View {
        sectionCard(title: "Source & sync") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.provenance) { stat in
                    HStack {
                        Text(stat.label).font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
                        Spacer()
                        Text(stat.value).font(.system(size: 13, weight: .medium)).foregroundStyle(BaselineColor.textMid)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(stat.label): \(stat.value)")
                }
            }
        }
    }

    // MARK: - Influence / cap footer (AC-4)

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InstrumentLabel("Today's decision")
            if let influence = model.footer.influence {
                Text(influence).font(.system(size: 13)).foregroundStyle(BaselineColor.textMid)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cap = model.footer.cap {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(BaselineColor.zoneAmber)
                    Text(cap).font(.system(size: 13, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note = model.footer.note {
                Text(note).font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous)
            .strokeBorder(BaselineColor.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Building blocks

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InstrumentLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous)
            .fill(BaselineColor.surface))
    }
}

/// A component score bar tinted with its component's color; hairline-dashed when the component was
/// not observable.
private struct ComponentBar: View {
    let fraction: Double
    let color: Color
    let available: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(BaselineColor.base)
                if available {
                    Capsule().fill(color)
                        .frame(width: max(2, CGFloat(fraction) * geo.size.width))
                } else {
                    Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(BaselineColor.line)
                }
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Detail · full staged night · dark") {
    NavigationStack {
        SleepDetailView(night: SleepPreviewFixtures.stagedNight,
                        analysis: SleepPreviewFixtures.stagedAnalysis,
                        decision: SleepPreviewFixtures.cappedDecision)
    }
    .preferredColorScheme(.dark)
}

#Preview("Detail · full night · accessibility XL") {
    NavigationStack {
        SleepDetailView(night: SleepPreviewFixtures.stagedNight,
                        analysis: SleepPreviewFixtures.stagedAnalysis,
                        decision: SleepPreviewFixtures.influenceOnlyDecision)
    }
    .environment(\.dynamicTypeSize, .accessibility3)
    .preferredColorScheme(.dark)
}

#Preview("Detail · cold-start partial · dark") {
    NavigationStack {
        SleepDetailView(night: SleepPreviewFixtures.partialNight,
                        analysis: SleepPreviewFixtures.partialAnalysis,
                        decision: nil)
    }
    .preferredColorScheme(.dark)
}

#Preview("Detail · manual low-reliability · dark") {
    NavigationStack {
        SleepDetailView(night: SleepPreviewFixtures.manualNight,
                        analysis: SleepPreviewFixtures.manualAnalysis,
                        decision: nil)
    }
    .preferredColorScheme(.dark)
}
#endif
