import SwiftUI

/// The single editing surface used by every workout draft, regardless of how it was created.
struct WorkoutTemplateEditor<TopContent: View, BottomContent: View>: View {
    @Environment(WorkoutStore.self) private var store

    @ViewBuilder let topContent: TopContent
    @ViewBuilder let bottomContent: BottomContent
    @State private var addExerciseRequest: AddExerciseRequest?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                topContent

                if let workout = store.current {
                    workoutHeader(workout)
                        .padding(.bottom, 18)

                    ForEach(workout.blocks) { block in
                        blockSection(block, blockCount: workout.blocks.count)
                    }

                    addRowButton("Add Block", systemImage: "plus.rectangle.on.rectangle", action: addBlock)
                        .padding(.top, 8)
                }

                bottomContent
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $addExerciseRequest) { request in
            AddExerciseFlow(blockID: request.id) { _ in }
        }
    }

    private func workoutHeader(_ workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Workout name", text: workoutTitleBinding)
                .font(.title2.bold())
                .foregroundStyle(BaselineColor.textHi)
                .textInputAutocapitalization(.sentences)

            TextField("Add workout notes", text: workoutGoalBinding, axis: .vertical)
                .font(.body)
                .foregroundStyle(BaselineColor.textMid)
                .lineLimit(2...6)

            TextField("Add detailed workout instructions", text: workoutGuidanceBinding, axis: .vertical)
                .font(.body)
                .foregroundStyle(BaselineColor.textMid)
                .lineLimit(2...12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private func blockSection(_ block: WorkoutBlock, blockCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if shouldShowHeader(for: block, blockCount: blockCount) {
                blockHeader(block)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
            }

            StructuredWorkoutBlockView(block: block, mode: .editTemplate)

            if block.nodes.isEmpty {
                Text("No exercises yet.")
                    .font(.subheadline)
                    .foregroundStyle(BaselineColor.textFaint)
                    .padding(.vertical, 16)
            }

            addRowButton("Add Exercise", systemImage: "plus") {
                addExerciseRequest = AddExerciseRequest(id: block.id)
            }
            .padding(.vertical, 10)
        }
    }

    private func blockHeader(_ block: WorkoutBlock) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                TextField("Block name", text: blockNameBinding(block))
                    .font(.title3.bold())
                    .foregroundStyle(BaselineColor.textHi)
                blockMenu(block)
            }

            if WorkoutPresentationFormatter.blockIntent(name: block.name, intent: block.intent) != nil {
                TextField("Block goal or intent", text: blockIntentBinding(block), axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(BaselineColor.textMid)
                    .lineLimit(1...3)
            }

            TextField("Block instructions", text: blockGuidanceBinding(block), axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(BaselineColor.textMid)
                .lineLimit(2...10)
        }
    }

    private func blockMenu(_ block: WorkoutBlock) -> some View {
        Menu("Block actions", systemImage: "ellipsis") {
            Button("Duplicate Block", systemImage: "plus.square.on.square") {
                store.edit { $0.duplicateBlock(block.id) }
            }
            Button("Delete Block", systemImage: "trash", role: .destructive) {
                store.edit { workout in
                    workout.removeBlock(block.id)
                    if workout.blocks.isEmpty {
                        workout.blocks.append(WorkoutBlock(name: "", isDefault: true))
                    }
                }
            }
        }
        .labelStyle(.iconOnly)
        .frame(width: 44, height: 44)
        .accessibilityLabel("Actions for \(block.name.isEmpty ? "Main" : block.name) block")
    }

    private func shouldShowHeader(for block: WorkoutBlock, blockCount: Int) -> Bool {
        blockCount > 1 || !block.isDefault || !block.name.isEmpty || !(block.intent?.isEmpty ?? true)
            || block.guidance != nil
    }

    private func addRowButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaselineColor.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(BaselineColor.surface))
        }
        .buttonStyle(.plain)
    }

    private func addBlock() {
        store.edit { $0.addUserBlock(name: "New Block") }
    }

    private var workoutTitleBinding: Binding<String> {
        Binding(
            get: { store.current?.title ?? "" },
            set: { value in store.edit { $0.rename(value) } }
        )
    }

    private var workoutGoalBinding: Binding<String> {
        Binding(
            get: { store.current?.goal ?? "" },
            set: { value in store.edit { $0.updateGoal(value.isEmpty ? nil : value) } }
        )
    }

    private var workoutGuidanceBinding: Binding<String> {
        Binding(
            get: { store.current?.guidance?.formCues.joined(separator: "\n\n") ?? "" },
            set: { value in
                store.edit { workout in
                    workout.updateGuidance(updatedGuidance(workout.guidance, notesText: value))
                }
            }
        )
    }

    private func blockNameBinding(_ block: WorkoutBlock) -> Binding<String> {
        Binding(
            get: { store.current?.blocks.first(where: { $0.id == block.id })?.name ?? block.name },
            set: { value in store.edit { $0.renameBlock(block.id, to: value) } }
        )
    }

    private func blockIntentBinding(_ block: WorkoutBlock) -> Binding<String> {
        Binding(
            get: { store.current?.blocks.first(where: { $0.id == block.id })?.intent ?? "" },
            set: { value in store.edit { $0.setBlockIntent(block.id, value.isEmpty ? nil : value) } }
        )
    }

    private func blockGuidanceBinding(_ block: WorkoutBlock) -> Binding<String> {
        Binding(
            get: {
                store.current?.blocks.first(where: { $0.id == block.id })?.guidance?.formCues
                    .joined(separator: "\n\n") ?? ""
            },
            set: { value in
                store.edit { workout in
                    let current = workout.blocks.first(where: { $0.id == block.id })?.guidance
                    workout.setBlockGuidance(block.id, updatedGuidance(current, notesText: value))
                }
            }
        )
    }

    private func updatedGuidance(_ current: CoachGuidance?, notesText: String) -> CoachGuidance? {
        var guidance = current ?? CoachGuidance()
        let value = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guidance.formCues = value.isEmpty ? [] : [value]
        let isEmpty = guidance.goal == nil && guidance.tempo == nil && guidance.formCues.isEmpty
            && guidance.commonMistakes.isEmpty && guidance.progressionNotes == nil
        return isEmpty ? nil : guidance
    }

    private struct AddExerciseRequest: Identifiable {
        let id: UUID
    }
}
