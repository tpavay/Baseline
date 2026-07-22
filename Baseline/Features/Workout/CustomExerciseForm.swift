import SwiftUI

/// Manual custom-exercise creation using the approved Hevy-style editor and real taxonomy bindings.
struct CustomExerciseForm: View {
    let onCreate: (ExerciseDefinition) -> Void

    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CustomExerciseFormDraft
    @State private var activePicker: CustomExercisePickerKind?

    init(seedName: String, onCreate: @escaping (ExerciseDefinition) -> Void) {
        self.onCreate = onCreate
        _draft = State(initialValue: CustomExerciseFormDraft(name: seedName))
    }

    init(draft: CustomExerciseFormDraft, onCreate: @escaping (ExerciseDefinition) -> Void) {
        self.onCreate = onCreate
        _draft = State(initialValue: draft)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CustomExerciseAssetPlaceholder()
                    .padding(.top, BaselineSpacing.xSmall)
                    .padding(.bottom, BaselineSpacing.xxSmall)

                TextField(
                    "",
                    text: $draft.name,
                    prompt: Text("Exercise name").foregroundStyle(BaselineColor.textFaint)
                )
                .baselineTypography(.exerciseName)
                .foregroundStyle(BaselineColor.textHi)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, BaselineSpacing.xxxSmall)
                .padding(.top, BaselineSpacing.large)
                .padding(.bottom, BaselineSpacing.medium)
                .overlay(alignment: .bottom) {
                    Hairline(color: BaselineColor.line)
                }
                .accessibilityLabel("Exercise name")

                CustomExerciseClassificationRow(
                    label: "Equipment",
                    isRequired: true,
                    value: draft.equipment.map(CustomExerciseTaxonomyPresentation.title).joined(separator: ", "),
                    action: { activePicker = .equipment }
                )
                CustomExerciseClassificationRow(
                    label: "Primary muscle",
                    isRequired: true,
                    value: draft.primaryMuscles.map(CustomExerciseTaxonomyPresentation.title).joined(separator: ", "),
                    action: { activePicker = .primaryMuscle }
                )
                CustomExerciseClassificationRow(
                    label: "Other muscles",
                    value: draft.secondaryMuscles.map(CustomExerciseTaxonomyPresentation.title).joined(separator: ", "),
                    action: { activePicker = .otherMuscles }
                )
                CustomExerciseClassificationRow(
                    label: "Metrics it can log",
                    isRequired: true,
                    value: draft.metrics.map(CustomExerciseTaxonomyPresentation.title).joined(separator: ", "),
                    action: { activePicker = .metrics }
                )
                CustomExerciseClassificationRow(
                    label: "Movement pattern",
                    value: draft.patterns.map(CustomExerciseTaxonomyPresentation.title).joined(separator: ", "),
                    action: { activePicker = .movementPattern }
                )
                CustomExerciseClassificationRow(
                    label: "Tags",
                    value: draft.tags.map(\.displayName).joined(separator: ", "),
                    action: { activePicker = .tags }
                )
                CustomExerciseClassificationRow(
                    label: "Level",
                    value: CustomExerciseTaxonomyPresentation.title(draft.level.first ?? .intermediate),
                    usesDefault: draft.level.first == .intermediate,
                    action: { activePicker = .level }
                )
            }
            .padding(.horizontal, BaselineSpacing.large)
            .padding(.bottom, BaselineSpacing.screen)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BaselineColor.base.ignoresSafeArea())
        .navigationTitle("Create exercise")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", action: dismiss.callAsFunction)
                    .foregroundStyle(BaselineColor.textMid)
                    .frame(minHeight: BaselineSize.minimumTapTarget)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save", action: save)
                    .baselineTypography(.primaryAction)
                    .foregroundStyle(draft.canSave ? BaselineColor.accent : BaselineColor.textFaint)
                    .frame(minHeight: BaselineSize.minimumTapTarget)
                    .disabled(draft.canSave == false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Save exercise", action: save)
                .baselineTypography(.primaryAction)
                .foregroundStyle(BaselineColor.base)
                .frame(maxWidth: .infinity)
                .frame(height: BaselineSize.primaryActionHeight)
                .background {
                    RoundedRectangle(cornerRadius: BaselineRadius.action)
                        .fill(BaselineColor.accent.opacity(draft.canSave ? 1 : 0.35))
                }
                .disabled(draft.canSave == false)
                .padding(.horizontal, BaselineSpacing.large)
                .padding(.top, BaselineSpacing.small)
                .padding(.bottom, BaselineSpacing.xSmall)
                .background {
                    LinearGradient(
                        colors: [BaselineColor.base.opacity(0), BaselineColor.base],
                        startPoint: .top,
                        endPoint: .center
                    )
                }
        }
        .navigationDestination(item: $activePicker) { picker in
            CustomExercisePicker(kind: picker, draft: $draft)
        }
    }

    private func save() {
        guard draft.canSave else { return }
        onCreate(draft.createDefinition(in: store))
    }
}
