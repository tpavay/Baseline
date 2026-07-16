import SwiftUI

struct WorkoutSwipeActionRow<Content: View>: View {
    let actionTitle: String
    let systemImage: String
    var actionColor = BaselineColor.zoneRed
    let action: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragOffset: CGFloat = 0
    @State private var isOpen = false

    private let actionWidth: CGFloat = 88

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: performAction) {
                Label(actionTitle, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(minHeight: 44)
                    .background(actionColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(actionTitle)

            content
                .background(BaselineColor.base)
                .offset(x: horizontalOffset)
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .accessibilityAction(named: Text(actionTitle), performAction)
    }

    private var horizontalOffset: CGFloat {
        let startingOffset = isOpen ? -actionWidth : 0
        return min(0, max(-actionWidth, startingOffset + dragOffset))
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($dragOffset) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let shouldOpen = isOpen
                    ? value.translation.width < 28
                    : value.translation.width < -36
                withAnimation(reduceMotion ? nil : .snappy) {
                    isOpen = shouldOpen
                }
            }
    }

    private func performAction() {
        withAnimation(reduceMotion ? nil : .snappy) {
            isOpen = false
        }
        action()
    }
}
