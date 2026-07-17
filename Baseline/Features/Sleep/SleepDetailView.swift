import SwiftUI

/// The sleep evidence screen pushed from Today's sleep row (plan §9). Explains the night behind the
/// readiness decision: score-or-observed-points + quality badge → stage timeline → duration/awake/gap
/// stats → Apple-aligned component breakdown → additional stage evidence (visually distinct from the
/// score) → vs-you comparisons + flags → descriptive insights → provenance → influence/cap footer.
///
/// All formatting/mapping is in `SleepDetailPresentation` (pure, tested); `body` only lays out already
/// resolved sections. The timeline needs the raw stage intervals, which live on the `SleepNight`, so
/// the view takes the night (facts) plus its `analysis` (derived) — the repository holds both.
struct SleepDetailView: View {
    let night: SleepNight
    let analysis: SleepAnalysis
    var decision: DecisionEngine.Result?

    /// Built once when the view value is created, not on every property read — the mapping runs
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
                                             lastSyncAt: night.lastHealthKitSyncAt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headline
                timelineSection
                statsSection
                componentsSection
                stageEvidenceSection
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

    private var headline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                headlineValue
                Spacer()
                badge
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var headlineValue: some View {
        switch model.headline {
        case .score(let score):
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(score)").font(.bMono(52, .bold)).foregroundStyle(BaselineColor.textHi)
                    Text("/ 100").font(.bMono(16, .medium)).foregroundStyle(BaselineColor.textFaint)
                }
                InstrumentLabel("Sleep score")
            }
            .accessibilityLabel("Sleep score \(score) of 100")
        case .partial(let observed, let possible, let coverage):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(observed)").font(.bMono(52, .bold)).foregroundStyle(BaselineColor.textHi)
                    Text("of \(possible) pts").font(.bMono(16, .medium)).foregroundStyle(BaselineColor.textFaint)
                }
                InstrumentLabel("Observed · \(coverage)% coverage")
                Text("Not enough evidence for a full score.")
                    .font(.system(size: 13)).foregroundStyle(BaselineColor.textMid)
            }
            .accessibilityLabel("\(observed) of \(possible) possible points observed, \(coverage) percent coverage. Not enough evidence for a full score.")
        case .notScored(let duration, let caption):
            VStack(alignment: .leading, spacing: 2) {
                Text(duration ?? "No sleep recorded")
                    .font(.bMono(duration == nil ? 24 : 44, .bold)).foregroundStyle(BaselineColor.textHi)
                    .fixedSize(horizontal: false, vertical: true)
                InstrumentLabel(caption)
            }
            .accessibilityLabel(duration.map { "\($0) asleep, \(caption)" } ?? caption)
        }
    }

    private var badge: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if model.badge.isProvisional {
                Text(model.badge.status.uppercased())
                    .font(.bMono(10, .bold)).tracking(1)
                    .foregroundStyle(BaselineColor.zoneAmber)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().stroke(BaselineColor.zoneAmber.opacity(0.6), lineWidth: 1))
            } else {
                Text(model.badge.status.uppercased())
                    .font(.bMono(10, .bold)).tracking(1)
                    .foregroundStyle(BaselineColor.textMid)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().stroke(BaselineColor.line, lineWidth: 1))
            }
            Text(model.badge.reliability)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.badge.status), \(model.badge.reliability)")
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        sectionCard(title: "Overnight") {
            SleepTimelineChart(intervals: night.primaryEpisode?.intervals ?? [],
                               gaps: night.primaryEpisode?.gaps ?? [],
                               naps: night.episodes.filter { !$0.isPrimary })
        }
    }

    // MARK: - Stats

    @ViewBuilder private var statsSection: some View {
        if !model.stats.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.stats) { stat in
                    VStack(alignment: .leading, spacing: 4) {
                        // One line, scaled to fit the narrow column, so a value never breaks mid-word.
                        Text(stat.value).font(.bMono(18, .bold)).foregroundStyle(BaselineColor.textHi)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        InstrumentLabel(stat.label, tracking: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(stat.label): \(stat.value)")
                    if stat.id != model.stats.last?.id {
                        Rectangle().fill(BaselineColor.line).frame(width: 1, height: 32)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
        }
    }

    // MARK: - Components

    private var componentsSection: some View {
        sectionCard(title: "Score breakdown") {
            VStack(spacing: 12) {
                ForEach(model.components) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(row.title).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(row.isAvailable ? BaselineColor.textHi : BaselineColor.textFaint)
                            Spacer()
                            Text(row.value).font(.bMono(13, .bold))
                                .foregroundStyle(row.isAvailable ? BaselineColor.textMid : BaselineColor.textFaint)
                        }
                        ComponentBar(fraction: row.fraction, available: row.isAvailable)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.title): \(row.value)")
                }
            }
        }
    }

    // MARK: - Additional stage evidence (visually distinct from the score)

    private var stageEvidenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path").font(.system(size: 12)).foregroundStyle(BaselineColor.sleepREM)
                InstrumentLabel("Sleep stages", color: BaselineColor.sleepREM)
            }
            if model.stageEvidence.isEmpty {
                Text("No stage detail from this source.")
                    .font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.stageEvidence) { row in
                        HStack {
                            RoundedRectangle(cornerRadius: 3).fill(row.stage.color).frame(width: 12, height: 12)
                            Text(row.label).font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textHi)
                            Spacer()
                            Text(row.duration).font(.bMono(13, .bold)).foregroundStyle(BaselineColor.textMid)
                            Text(row.share).font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.label): \(row.duration), \(row.share)")
                    }
                }
                Text(model.stageEvidenceCaption)
                    .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Distinct surface + accent hairline so stage evidence never reads as part of the score card.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.amethyst.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(BaselineColor.sleepCore.opacity(0.4), lineWidth: 1))
        )
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
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }
}

/// A component score bar; hairline-dashed when the component was not observable.
private struct ComponentBar: View {
    let fraction: Double
    let available: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(BaselineColor.base)
                if available {
                    Capsule().fill(BaselineColor.accent)
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
#Preview("Detail · full staged night · light") {
    NavigationStack {
        SleepDetailView(night: SleepPreviewFixtures.stagedNight,
                        analysis: SleepPreviewFixtures.stagedAnalysis,
                        decision: SleepPreviewFixtures.cappedDecision)
    }
    .preferredColorScheme(.light)
}

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

#Preview("Detail · manual low-reliability · light") {
    NavigationStack {
        SleepDetailView(night: SleepPreviewFixtures.manualNight,
                        analysis: SleepPreviewFixtures.manualAnalysis,
                        decision: nil)
    }
    .preferredColorScheme(.light)
}
#endif
