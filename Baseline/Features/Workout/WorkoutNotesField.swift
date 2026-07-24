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

extension CoachGuidance {
    var notesText: String {
        var notes: [String] = []
        Self.append(goal, to: &notes)
        Self.append(tempo, to: &notes)
        notes.append(contentsOf: formCues.compactMap(Self.trimmedNote))
        notes.append(contentsOf: commonMistakes.compactMap(Self.trimmedNote))
        Self.append(progressionNotes, to: &notes)
        return notes.joined(separator: "\n\n")
    }

    static func notes(from text: String) -> CoachGuidance? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : CoachGuidance(formCues: [value])
    }

    private static func append(_ note: String?, to notes: inout [String]) {
        guard let value = trimmedNote(note) else { return }
        notes.append(value)
    }

    private static func trimmedNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
