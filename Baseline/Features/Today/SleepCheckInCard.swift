import SwiftUI

/// Pure mapping for the upgraded check-in readout (AC-5), so the score/quality-hint copy is asserted
/// by `SleepCheckInCardTests` without a view tree. Built only when Health sleep + an analysis are both
/// present; a nil analysis leaves the legacy Health/manual card untouched.
struct SleepCheckInReadout: Equatable {
    var headline: String        // "82" (score) or "45/50" (observed/possible)
    var isScore: Bool
    var qualityHint: String
    var showsProvisional: Bool
    var accessibilityLabel: String

    init(asleepHours: Double, analysis: SleepAnalysis) {
        self.isScore = analysis.score != nil
        self.headline = analysis.score.map(String.init) ?? "\(analysis.observedPoints)/\(analysis.possiblePoints)"
        self.showsProvisional = analysis.quality.status == .provisional

        let gap = analysis.additionalEvidence.gapMinutes
        if analysis.quality.status == .provisional {
            self.qualityHint = "Still syncing from Apple Health"
        } else if let waso = analysis.wasoMinutes, waso >= 20 {
            self.qualityHint = "Some interruptions overnight"
        } else if gap >= 20 {
            self.qualityHint = "Contains a tracking gap"
        } else {
            self.qualityHint = "Synced from Apple Health"
        }

        let head = analysis.score.map { "Sleep score \($0)" }
            ?? "\(analysis.observedPoints) of \(analysis.possiblePoints) points observed"
        self.accessibilityLabel = "\(head), \(SleepCheckInReadout.durationText(asleepHours)) asleep. \(qualityHint)"
    }

    static func durationText(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

/// The "How did you sleep?" question. If Apple Health has last night's sleep, it's shown read-only
/// (that value feeds the score). Otherwise the athlete answers manually — a thumbs up/down and/or a
/// typed duration — which feeds the score when Health can't.
struct SleepCheckInCard: View {
    @Binding var answers: CheckInAnswers
    /// The Sleep Engine's analysis for last night, when available (plan §9, Slice 5). Defaulted nil so
    /// every existing call site (and the whole app while the engine is dormant) is byte-identical to
    /// pre-slice: nil → the legacy Health-duration / manual paths are untouched (AC-5/AC-7). A go-live
    /// caller supplies the analysis to unlock the upgraded readout.
    var analysis: SleepAnalysis? = nil
    @Environment(HealthService.self) private var health

    @State private var healthSleep: (hours: Double, efficiency: Double?)?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOW DID YOU SLEEP?")
                .font(.bMono(12, .bold)).tracking(1.5).foregroundStyle(BaselineColor.textHi)

            if !loaded {
                loadingCard
            } else if let s = healthSleep, let analysis {
                analysisCard(s, analysis)
            } else if let s = healthSleep {
                healthCard(s)
            } else {
                manualCard
            }
        }
        .task {
            healthSleep = await health.lastNightSleep()
            loaded = true
        }
    }

    /// Upgraded Health readout (AC-5): score (or observed points when partial) + duration + a quality
    /// hint, with a provisional marker when the source hasn't stabilized. Purely additive to the legacy
    /// `healthCard`; only reachable when an analysis is injected.
    private func analysisCard(_ s: (hours: Double, efficiency: Double?), _ analysis: SleepAnalysis) -> some View {
        SleepAnalysisReadoutCard(hours: s.hours, analysis: analysis)
    }

    // MARK: - States

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(BaselineColor.accent)
            Text("Checking Apple Health…").font(.system(size: 13, weight: .medium)).foregroundStyle(BaselineColor.textMid)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }

    private func healthCard(_ s: (hours: Double, efficiency: Double?)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 18)).foregroundStyle(BaselineColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(durationText(s.hours)).font(.system(size: 16, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                Text("Synced from Apple Health").font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(BaselineColor.zoneGreen)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }

    private var manualCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                thumb(up: true)
                thumb(up: false)
            }
            HStack {
                Text("Duration").font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textMid)
                Spacer()
                Stepper(
                    value: Binding(get: { answers.sleepHoursManual ?? 7.5 },
                                   set: { answers.sleepHoursManual = $0 }),
                    in: 0...14, step: 0.5
                ) {
                    Text(answers.sleepHoursManual.map(durationText) ?? "Not set")
                        .font(.bMono(14, .bold))
                        .foregroundStyle(answers.sleepHoursManual == nil ? BaselineColor.textFaint : BaselineColor.textHi)
                }
                .labelsHidden()
                .tint(BaselineColor.accent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }

    private func thumb(up: Bool) -> some View {
        let on = answers.sleepThumbsUp == up
        return Button {
            answers.sleepThumbsUp = up
            Haptics.select()
        } label: {
            Image(systemName: up ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? BaselineColor.base : BaselineColor.textMid)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? BaselineColor.accent : BaselineColor.base))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(on ? Color.clear : BaselineColor.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func durationText(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

/// The upgraded Health readout as its own view so it is previewable/renderable in isolation without a
/// live `HealthService`. Driven entirely by the pure `SleepCheckInReadout`.
struct SleepAnalysisReadoutCard: View {
    let hours: Double
    let analysis: SleepAnalysis

    var body: some View {
        let readout = SleepCheckInReadout(asleepHours: hours, analysis: analysis)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(readout.headline).font(.bMono(20, .bold)).foregroundStyle(BaselineColor.textHi)
                InstrumentLabel(readout.isScore ? "Sleep score" : "Sleep · observed", tracking: 1)
            }
            Rectangle().fill(BaselineColor.line).frame(width: 1, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(SleepCheckInReadout.durationText(hours)).font(.system(size: 16, weight: .bold))
                    .foregroundStyle(BaselineColor.textHi)
                Text(readout.qualityHint).font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
            }
            Spacer()
            if readout.showsProvisional {
                Text("SYNCING").font(.bMono(9, .bold)).tracking(1).foregroundStyle(BaselineColor.zoneAmber)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().stroke(BaselineColor.zoneAmber.opacity(0.6), lineWidth: 1))
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(BaselineColor.zoneGreen)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(readout.accessibilityLabel)
    }
}

#if DEBUG
#Preview("Check-in · Health analysis · dark") {
    VStack(alignment: .leading, spacing: 12) {
        Text("HOW DID YOU SLEEP?").font(.bMono(12, .bold)).tracking(1.5).foregroundStyle(BaselineColor.textHi)
        SleepAnalysisReadoutCard(hours: SleepPreviewFixtures.stagedNight.asleepHours ?? 7.3,
                                 analysis: SleepPreviewFixtures.stagedAnalysis)
        SleepAnalysisReadoutCard(hours: SleepPreviewFixtures.partialNight.asleepHours ?? 6.75,
                                 analysis: SleepPreviewFixtures.partialAnalysis)
    }
    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(BaselineColor.base)
    .preferredColorScheme(.dark)
}

#Preview("Check-in · Health analysis · light + XL") {
    VStack(alignment: .leading, spacing: 12) {
        Text("HOW DID YOU SLEEP?").font(.bMono(12, .bold)).tracking(1.5).foregroundStyle(BaselineColor.textHi)
        SleepAnalysisReadoutCard(hours: SleepPreviewFixtures.stagedNight.asleepHours ?? 7.3,
                                 analysis: SleepPreviewFixtures.stagedAnalysis)
    }
    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(BaselineColor.base)
    .environment(\.dynamicTypeSize, .accessibility3)
    .preferredColorScheme(.light)
}
#endif
