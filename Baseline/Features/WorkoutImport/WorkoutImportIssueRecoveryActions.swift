import SwiftUI

struct WorkoutImportIssueRecoveryActions: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let showsUseWatts: Bool
    let onUseWatts: () -> Void
    let onRemoveTarget: () -> Void

    @State private var confirmingRemoval = false

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 16))

        layout {
            if showsUseWatts {
                Button("Use watts", action: onUseWatts)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.accent)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Use watts for this power target")
                    .accessibilityHint("Keeps the imported range and confirms that its unit is watts")
            }

            Button("Remove target", role: .destructive) {
                confirmingRemoval = true
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .accessibilityHint("Asks for confirmation before removing this imported intensity target")
            .confirmationDialog(
                "Remove this target?",
                isPresented: $confirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove target", role: .destructive, action: onRemoveTarget)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the imported intensity target from the workout. The source photo stays available.")
            }
        }
    }
}
