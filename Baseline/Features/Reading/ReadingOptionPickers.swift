import SwiftUI

/// M:SS wheel picker for the morning reading length (1:00–5:59), presented as a CANCEL/SAVE sheet
/// from the morning prompt. Edits a scratch value and only commits on SAVE.
struct DurationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let seconds: Int
    let onSave: (Int) -> Void

    @State private var minutes: Int
    @State private var secs: Int

    init(seconds: Int, onSave: @escaping (Int) -> Void) {
        self.seconds = seconds
        self.onSave = onSave
        _minutes = State(initialValue: seconds / 60)
        _secs = State(initialValue: seconds % 60)
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            VStack(spacing: 0) {
                header(title: "DURATION") {
                    onSave(min(max(minutes * 60 + secs, ReadingLength.range.lowerBound), ReadingLength.range.upperBound))
                    dismiss()
                }
                Spacer()
                HStack(spacing: 0) {
                    Picker("Minutes", selection: $minutes) {
                        ForEach(1...5, id: \.self) { Text("\(String(format: "%02d", $0))").tag($0) }
                    }
                    .pickerStyle(.wheel).frame(width: 90)
                    Text(":").font(.bMono(28, .bold)).foregroundStyle(BaselineColor.accent)
                    Picker("Seconds", selection: $secs) {
                        ForEach(0...59, id: \.self) { Text("\(String(format: "%02d", $0))").tag($0) }
                    }
                    .pickerStyle(.wheel).frame(width: 90)
                }
                .colorScheme(.dark)
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private func header(title: String, save: @escaping () -> Void) -> some View {
        HStack {
            Button("CANCEL") { dismiss() }
                .font(.bMono(12, .medium)).tracking(1).foregroundStyle(BaselineColor.textFaint)
            Spacer()
            InstrumentLabel(title, tracking: 1.5)
            Spacer()
            Button("SAVE") { Haptics.select(); save() }
                .font(.bMono(12, .bold)).tracking(1).foregroundStyle(BaselineColor.accent)
        }
        .padding(.top, 18)
    }
}

/// Body-position picker (lying / sitting / standing) as a CANCEL/SAVE sheet.
struct PositionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let position: BodyPosition
    let onSave: (BodyPosition) -> Void

    @State private var selection: BodyPosition

    init(position: BodyPosition, onSave: @escaping (BodyPosition) -> Void) {
        self.position = position
        self.onSave = onSave
        _selection = State(initialValue: position)
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button("CANCEL") { dismiss() }
                        .font(.bMono(12, .medium)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                    Spacer()
                    InstrumentLabel("POSITION", tracking: 1.5)
                    Spacer()
                    Button("SAVE") { Haptics.select(); onSave(selection); dismiss() }
                        .font(.bMono(12, .bold)).tracking(1).foregroundStyle(BaselineColor.accent)
                }
                .padding(.top, 18)

                VStack(spacing: 12) {
                    ForEach(BodyPosition.allCases) { pos in
                        Button {
                            Haptics.select()
                            selection = pos
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: icon(pos))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(selection == pos ? BaselineColor.accent : BaselineColor.textMid)
                                    .frame(width: 32)
                                Text(pos.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(BaselineColor.textHi)
                                Spacer()
                                Image(systemName: selection == pos ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(selection == pos ? BaselineColor.accent : BaselineColor.line)
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(BaselineColor.surface)
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(selection == pos ? BaselineColor.accent : BaselineColor.line, lineWidth: selection == pos ? 1.5 : 1))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 28)
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .presentationDetents([.medium])
    }

    private func icon(_ position: BodyPosition) -> String {
        switch position {
        case .lyingDown: "bed.double.fill"
        case .sitting: "figure.seated.side"
        case .standing: "figure.stand"
        }
    }
}
