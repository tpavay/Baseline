import SwiftUI

/// The plan's own note, rendered as quiet read-only context above the athlete's editable session
/// note. The caption, the rule, and the fainter treatment are load-bearing: they are what tells the
/// athlete — by sight and through VoiceOver — which of the two blocks accepts what they type.
struct WorkoutPlanNote: View {
    let text: String
    var font: Font = .subheadline
    var accessibilityLabel: String = "Plan note"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("FROM YOUR PLAN")
                .font(.bMono(11, .bold)).tracking(0.8)
                .foregroundStyle(BaselineColor.textFaint)
            Text(text)
                .font(font)
                .foregroundStyle(BaselineColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Capsule().fill(BaselineColor.line).frame(width: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityLabel). \(text)")
    }
}

struct WorkoutNotesField: View {
    let prompt: String
    @Binding var text: String
    var font: Font = .subheadline
    var lineLimit: PartialRangeFrom<Int> = 2...
    var accessibilityLabel: String = "Notes"

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .font(font)
            .foregroundStyle(BaselineColor.textMid)
            .lineLimit(lineLimit)
            .textInputAutocapitalization(.sentences)
            .focused($isFocused)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .accessibilityLabel(accessibilityLabel)
    }
}
