import SwiftUI

/// A check-in metric described as an ordered set of labeled steps. The UI renders any scale
/// generically, so adding or retuning a metric is a data change here — not new view code. Steps
/// are listed in left→right display order; `bestOnRight` says which visual end is the most
/// recovered, and everything maps to a single oriented recovery value in 1…5 (5 = most recovered)
/// that the score already understands (`ReadinessScore.subjectiveScore`).
struct CheckInScale {
    struct Step: Equatable {
        let label: String
        var emoji: String? = nil
    }

    let title: String
    let steps: [Step]
    let bestOnRight: Bool

    var count: Int { steps.count }

    /// Steps that all carry an emoji render as a tap-to-pick emoji row instead of a slider.
    var isEmojiPicker: Bool { !steps.isEmpty && steps.allSatisfy { $0.emoji != nil } }

    /// Oriented recovery value in 1…5 for a left→right index (5 = most recovered).
    func oriented(displayIndex i: Int) -> Double {
        guard count > 1 else { return 3 }
        let rank = bestOnRight ? Double(i) : Double(count - 1 - i)   // 0 = worst … count-1 = best
        return 1 + 4 * rank / Double(count - 1)
    }

    /// Nearest left→right index for a stored oriented value — to restore the thumb and its label.
    func displayIndex(forOriented v: Double) -> Int {
        guard count > 1 else { return 0 }
        let rank = (v - 1) / 4 * Double(count - 1)                   // 0 = worst … count-1 = best
        let idx = bestOnRight ? rank : Double(count - 1) - rank
        return min(max(Int(idx.rounded()), 0), count - 1)
    }

    func label(forOriented v: Double) -> String {
        let step = steps[displayIndex(forOriented: v)]
        return (step.emoji.map { "\($0)  " } ?? "") + step.label
    }
}

extension CheckInComponent {
    /// The metric's scale. Directions are the athlete's natural framing (soreness/stress worst on
    /// the right; mood/energy best on the right); orientation to 1…5 is handled by `CheckInScale`.
    var scale: CheckInScale {
        switch self {
        case .soreness:
            CheckInScale(title: "Muscle soreness", steps: [
                .init(label: "None"), .init(label: "Barely noticeable"), .init(label: "Somewhat sore"),
                .init(label: "Sore"), .init(label: "Very sore"), .init(label: "Extremely sore"),
            ], bestOnRight: false)
        case .energy:
            CheckInScale(title: "Energy levels", steps: [
                .init(label: "Exhausted"), .init(label: "Tired"), .init(label: "Normal"),
                .init(label: "Energized"), .init(label: "Full of energy"),
            ], bestOnRight: true)
        case .mood:
            CheckInScale(title: "Mood", steps: [
                .init(label: "Angry", emoji: "😠"), .init(label: "Sad", emoji: "😢"),
                .init(label: "Worried", emoji: "😟"), .init(label: "Calm", emoji: "🙂"),
                .init(label: "Happy", emoji: "😄"),
            ], bestOnRight: true)
        case .stress:
            CheckInScale(title: "Stress", steps: [
                .init(label: "None"), .init(label: "Low"), .init(label: "Moderate"), .init(label: "High"),
            ], bestOnRight: false)
        case .sleepQuality:
            CheckInScale(title: "Sleep quality", steps: [
                .init(label: "Terrible"), .init(label: "Poor"), .init(label: "Fair"),
                .init(label: "Good"), .init(label: "Excellent"),
            ], bestOnRight: true)
        }
    }

    /// Where this component's answer lives on `CheckInAnswers` — lets views bind generically.
    var answerKeyPath: WritableKeyPath<CheckInAnswers, Double?> {
        switch self {
        case .soreness: \.soreness
        case .mood: \.mood
        case .energy: \.energy
        case .stress: \.stress
        case .sleepQuality: \.sleepQuality
        }
    }
}

/// A single check-in rating row: a discrete slider snapping across a `CheckInScale`'s steps, with
/// the current step's label (and emoji, if any) and the two end labels. Binds an optional so an
/// untouched item reads "NOT SELECTED" and drops out of the score — the first touch commits a value
/// even at the midpoint (via `onEditingChanged`).
struct CheckInScaleView: View {
    let scale: CheckInScale
    @Binding var value: Double?

    private var isSet: Bool { value != nil }
    private var lastIndex: Int { max(scale.count - 1, 1) }

    private var indexProxy: Binding<Double> {
        Binding(
            get: {
                if let v = value { return Double(scale.displayIndex(forOriented: v)) }
                return Double(scale.count - 1) / 2   // centered while unset
            },
            set: { value = scale.oriented(displayIndex: Int($0.rounded())) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(scale.title.uppercased())
                    .font(.bMono(12, .bold)).tracking(1.5)
                    .foregroundStyle(BaselineColor.textHi)
                Spacer()
                if isSet, let v = value {
                    Text(isEmojiTitle(v))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(BaselineColor.accent)
                        .contentTransition(.opacity)
                } else {
                    Text("NOT SELECTED")
                        .font(.bMono(10, .bold)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                }
            }
            if scale.isEmojiPicker { emojiRow } else { slider }
        }
    }

    /// Emoji title without the glyph doubled up (the emoji is already on the selected chip).
    private func isEmojiTitle(_ v: Double) -> String {
        scale.isEmojiPicker ? scale.steps[scale.displayIndex(forOriented: v)].label : scale.label(forOriented: v)
    }

    private var slider: some View {
        Slider(value: indexProxy, in: 0...Double(lastIndex), step: 1) { editing in
            if editing, value == nil {
                value = scale.oriented(displayIndex: Int(indexProxy.wrappedValue.rounded()))
                Haptics.select()
            }
        }
        .tint(isSet ? BaselineColor.accent : BaselineColor.line)
        .onChange(of: indexProxy.wrappedValue) { _, _ in if isSet { Haptics.select() } }
    }

    private var emojiRow: some View {
        let selectedIndex = value.map { scale.displayIndex(forOriented: $0) }
        return HStack(spacing: 8) {
            ForEach(Array(scale.steps.enumerated()), id: \.offset) { i, step in
                let on = selectedIndex == i
                Button {
                    value = scale.oriented(displayIndex: i)
                    Haptics.select()
                } label: {
                    Text(step.emoji ?? "")
                        .font(.system(size: 26))
                        .opacity(on ? 1 : (selectedIndex == nil ? 0.85 : 0.45))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(on ? BaselineColor.accent.opacity(0.9) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
    }
}
