import SwiftUI

/// The "How did you sleep?" question. If Apple Health has last night's sleep, it's shown read-only
/// (that value feeds the score). Otherwise the athlete answers manually — a thumbs up/down and/or a
/// typed duration — which feeds the score when Health can't.
struct SleepCheckInCard: View {
    @Binding var answers: CheckInAnswers
    @Environment(HealthService.self) private var health

    @State private var healthSleep: (hours: Double, efficiency: Double?)?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOW DID YOU SLEEP?")
                .font(.bMono(12, .bold)).tracking(1.5).foregroundStyle(BaselineColor.textHi)

            if !loaded {
                loadingCard
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
