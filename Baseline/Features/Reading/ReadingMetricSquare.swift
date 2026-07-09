import SwiftUI

/// The square "TIME LIMIT / BODY POSITION" tile on the pre-reading start screens. Tappable when an
/// `action` is given (opens a picker); a fixed value (e.g. the snapshot's 1:00) passes none.
struct ReadingMetricSquare: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    var action: (() -> Void)? = nil

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(BaselineColor.textMid)
                    Spacer()
                }
                Spacer()
                Text(value)
                    .font(.bMono(value.count > 6 ? 23 : 34, .bold))
                    .foregroundStyle(BaselineColor.textHi)
                    .lineLimit(1).minimumScaleFactor(0.65)
                Text(title)
                    .font(.bMono(11, .bold)).tracking(1)
                    .foregroundStyle(BaselineColor.textHi)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(BaselineColor.textFaint)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BaselineColor.surface.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(BaselineColor.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}
