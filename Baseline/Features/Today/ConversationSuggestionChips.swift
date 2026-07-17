import SwiftUI

/// The row of openers above the composer. Selecting one *fills* the composer rather than sending
/// it: the prompt is a starting point to edit ("my knee" becomes "my Achilles"), so a second tap
/// simply replaces the first, nothing having been committed either time.
///
/// Styled off the accent deliberately. The send button is the only accent-filled control here, and
/// a chip that competed with it would read as the thing to press.
struct ConversationSuggestionChips: View {
    let suggestions: [ConversationSuggestion]
    let onSelect: (ConversationSuggestion) -> Void

    /// 13pt at the default text size, matching the app's other chip rows, but scaled rather than
    /// frozen, and paired with padding instead of a fixed height so a capsule grows with its label
    /// under Dynamic Type instead of clipping it. The row already scrolls, so wider chips are free.
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 13

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button { onSelect(suggestion) } label: {
                        Text(suggestion.label)
                            .font(.system(size: labelSize, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(BaselineColor.textMid)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(BaselineColor.surface))
                            .overlay(Capsule().strokeBorder(BaselineColor.line, lineWidth: 1))
                            // The row's breathing room, taken inside the button and outside the
                            // capsule: the chip draws 32pt as before, but answers to a 48pt touch,
                            // clearing the 44pt floor. The minimum holds that floor at the smallest
                            // text sizes, where the capsule itself shrinks.
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint("Fills the message box with \u{201C}\(suggestion.prompt)\u{201D} to edit before sending")
                }
            }
            .padding(.horizontal, 14)
        }
        .scrollBounceBehavior(.basedOnSize)   // a row that already fits shouldn't rubber-band
    }
}

#Preview {
    ZStack {
        BaselineColor.base.ignoresSafeArea()
        VStack(spacing: 24) {
            ConversationSuggestionChips(suggestions: ConversationSuggestion.all(for: .general)) { _ in }
            ConversationSuggestionChips(suggestions: ConversationSuggestion.all(for: .workoutImport)) { _ in }
        }
    }
}
