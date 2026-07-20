import SwiftUI

/// Drag-and-drop reordering for a workout's blocks and the exercises inside them.
///
/// The surface is deliberately two-level: blocks reorder on the root list, and tapping a block opens
/// its own list of exercises. That structure *is* the product constraint — an exercise drag is scoped
/// to one block's list and therefore cannot carry the exercise into a different block. Moving an
/// exercise across blocks stays where it already lives, behind the explicit "Move to Block" action, so
/// a slipped finger can never restructure a workout in a way the athlete did not ask for.
///
/// Rows cover *every* node kind, not just exercises. `Workout.moveNodes(inBlock:...)` moves by array
/// position, so the list has to render the same array the move operates on — hiding rests, groups, or
/// choices here would silently shift the wrong element.
///
/// During a live session every edit made here is session-scoped: `WorkoutStore` routes it to the
/// session's own workout copy and the saved plan is untouched until the athlete opts in at completion.
struct WorkoutReorderSheet: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Block queued for deletion while its confirmation dialog is up.
    @State private var blockPendingDeletion: WorkoutBlock?

    private var blocks: [WorkoutBlock] { store.current?.blocks ?? [] }

    var body: some View {
        NavigationStack {
            Group {
                if blocks.count > 1 {
                    blockList
                } else if let block = blocks.first {
                    // A single-block workout has nothing to reorder at the block level, so go straight
                    // to the exercises rather than making the athlete tap through a one-row list.
                    ExerciseReorderList(blockID: block.id)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(BaselineColor.accent)
        .confirmationDialog(
            blockPendingDeletion.map { "Delete \(Self.name(for: $0))?" } ?? "",
            isPresented: Binding(
                get: { blockPendingDeletion != nil },
                set: { if !$0 { blockPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: blockPendingDeletion
        ) { block in
            Button("Delete Block", role: .destructive) {
                store.removeBlockFromWorkout(block.id)
                blockPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { blockPendingDeletion = nil }
        } message: { block in
            Text(store.hasLoggedWork(inBlock: block.id)
                 ? "This removes the block and the sets you have already logged in it."
                 : "This removes the block and its exercises from this workout.")
        }
    }

    // MARK: - Blocks

    private var blockList: some View {
        List {
            Section {
                ForEach(blocks) { block in
                    NavigationLink {
                        ExerciseReorderList(blockID: block.id)
                    } label: {
                        blockRow(block)
                    }
                }
                .onMove { source, destination in
                    Haptics.select()
                    store.edit { $0.moveBlocks(fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    // Route through the confirmation rather than deleting on the swipe, because a
                    // block can hold logged sets that deletion discards.
                    if let index = offsets.first, blocks.indices.contains(index) {
                        blockPendingDeletion = blocks[index]
                    }
                }
            } footer: {
                Text("Drag to reorder blocks. Open a block to reorder the exercises inside it.")
                    .font(.footnote)
                    .foregroundStyle(BaselineColor.textFaint)
            }
            .listRowBackground(BaselineColor.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BaselineColor.base)
        .environment(\.editMode, .constant(.active))
    }

    private func blockRow(_ block: WorkoutBlock) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.name(for: block))
                .font(.body.weight(.semibold))
                .foregroundStyle(BaselineColor.textHi)
            Text(Self.subtitle(for: block))
                .font(.caption)
                .foregroundStyle(BaselineColor.textFaint)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Nothing to reorder")
                .font(.title3.weight(.semibold))
                .foregroundStyle(BaselineColor.textHi)
            Text("Add an exercise first, then come back to arrange the order.")
                .font(.body)
                .foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BaselineColor.base)
    }

    static func name(for block: WorkoutBlock) -> String {
        block.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Main" : block.name
    }

    private static func subtitle(for block: WorkoutBlock) -> String {
        let count = block.exercises.count
        return count == 1 ? "1 exercise" : "\(count) exercises"
    }
}

// MARK: - Exercises within one block

/// The exercise-level drag list for a single block. Reads the block back out of the store by id on
/// every render so a move made here is reflected immediately and the list never drifts from the model.
private struct ExerciseReorderList: View {
    @Environment(WorkoutStore.self) private var store

    let blockID: UUID

    private var block: WorkoutBlock? {
        store.current?.blocks.first { $0.id == blockID }
    }

    var body: some View {
        List {
            if let block, !block.nodes.isEmpty {
                Section {
                    ForEach(block.nodes) { node in
                        nodeRow(node)
                    }
                    .onMove { source, destination in
                        Haptics.select()
                        store.edit { $0.moveNodes(inBlock: blockID, fromOffsets: source, toOffset: destination) }
                    }
                } footer: {
                    Text("Drag to reorder within this block. To move an exercise to another block, use the exercise's actions menu.")
                        .font(.footnote)
                        .foregroundStyle(BaselineColor.textFaint)
                }
                .listRowBackground(BaselineColor.surface)
            } else {
                Text("This block has no exercises yet.")
                    .font(.subheadline)
                    .foregroundStyle(BaselineColor.textFaint)
                    .listRowBackground(BaselineColor.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BaselineColor.base)
        .environment(\.editMode, .constant(.active))
        .navigationTitle(block.map { WorkoutReorderSheet.name(for: $0) } ?? "Block")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
    }

    /// One row per node. Non-exercise nodes are shown (and draggable) because the underlying move is by
    /// array position — see the type comment on `WorkoutReorderSheet`.
    @ViewBuilder private func nodeRow(_ node: WorkoutNode) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.title(for: node))
                .font(.body)
                .foregroundStyle(BaselineColor.textHi)
            if let detail = Self.detail(for: node) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(BaselineColor.textFaint)
            }
        }
        .padding(.vertical, 4)
    }

    private static func title(for node: WorkoutNode) -> String {
        switch node {
        case .exercise(let exercise):
            let label = exercise.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (label?.isEmpty == false ? label : nil) ?? exercise.exerciseName
        case .group(let group): return WorkoutPresentationFormatter.groupTitle(group)
        case .rest(let rest): return rest.label.isEmpty ? "Rest" : rest.label
        case .choice(let choice): return choice.label.isEmpty ? "Choice" : choice.label
        }
    }

    private static func detail(for node: WorkoutNode) -> String? {
        switch node {
        case .exercise: return nil
        case .group(let group):
            let count = group.children.exercises.count
            return count == 1 ? "Group · 1 exercise" : "Group · \(count) exercises"
        case .rest(let rest):
            guard let seconds = rest.durationSeconds, seconds > 0 else { return "Rest" }
            return "Rest · \(seconds)s"
        case .choice(let choice):
            return "Choose \(choice.selectionCount) of \(choice.options.count)"
        }
    }
}
