import SwiftUI

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
