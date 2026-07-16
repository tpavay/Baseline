import SwiftUI

struct WorkoutInstructionText: View {
    let lines: [String]
    var placeholder: String?

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(BaselineColor.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(index == 0 ? "Instructions. \(line)" : line)
                }
            }
        } else if let placeholder {
            Text(placeholder)
                .font(.subheadline)
                .foregroundStyle(BaselineColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("No exercise notes")
        }
    }
}
