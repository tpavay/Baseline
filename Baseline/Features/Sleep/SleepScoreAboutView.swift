import SwiftUI

/// "How your score works" - the About screen the sleep detail's ⓘ opens (approved redesign, screen
/// 4). Content is written from the real scoring algorithm: the three components with their point
/// caps and what each measures, the Apple-post-26.2 band cutoffs, and the notes that stages are
/// context-only and manual nights aren't scored. Static, honest copy - no live numbers beyond the
/// current score's position in the band ladder.
struct SleepScoreAboutView: View {
    /// The night's published score, to highlight where it lands in the band ladder; nil renders the
    /// ladder without a highlight (partial/manual nights have no score).
    var score: Int?

    private struct ComponentCard: Identifiable {
        let kind: SleepComponent.Kind
        let title: String
        let cap: String
        let detail: String
        var id: SleepComponent.Kind { kind }
    }

    /// Point caps and copy mirror `SleepEngine.Tunables` (duration 50 / bedtime consistency 30 /
    /// interruptions 20; 30-minute bedtime grace band).
    private let cards: [ComponentCard] = [
        ComponentCard(
            kind: .duration,
            title: "Duration",
            cap: "up to 50 pts",
            detail: "Time asleep vs your sleep goal. Full points at your goal or above; tapers as you fall short."
        ),
        ComponentCard(
            kind: .bedtimeConsistency,
            title: "Bedtime consistency",
            cap: "up to 30 pts",
            detail: "How close last night's bedtime was to your recent average. Full points within ~30 min; tapers as your schedule drifts."
        ),
        ComponentCard(
            kind: .interruptions,
            title: "Interruptions",
            cap: "up to 20 pts",
            detail: "Time awake after falling asleep, plus how many times you woke. Fewer, shorter wake-ups score higher."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BaselineSpacing.section) {
                Text("How your score works")
                    .baselineTypography(.screenTitle)
                    .foregroundStyle(BaselineColor.textHi)
                Text("A 0–100 estimate of how restorative last night was, built from three things you can act on - and only from what your watch actually measured. It never guesses.")
                    .font(.system(size: 13))
                    .foregroundStyle(BaselineColor.textMid)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, BaselineSpacing.xxSmall)

                ForEach(cards) { card in
                    componentCard(card)
                }

                bandCard

                Text("Sleep stages (REM / Deep / Core) are shown as context but never change the score. Manually logged nights aren't scored. Component weights follow Apple's published weighting; the detail curves are Baseline's.")
                    .font(.system(size: 12))
                    .foregroundStyle(BaselineColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, BaselineSpacing.xxSmall)
            }
            .padding(BaselineSpacing.xLarge)
            .padding(.bottom, BaselineSpacing.scrollBottom)
        }
        .background(BaselineColor.base.ignoresSafeArea())
        .navigationTitle("Sleep score")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
    }

    private func componentCard(_ card: ComponentCard) -> some View {
        VStack(alignment: .leading, spacing: BaselineSpacing.xxSmall) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(card.kind.color)
                Spacer()
                Text(card.cap)
                    .font(.bMono(13, .medium))
                    .foregroundStyle(BaselineColor.textFaint)
            }
            Text(card.detail)
                .font(.system(size: 13))
                .foregroundStyle(BaselineColor.textMid)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BaselineSpacing.large)
        .background(RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous)
            .fill(BaselineColor.surface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title), \(card.cap). \(card.detail)")
    }

    private var bandCard: some View {
        let currentBand = score.map(SleepScoreBand.init(score:))
        return VStack(alignment: .leading, spacing: BaselineSpacing.small) {
            InstrumentLabel(score.map { "Where \($0) lands" } ?? "Score bands")
            FlowRow(spacing: 6) {
                ForEach(Array(SleepScoreBand.allCases.enumerated()), id: \.offset) { index, band in
                    if index > 0 {
                        Text("·").font(.bMono(11, .medium)).foregroundStyle(BaselineColor.textFaint)
                    }
                    Text("\(band.label) \(band.rangeLabel)")
                        .font(.bMono(11, band == currentBand ? .bold : .medium))
                        .foregroundStyle(band == currentBand ? band.color : BaselineColor.textFaint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BaselineSpacing.large)
        .background(RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous)
            .fill(BaselineColor.surface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bandAccessibilityLabel(currentBand))
    }

    private func bandAccessibilityLabel(_ currentBand: SleepScoreBand?) -> String {
        let ladder = SleepScoreBand.allCases
            .map { "\($0.label) \($0.rangeLabel)" }
            .joined(separator: ", ")
        if let score, let currentBand {
            return "Where \(score) lands: \(currentBand.label). Bands: \(ladder)"
        }
        return "Score bands: \(ladder)"
    }
}

// MARK: - Shared component/band colors

extension SleepComponent.Kind {
    /// The approved redesign's component color, shared by the score ring, the breakdown bars, and
    /// the About cards so the three surfaces always agree.
    var color: Color {
        switch self {
        case .duration: BaselineColor.zoneBlue
        case .bedtimeConsistency: BaselineColor.zoneGreen
        case .interruptions: BaselineColor.zoneRed
        }
    }
}

extension SleepScoreBand {
    /// Semantic band color for the detail headline's band word and the About ladder highlight.
    var color: Color {
        switch self {
        case .veryLow: BaselineColor.zoneRed
        case .low: BaselineColor.zoneAmber
        case .ok, .high, .veryHigh: BaselineColor.zoneGreen
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("About · scored night") {
    NavigationStack { SleepScoreAboutView(score: 78) }
        .preferredColorScheme(.dark)
}

#Preview("About · no score") {
    NavigationStack { SleepScoreAboutView(score: nil) }
        .preferredColorScheme(.dark)
}
#endif
