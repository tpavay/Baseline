import SwiftUI

/// Everything Today needs to render the sleep row and push its detail. Assembled only when a canonical
/// night exists for today; **absent while the Sleep Engine is dormant**, which is exactly what keeps
/// Today byte-identical to pre-slice (AC-6/AC-7): no context → no row → no tap target.
struct SleepDetailContext: Equatable {
    var night: SleepNight
    var analysis: SleepAnalysis
    var decision: DecisionEngine.Result?
}

/// Pure row presentation. `make` returns nil **iff** there is no analysis for today — the single
/// dormancy gate the row view and `TodaySleepRowTests` both rely on, so the "tappable iff analysis
/// present" behavior is asserted without a view tree.
struct TodaySleepRowModel: Equatable {
    var headline: String   // "82" (score) or "45/50" (observed/possible when partial)
    var isScore: Bool
    var caption: String    // "7 h 18 m asleep · High reliability"
    var accessibilityLabel: String

    static func make(_ context: SleepDetailContext?) -> TodaySleepRowModel? {
        guard let context else { return nil }
        let a = context.analysis
        let headline = a.score.map(String.init) ?? "\(a.observedPoints)/\(a.possiblePoints)"
        let duration = a.asleepHours.map { "\(SleepFormat.hours($0)) asleep" }
        let reliability = reliabilityWord(a.quality.reliability, source: context.night.resolvedSource)
        let caption = [duration, reliability].compactMap { $0 }.joined(separator: " · ")
        let headSpoken = a.score.map { "Sleep score \($0)" }
            ?? "Sleep, \(a.observedPoints) of \(a.possiblePoints) points observed"
        return TodaySleepRowModel(
            headline: headline,
            isScore: a.score != nil,
            caption: caption,
            accessibilityLabel: caption.isEmpty ? headSpoken : "\(headSpoken), \(caption)")
    }

    private static func reliabilityWord(_ reliability: Double, source: SleepSource) -> String? {
        if case .manual = source { return "Manual entry" }
        if case .none = source { return nil }
        if reliability >= 0.9 { return "High reliability" }
        if reliability >= 0.5 { return "Medium reliability" }
        return "Low reliability"
    }
}

/// The tappable Today sleep row (plan §2 Q-B: the **whole row** pushes the detail, not a chevron
/// target). Renders nothing when no analysis exists for today, preserving Today's dormant layout.
struct TodaySleepRow: View {
    let context: SleepDetailContext?

    var body: some View {
        if let context, let model = TodaySleepRowModel.make(context) {
            NavigationLink {
                SleepDetailView(night: context.night, analysis: context.analysis, decision: context.decision)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 16)).foregroundStyle(BaselineColor.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sleep").font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                        Text(model.caption).font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                    }
                    Spacer()
                    Text(model.headline).font(.bMono(model.isScore ? 20 : 15, .bold))
                        .foregroundStyle(BaselineColor.textHi)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BaselineColor.textFaint)
                }
                .padding(.horizontal, 16).frame(height: 60).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityHint("Opens sleep detail")
        }
    }
}

#if DEBUG
#Preview("Today sleep row · dark") {
    NavigationStack {
        VStack(spacing: 12) {
            TodaySleepRow(context: SleepDetailContext(night: SleepPreviewFixtures.stagedNight,
                                                      analysis: SleepPreviewFixtures.stagedAnalysis,
                                                      decision: SleepPreviewFixtures.cappedDecision))
            TodaySleepRow(context: SleepDetailContext(night: SleepPreviewFixtures.partialNight,
                                                      analysis: SleepPreviewFixtures.partialAnalysis,
                                                      decision: nil))
            // Dormant: no analysis → renders nothing (row is absent).
            TodaySleepRow(context: nil)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BaselineColor.base)
    }
    .preferredColorScheme(.dark)
}
#endif
