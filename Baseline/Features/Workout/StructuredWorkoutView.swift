import SwiftUI

/// Renders every workout node as a flat, readable row. Nesting is communicated with indentation and
/// a slim rail rather than nested cards, so an imported circuit remains as easy to scan as five
/// ordinary exercises.
struct StructuredWorkoutBlockView: View {
    @Environment(WorkoutStore.self) private var store

    let block: WorkoutBlock
    let mode: WorkoutPresentationMode

    private var choiceSelections: [UUID: Set<UUID>] {
        Dictionary(uniqueKeysWithValues: (store.currentLog?.choices ?? []).map {
            ($0.plannedChoiceID, Set($0.selectedOptionIDs))
        })
    }

    private var items: [WorkoutDisplayItem] {
        StructuredWorkoutDisplayBuilder.items(
            nodes: block.nodes,
            mode: mode,
            choiceSelections: choiceSelections
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                WorkoutDisplayRow(item: item, blockID: block.id, mode: mode)
            }
        }
    }
}

// MARK: - Flat display model

private struct WorkoutDisplayItem: Identifiable {
    enum Kind {
        case exercise(PlannedExercise, groupID: UUID?, iteration: Int?)
        case group(WorkoutGroup, showsLogger: Bool)
        case rest(PlannedRest)
        case choice(WorkoutChoice)
        case option(String)
    }

    let id: String
    let depth: Int
    let kind: Kind
}

private enum StructuredWorkoutDisplayBuilder {
    static func items(
        nodes: [WorkoutNode],
        mode: WorkoutPresentationMode,
        choiceSelections: [UUID: Set<UUID>]
    ) -> [WorkoutDisplayItem] {
        var result: [WorkoutDisplayItem] = []
        append(
            nodes,
            depth: 0,
            mode: mode,
            choiceSelections: choiceSelections,
            to: &result
        )
        return result
    }

    private static func append(
        _ nodes: [WorkoutNode],
        depth: Int,
        mode: WorkoutPresentationMode,
        choiceSelections: [UUID: Set<UUID>],
        to result: inout [WorkoutDisplayItem]
    ) {
        for node in nodes {
            switch node {
            case .exercise(let exercise):
                result.append(item(id: exercise.id, depth: depth, kind: .exercise(exercise, groupID: nil, iteration: nil), result: result))

            case .rest(let rest):
                result.append(item(id: rest.id, depth: depth, kind: .rest(rest), result: result))

            case .group(let group):
                let showsLogger = mode.usesPerformedData && group.execution.isRepeated
                result.append(item(id: group.id, depth: depth, kind: .group(group, showsLogger: showsLogger), result: result))
                if !showsLogger {
                    append(
                        group.children,
                        depth: depth + 1,
                        mode: mode,
                        choiceSelections: choiceSelections,
                        to: &result
                    )
                }

            case .choice(let choice):
                result.append(item(id: choice.id, depth: depth, kind: .choice(choice), result: result))
                if mode.usesPerformedData {
                    let selected = choiceSelections[choice.id]
                        ?? Set(choice.options.prefix(choice.selectionCount).map(\.id))
                    append(
                        choice.options.filter { selected.contains($0.id) },
                        depth: depth + 1,
                        mode: mode,
                        choiceSelections: choiceSelections,
                        to: &result
                    )
                } else {
                    for option in choice.options {
                        result.append(item(id: option.id, depth: depth + 1, kind: .option(option.label), result: result))
                        append(
                            [option],
                            depth: depth + 2,
                            mode: mode,
                            choiceSelections: choiceSelections,
                            to: &result
                        )
                    }
                }
            }
        }
    }

    private static func item(
        id: UUID,
        depth: Int,
        kind: WorkoutDisplayItem.Kind,
        result: [WorkoutDisplayItem]
    ) -> WorkoutDisplayItem {
        WorkoutDisplayItem(
            id: "\(id.uuidString)-\(depth)-\(result.count)",
            depth: depth,
            kind: kind
        )
    }
}

private struct WorkoutDisplayRow: View {
    let item: WorkoutDisplayItem
    let blockID: UUID
    let mode: WorkoutPresentationMode

    var body: some View {
        HStack(alignment: .top, spacing: item.depth > 0 ? 10 : 0) {
            if item.depth > 0 {
                Capsule()
                    .fill(BaselineColor.accent.opacity(0.42))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
            }
            rowContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(max(item.depth - 1, 0)) * 10)
    }

    @ViewBuilder private var rowContent: some View {
        switch item.kind {
        case .exercise(let exercise, let groupID, let iteration):
            WorkoutExerciseSection(
                exercise: exercise,
                blockID: blockID,
                mode: mode,
                groupID: groupID,
                iteration: iteration
            )
        case .group(let group, let showsLogger):
            WorkoutGroupHeader(group: group, mode: mode, showsLogger: showsLogger, blockID: blockID)
        case .rest(let rest):
            WorkoutRestRow(rest: rest)
        case .choice(let choice):
            WorkoutChoiceHeader(choice: choice, mode: mode)
        case .option(let label):
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.caption2)
                    .foregroundStyle(BaselineColor.textFaint)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.textMid)
            }
            .padding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Option: \(label)")
        }
    }
}

// MARK: - Group

private struct WorkoutGroupHeader: View {
    @Environment(WorkoutStore.self) private var store

    let group: WorkoutGroup
    let mode: WorkoutPresentationMode
    let showsLogger: Bool
    let blockID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if mode.isEditing {
                    TextField("Group name", text: groupNameBinding)
                        .font(.headline)
                        .foregroundStyle(BaselineColor.textHi)
                } else {
                    Text(WorkoutPresentationFormatter.groupTitle(group))
                        .font(.headline)
                        .foregroundStyle(BaselineColor.textHi)
                }

                Spacer(minLength: 8)

                Image(systemName: group.execution.symbol)
                    .foregroundStyle(BaselineColor.textFaint)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 7) {
                if let summary = WorkoutPresentationFormatter.groupExecutionSummary(group.execution) {
                    Text(summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if group.isOptional {
                    Text("Optional").workoutChip(color: BaselineColor.textFaint)
                }
                if let dose = group.doseLayer {
                    Text(dose.rawValue.uppercased()).workoutChip(color: BaselineColor.accent)
                }
            }

            if mode.isEditing {
                groupExecutionEditor
                TextField("Add group notes", text: groupGuidanceBinding, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(BaselineColor.textMid)
                    .lineLimit(2...10)
                    .accessibilityLabel("Notes for \(group.label)")
            } else if let guidance = group.guidance {
                WorkoutInstructionText(
                    lines: [guidance.goal].compactMap { $0 } + guidance.formCues
                )
            }

            if showsLogger {
                WorkoutGroupLogger(group: group, blockID: blockID, mode: mode)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, showsLogger ? 16 : 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var groupExecutionEditor: some View {
        switch group.execution.repetition {
        case .once:
            EmptyView()
        case .count(let count):
            HStack(spacing: 12) {
                Text("Rounds").font(.subheadline).foregroundStyle(BaselineColor.textMid)
                Spacer()
                quantityButton(systemName: "minus", label: "Remove one round") {
                    updateRepetition(.count(max(1, count - 1)))
                }
                Text("\(count)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(BaselineColor.textHi)
                    .frame(minWidth: 28)
                quantityButton(systemName: "plus", label: "Add one round") {
                    updateRepetition(.count(min(500, count + 1)))
                }
            }
        case .until(let seconds):
            let step = Int(group.execution.adjustments.first(where: { $0.metric == .duration })?.step ?? 300)
            HStack(spacing: 12) {
                Text("Duration").font(.subheadline).foregroundStyle(BaselineColor.textMid)
                Spacer()
                quantityButton(systemName: "minus", label: "Reduce duration") {
                    updateRepetition(.until(seconds: max(60, seconds - step)))
                }
                Text(seconds.durationLabel)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(BaselineColor.textHi)
                    .frame(minWidth: 58)
                quantityButton(systemName: "plus", label: "Increase duration") {
                    updateRepetition(.until(seconds: seconds + step))
                }
            }
        }
    }

    private func quantityButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(BaselineColor.surface))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var groupNameBinding: Binding<String> {
        Binding(
            get: { store.current?.allGroups.first(where: { $0.id == group.id })?.label ?? group.label },
            set: { value in store.edit(mode.editScope) { $0.updateGroup(group.id) { $0.label = value } } }
        )
    }

    private var groupGuidanceBinding: Binding<String> {
        Binding(
            get: {
                store.current?.allGroups.first(where: { $0.id == group.id })?.guidance?.formCues
                    .joined(separator: "\n\n") ?? ""
            },
            set: { value in
                store.edit(mode.editScope) { workout in
                    workout.updateGroup(group.id) { updated in
                        updated.guidance = updatedGuidance(updated.guidance, notesText: value)
                    }
                }
            }
        )
    }

    private func updatedGuidance(_ current: CoachGuidance?, notesText: String) -> CoachGuidance? {
        var guidance = current ?? CoachGuidance()
        let notes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guidance.formCues = notes.isEmpty ? [] : [notes]
        let isEmpty = guidance.goal == nil && guidance.tempo == nil && guidance.formCues.isEmpty
            && guidance.commonMistakes.isEmpty && guidance.progressionNotes == nil
        return isEmpty ? nil : guidance
    }

    private func updateRepetition(_ repetition: RepetitionRule) {
        store.edit(mode.editScope) { workout in
            workout.updateGroup(group.id) { $0.execution.repetition = repetition }
        }
    }
}

private struct WorkoutGroupLogger: View {
    @Environment(WorkoutStore.self) private var store

    let group: WorkoutGroup
    let blockID: UUID
    let mode: WorkoutPresentationMode

    @State private var selectedIteration = 1

    private var groupLog: GroupLog? {
        store.currentLog?.groups.first { $0.plannedGroupID == group.id }
    }

    private var choiceSelections: [UUID: Set<UUID>] {
        Dictionary(uniqueKeysWithValues: (store.currentLog?.choices ?? []).map {
            ($0.plannedChoiceID, Set($0.selectedOptionIDs))
        })
    }

    private var iterationCount: Int {
        switch group.execution.repetition {
        case .count(let count): min(max(count, 1), 500)
        case .until:
            mode == .completed
                ? min(max(max(groupLog?.completedIterations ?? 0, maxLoggedIteration), 1), 500)
                : min(max((groupLog?.completedIterations ?? 0) + 1, 1), 500)
        case .once: 1
        }
    }

    private var maxLoggedIteration: Int {
        store.currentLog?.exercises
            .flatMap(\.setLogs)
            .filter { $0.groupID == group.id }
            .compactMap(\.iteration)
            .max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(group.children.flatMap(\.choices)) { choice in
                WorkoutChoiceHeader(choice: choice, mode: mode)
            }

            if group.execution.repetition.durationSeconds != nil {
                if mode.isLogging { durationControls } else { completedDurationSummary }
            }

            roundSelector

            ForEach(exercises(for: selectedIteration)) { exercise in
                WorkoutExerciseSection(
                    exercise: exercise,
                    blockID: blockID,
                    mode: mode,
                    groupID: group.id,
                    iteration: selectedIteration
                )
            }

            if mode.isLogging && !roundIsComplete(selectedIteration) {
                Button { complete(selectedIteration) } label: {
                    Label("Complete \(iterationLabel.lowercased())", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(BaselineColor.surface))
                }
                .buttonStyle(.plain)
            }

            if shouldShowBetweenRest(after: selectedIteration) {
                ForEach(group.children.compactMap(\.betweenRest)) { rest in
                    WorkoutRestRow(rest: rest)
                }
            }
        }
        .onChange(of: iterationCount) { _, count in
            selectedIteration = min(max(selectedIteration, 1), count)
        }
    }

    private var roundSelector: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(1...iterationCount, id: \.self) { iteration in
                    Button { selectedIteration = iteration } label: {
                        Text("\(iteration)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(roundColor(iteration))
                            .frame(minWidth: 44, minHeight: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(iteration == selectedIteration ? BaselineColor.amethyst : BaselineColor.surface)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(iterationLabel) \(iteration)")
                    .accessibilityValue(roundIsComplete(iteration) ? "Complete" : iteration == selectedIteration ? "Selected" : "Not complete")
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Choose \(iterationLabel.lowercased())")
    }

    private func roundColor(_ iteration: Int) -> Color {
        if roundIsComplete(iteration) { return BaselineColor.zoneGreen }
        if iteration == selectedIteration { return BaselineColor.accent }
        return BaselineColor.textMid
    }

    private var iterationLabel: String {
        if group.execution.cadence?.scope == .child { return "Minute" }
        if group.children.exercises.count == 1,
           group.children.exercises.first?.selectedMetrics.contains(.duration) == true {
            return "Interval"
        }
        return "Round"
    }

    private func exercises(for iteration: Int) -> [PlannedExercise] {
        let workload = group.children.filter { node in
            if case .rest = node { return false }
            return true
        }
        if group.execution.cadence?.scope == .child, !workload.isEmpty {
            return workload[(iteration - 1) % workload.count]
                .resolvedExercises(choiceSelections: choiceSelections)
        }
        return workload.flatMap { $0.resolvedExercises(choiceSelections: choiceSelections) }
    }

    private func roundIsComplete(_ iteration: Int) -> Bool {
        let plannedExercises = exercises(for: iteration)
        let setsHandled = plannedExercises.allSatisfy { planned in
            if store.currentLog?.isExerciseSkipped(
                planned.id,
                groupID: group.id,
                iteration: iteration
            ) == true {
                return true
            }
            let actual = store.currentLog?.effectiveExercise(
                for: planned,
                groupID: group.id,
                iteration: iteration
            ) ?? planned
            return actual.prescription.sets.allSatisfy { set in
                store.currentLog?.setLog(
                    forPlanned: planned.id,
                    plannedSetID: set.id,
                    groupID: group.id,
                    iteration: iteration
                )?.isHandled == true
            }
        }
        let addedSets = store.currentLog?.exercises
            .flatMap(\.setLogs)
            .filter {
                $0.plannedSetID == nil && $0.groupID == group.id && $0.iteration == iteration
            } ?? []
        if plannedExercises.isEmpty && addedSets.isEmpty {
            return (groupLog?.completedIterations ?? 0) >= iteration
        }
        return setsHandled && addedSets.allSatisfy(\.isHandled)
    }

    private func complete(_ iteration: Int) {
        let roundExercises = exercises(for: iteration)
        store.editLog { log in
            for planned in roundExercises where !log.isExerciseSkipped(
                planned.id,
                groupID: group.id,
                iteration: iteration
            ) {
                let exercise = log.effectiveExercise(
                    for: planned,
                    groupID: group.id,
                    iteration: iteration
                )
                for set in exercise.prescription.sets {
                    log.upsertSetLog(
                        forPlanned: planned.id,
                        name: exercise.exerciseName,
                        plannedSetID: set.id,
                        groupID: group.id,
                        iteration: iteration
                    ) { actual in
                        let expected = set.expectedValues(iteration: iteration)
                        for metric in exercise.selectedMetrics where actual.values[metric] == nil {
                            actual.values[metric] = expected[metric]
                        }
                        actual.completed = true
                    }
                }
            }
            log.upsertGroupLog(group.id, targetDurationSeconds: group.execution.repetition.durationSeconds) { actual in
                actual.completedIterations = max(actual.completedIterations, iteration)
                if case .count(let count) = group.execution.repetition, iteration >= count {
                    actual.isComplete = true
                }
            }
        }

        if selectedIteration < iterationCount {
            selectedIteration += 1
        } else if group.execution.repetition.durationSeconds != nil {
            selectedIteration = min(selectedIteration + 1, 500)
        }
    }

    private func shouldShowBetweenRest(after iteration: Int) -> Bool {
        guard group.children.contains(where: { $0.betweenRest != nil }) else { return false }
        return switch group.execution.repetition {
        case .count(let count): iteration < count
        case .until: true
        case .once: false
        }
    }

    private var durationControls: some View {
        let planned = group.execution.repetition.durationSeconds ?? 0
        let target = groupLog?.targetDurationSeconds ?? planned
        let step = Int(group.execution.adjustments.first(where: { $0.metric == .duration })?.step ?? 600)

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Today's target")
                    .font(.subheadline)
                    .foregroundStyle(BaselineColor.textMid)
                Spacer()
                durationButton(systemName: "minus", label: "Reduce target by \(step / 60) minutes") {
                    adjustTarget(-step)
                }
                Text(target.durationLabel)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(BaselineColor.textHi)
                    .frame(minWidth: 58)
                durationButton(systemName: "plus", label: "Increase target by \(step / 60) minutes") {
                    adjustTarget(step)
                }
            }

            HStack(spacing: 8) {
                Text("Actual time")
                    .font(.subheadline)
                    .foregroundStyle(BaselineColor.textMid)
                Spacer()
                TextField("Minutes", value: actualMinutesBinding, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(BaselineColor.textHi)
                    .frame(width: 70)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(BaselineColor.base))
                    .accessibilityLabel("Actual minutes")
                Text("min").font(.caption).foregroundStyle(BaselineColor.textFaint)
                Button(groupLog?.isComplete == true ? "Ended" : "End") { finish(defaultSeconds: target) }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(groupLog?.isComplete == true ? BaselineColor.zoneGreen : BaselineColor.accent)
                    .frame(minHeight: 44)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.surface))
    }

    private var completedDurationSummary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Planned")
                    .font(.caption)
                    .foregroundStyle(BaselineColor.textFaint)
                Text((groupLog?.targetDurationSeconds ?? group.execution.repetition.durationSeconds ?? 0).durationLabel)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(BaselineColor.textHi)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Completed")
                    .font(.caption)
                    .foregroundStyle(BaselineColor.textFaint)
                Text(groupLog?.performedDurationSeconds?.durationLabel ?? "Not logged")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(BaselineColor.zoneGreen)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.surface))
    }

    private func durationButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(BaselineColor.base))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func adjustTarget(_ delta: Int) {
        let planned = group.execution.repetition.durationSeconds
        store.editLog { log in
            log.upsertGroupLog(group.id, targetDurationSeconds: planned) {
                $0.targetDurationSeconds = max(0, ($0.targetDurationSeconds ?? planned ?? 0) + delta)
            }
        }
    }

    private var actualMinutesBinding: Binding<Int?> {
        Binding(
            get: { groupLog?.performedDurationSeconds.map { $0 / 60 } },
            set: { minutes in
                store.editLog { log in
                    log.upsertGroupLog(group.id, targetDurationSeconds: group.execution.repetition.durationSeconds) {
                        $0.performedDurationSeconds = minutes.map { max(0, $0) * 60 }
                    }
                }
            }
        )
    }

    private func finish(defaultSeconds: Int) {
        store.editLog { log in
            log.upsertGroupLog(group.id, targetDurationSeconds: group.execution.repetition.durationSeconds) {
                if $0.performedDurationSeconds == nil { $0.performedDurationSeconds = defaultSeconds }
                $0.isComplete = true
            }
        }
    }
}

// MARK: - Choice and rest

private struct WorkoutChoiceHeader: View {
    @Environment(WorkoutStore.self) private var store

    let choice: WorkoutChoice
    let mode: WorkoutPresentationMode

    private var selected: Set<UUID> {
        store.currentLog?.selectedOptions(for: choice.id) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(choice.label, systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(BaselineColor.textHi)
                Spacer()
                if mode.isEditing {
                    Menu("Choice actions", systemImage: "ellipsis") {
                        Button("Require All Exercises", systemImage: "list.bullet") {
                            store.edit(mode.editScope) { $0.convertChoiceToRequiredGroup(choice.id) }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Actions for \(choice.label)")
                } else {
                    Text("Choose \(choice.selectionCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BaselineColor.textFaint)
                }
            }

            if mode.isLogging {
                ForEach(choice.options) { option in
                    Button { select(option.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(option.id) ? BaselineColor.accent : BaselineColor.textFaint)
                            Text(option.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(BaselineColor.textHi)
                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Selects this option for the workout log")
                }
            } else if mode == .completed {
                ForEach(choice.options.filter { selected.contains($0.id) }) { option in
                    Label(option.label, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.textMid)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func select(_ optionID: UUID) {
        store.editLog {
            $0.selectOption(optionID, for: choice.id, selectionCount: choice.selectionCount)
        }
    }
}

private struct WorkoutRestRow: View {
    let rest: PlannedRest

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .foregroundStyle(BaselineColor.textFaint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(rest.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.textMid)
                if let guidance = rest.guidance, !guidance.isEmpty {
                    Text(guidance)
                        .font(.caption)
                        .foregroundStyle(BaselineColor.textFaint)
                }
            }
            Spacer()
            if let seconds = rest.durationSeconds {
                Text(seconds.durationLabel)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(BaselineColor.textHi)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Exercise and set table

private struct WorkoutExerciseSection: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(PlanStore.self) private var plan
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let exercise: PlannedExercise
    let blockID: UUID
    let mode: WorkoutPresentationMode
    var groupID: UUID?
    var iteration: Int?

    @State private var sheet: ExerciseSheet?
    @State private var showLabelEditor = false
    @State private var labelDraft = ""
    /// Raised instead of removing outright when a mid-workout true-remove would discard logged sets.
    @State private var showRemoveConfirmation = false

    private var performed: PerformedExercise? {
        store.currentLog?.performed(forPlanned: exercise.id)
    }

    private var adjustment: ExerciseLogAdjustment? {
        guard mode.usesPerformedData else { return nil }
        return store.currentLog?.exerciseAdjustment(
            for: exercise.id,
            groupID: groupID,
            iteration: iteration
        )
    }

    private var presentedExercise: PlannedExercise {
        store.currentLog?.effectiveExercise(
            for: exercise,
            groupID: groupID,
            iteration: iteration
        ) ?? exercise
    }

    private var isSkipped: Bool { adjustment?.outcome == .skipped }

    private var workoutDisplayLabel: String? {
        guard let label = presentedExercise.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return nil }
        return label
    }

    private var metrics: [MetricType] {
        if !presentedExercise.selectedMetrics.isEmpty { return presentedExercise.selectedMetrics }
        return MetricType.allCases.filter { metric in
            presentedExercise.prescription.sets.contains { $0.values[metric] != nil }
        }
    }

    private var previous: ExercisePerformance? {
        guard mode.isLogging, metrics.count <= 2,
              let definitionID = presentedExercise.definitionId else { return nil }
        return plan.previousPerformance(exerciseDefinitionID: definitionID)
    }

    private var addedSetLogs: [SetLog] {
        performed?.setLogs.filter {
            $0.plannedSetID == nil && $0.groupID == groupID && $0.iteration == iteration
        } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            exerciseHeader

            if isSkipped {
                skippedState
            } else {
                if mode.isEditing {
                    TextField("Add exercise notes", text: exerciseGuidanceBinding, axis: .vertical)
                        .font(.subheadline)
                        .foregroundStyle(BaselineColor.textMid)
                        .lineLimit(2...10)
                        .accessibilityLabel("Notes for \(presentedExercise.exerciseName)")
                    structuredTargets
                } else {
                    WorkoutInstructionText(
                        lines: WorkoutPresentationFormatter.exerciseInstructions(presentedExercise),
                        placeholder: "Add notes here..."
                    )
                }

                qualitativeTargets

                setTable

                if mode.isEditing {
                    editActions
                } else if mode.isLogging {
                    addPerformedSetButton
                }

                if mode.usesPerformedData {
                    performedNotes
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BaselineColor.line).frame(height: 1)
        }
        .sheet(item: $sheet) { destination in
            exerciseSheet(destination)
        }
        .alert("Workout label", isPresented: $showLabelEditor) {
            TextField("Optional label", text: $labelDraft)
            Button("Save", action: saveDisplayLabel)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes how the movement is labeled in this workout without renaming the exercise.")
        }
        .confirmationDialog(
            "Remove \(presentedExercise.exerciseName)?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove and Discard Sets", role: .destructive) {
                store.removeExerciseFromWorkout(exercise.id, scope: mode.editScope)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have already logged sets for this exercise. Removing it from this workout discards them.")
        }
    }

    private var exerciseHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            ExerciseThumbnailView(definition: presentedExercise.definition, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(workoutDisplayLabel ?? presentedExercise.exerciseName)
                        .font(.headline)
                        .foregroundStyle(BaselineColor.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    statusChip
                }

                if workoutDisplayLabel != nil {
                    Text(presentedExercise.exerciseName)
                        .font(.subheadline)
                        .foregroundStyle(BaselineColor.textFaint)
                }

                if presentedExercise.prescription.sets.isEmpty, !isSkipped {
                    Text("No sets")
                        .font(.caption)
                        .foregroundStyle(BaselineColor.textFaint)
                }
            }

            Spacer(minLength: 8)
            exerciseMenu
        }
    }

    @ViewBuilder private var statusChip: some View {
        if adjustment?.outcome == .skipped {
            Text("Removed").workoutChip(color: BaselineColor.zoneAmber)
        } else if adjustment?.outcome == .substituted {
            Text("Substituted").workoutChip(color: BaselineColor.accent)
        } else if groupID == nil, let status = performed?.status, status != .pending {
            let presentation = status.presentation
            Text(presentation.label)
                .workoutChip(color: presentation.color)
        }
    }

    private var skippedState: some View {
        HStack(spacing: 10) {
            Text(skippedStateLabel)
                .font(.subheadline)
                .foregroundStyle(BaselineColor.textMid)
            Spacer()
            if mode.isLogging {
                Button("Restore", action: restoreActiveAdjustment)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.accent)
                    .frame(minHeight: 44)
            }
        }
    }

    private var skippedStateLabel: String {
        guard groupID != nil else { return "Removed from this workout" }
        return adjustment?.iteration == nil ? "Removed from every round" : "Removed from this round"
    }

    private var performedNotes: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(performed?.athleteNotes ?? [], id: \.self) { note in
                Text(note)
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(BaselineColor.textMid)
            }
            if mode.isLogging {
                WorkoutNoteEntry(prompt: "Add session note…") { note in
                    store.editLog {
                        $0.addNote(note, forPlanned: exercise.id, name: presentedExercise.exerciseName)
                    }
                }
            }
        }
    }

    @ViewBuilder private var qualitativeTargets: some View {
        let targets = WorkoutPresentationFormatter.qualitativeLoadTargets(presentedExercise)
        ForEach(targets, id: \.self) { target in
            LabeledContent("Load target") {
                Text(target)
                    .foregroundStyle(BaselineColor.textHi)
            }
            .font(.subheadline)
            .foregroundStyle(BaselineColor.textMid)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var structuredTargets: some View {
        ForEach(WorkoutPresentationFormatter.structuredIntensityTargets(presentedExercise), id: \.self) { target in
            LabeledContent("Target") {
                Text(target)
                    .foregroundStyle(BaselineColor.textHi)
            }
            .font(.subheadline)
            .foregroundStyle(BaselineColor.textMid)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var setTable: some View {
        if usesScrollableSetTable {
            ScrollView(.horizontal) {
                setTableContent
                    .frame(minWidth: setTableMinimumWidth)
            }
            .scrollIndicators(.visible)
            .accessibilityHint("Swipe horizontally to review all workout metrics")
        } else {
            setTableContent
        }
    }

    private var setTableContent: some View {
        VStack(spacing: 0) {
            if !presentedExercise.prescription.sets.isEmpty {
                tableHeader
            }

            ForEach(Array(presentedExercise.prescription.sets.enumerated()), id: \.element.id) { index, set in
                setRow(index: index, set: set)
            }

            ForEach(Array(addedSetLogs.enumerated()), id: \.element.id) { offset, setLog in
                addedSetRow(index: presentedExercise.prescription.sets.count + offset, setLog: setLog)
            }
        }
    }

    private var usesScrollableSetTable: Bool {
        dynamicTypeSize.isAccessibilitySize || metrics.count > 3
    }

    private var setTableMinimumWidth: CGFloat {
        let metricColumns = CGFloat(metrics.count + (showsEffortTargetColumn ? 1 : 0)) * 88
        let previousColumn: CGFloat = previous == nil ? 0 : 88
        let completionColumn: CGFloat = mode.usesPerformedData ? 44 : 0
        return 44 + metricColumns + previousColumn + completionColumn
    }

    private var tableHeader: some View {
        HStack(spacing: 6) {
            Text("SET").frame(width: 44)
            if previous != nil { Text("PREVIOUS").frame(maxWidth: .infinity) }
            ForEach(metrics, id: \.self) { metric in
                Text(MetricFormat.columnHeader(metric, unit: store.displayUnit(metric, for: presentedExercise)))
                    .frame(maxWidth: .infinity)
            }
            if showsEffortTargetColumn {
                Text(effortTargetColumnHeader)
                    .frame(maxWidth: .infinity)
            }
            if mode.usesPerformedData {
                Image(systemName: "checkmark").frame(width: 44)
            }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(BaselineColor.textFaint)
        .padding(.bottom, 6)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func setRow(index: Int, set: PlannedSet) -> some View {
        if mode.isLogging {
            WorkoutSwipeActionRow(
                actionTitle: isSetSkipped(set) ? "Restore set" : "Remove set",
                systemImage: isSetSkipped(set) ? "arrow.uturn.backward" : "trash",
                actionColor: isSetSkipped(set) ? BaselineColor.accent : BaselineColor.zoneRed,
                action: { toggleSetSkipped(set) }
            ) {
                setRowContent(index: index, set: set)
            }
        } else {
            setRowContent(index: index, set: set)
        }
    }

    private func setRowContent(index: Int, set: PlannedSet) -> some View {
        let complete = isComplete(set)
        let skipped = isSetSkipped(set)
        let rowBackground = index.isMultiple(of: 2) ? BaselineColor.surface.opacity(0.72) : BaselineColor.base

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                setLabel(index: index, set: set)
                    .frame(width: 44)
                    .frame(minHeight: 44)

                if let previous {
                    Text(previousCell(previous, index: index))
                        .font(.caption)
                        .foregroundStyle(BaselineColor.textFaint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }

                ForEach(metrics, id: \.self) { metric in
                    metricCell(
                        set: set,
                        setNumber: index + 1,
                        metric: metric,
                        complete: complete,
                        skipped: skipped
                    )
                }

                if showsEffortTargetColumn {
                    Text(effortTargetValue(set.effortTarget))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(skipped ? BaselineColor.textFaint : BaselineColor.textHi)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityLabel(effortTargetAccessibilityLabel(set.effortTarget))
                }

                if mode.isLogging {
                    Button { skipped ? toggleSetSkipped(set) : toggle(set) } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(complete ? BaselineColor.zoneGreen : BaselineColor.surface)
                            .frame(width: 30, height: 30)
                            .overlay {
                                Image(systemName: skipped ? "arrow.uturn.backward" : "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(
                                        complete || skipped ? Color.white : BaselineColor.textFaint.opacity(0.35)
                                    )
                            }
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        skipped ? "Restore set" : complete ? "Mark set incomplete" : "Mark set complete"
                    )
                } else if mode == .completed {
                    Image(systemName: skipped ? "minus.square.fill" : complete ? "checkmark.square.fill" : "square")
                        .foregroundStyle(
                            skipped ? BaselineColor.zoneAmber : complete ? BaselineColor.zoneGreen : BaselineColor.textFaint
                        )
                        .frame(width: 44, height: 44)
                        .accessibilityLabel(skipped ? "Set removed" : complete ? "Set completed" : "Set not logged")
                }
            }

            ForEach(set.alternatives) { alternative in
                alternativeRow(set: set, alternative: alternative, skipped: skipped)
            }

            if let detail = set.detailLine(unitFor: { store.displayUnit($0, for: presentedExercise) }) {
                Text("Target: \(detail)")
                    .font(.caption)
                    .foregroundStyle(BaselineColor.textFaint)
                    .padding(.leading, 48)
                    .padding(.bottom, 5)
            }
        }
        .background(rowBackground)
        .opacity(skipped ? 0.62 : 1)
        .accessibilityValue(skipped ? "Removed" : complete ? "Completed" : "Not completed")
    }

    private func alternativeRow(
        set: PlannedSet,
        alternative: PlannedSetAlternative,
        skipped: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("OR \(alternative.label)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BaselineColor.textMid)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if mode.isEditing {
                    Menu {
                        Button(role: .destructive) {
                            removeAlternative(alternative.id, from: set.id)
                        } label: {
                            Label("Remove Alternative", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(BaselineColor.textMid)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Alternative \(alternative.label) actions")
                }
            }
            .padding(.leading, 48)

            HStack(spacing: 6) {
                Text("OR")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BaselineColor.accent)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                if previous != nil {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(BaselineColor.textFaint)
                        .frame(maxWidth: .infinity)
                }

                ForEach(metrics, id: \.self) { metric in
                    if mode.isEditing {
                        MetricField(
                            metric: metric,
                            unit: store.displayUnit(metric, for: presentedExercise),
                            accessibilityName: "Alternative \(alternative.label), \(metric.label), \(store.displayUnit(metric, for: presentedExercise).short)",
                            canonical: alternativeBinding(setID: set.id, alternativeID: alternative.id, metric: metric)
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        let value = displayValue(alternative.values[metric], metric: metric)
                        Text(value)
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(skipped ? BaselineColor.textFaint : BaselineColor.textHi)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityLabel("Alternative \(alternative.label), \(metric.label)")
                            .accessibilityValue(value)
                    }
                }

                if showsEffortTargetColumn {
                    Text("—")
                        .foregroundStyle(BaselineColor.textFaint)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityLabel("No alternative effort target")
                }
                if mode.usesPerformedData {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }

            if let detail = alternative.detailLine(unitFor: { store.displayUnit($0, for: presentedExercise) }) {
                Text("Target: \(detail)")
                    .font(.caption)
                    .foregroundStyle(BaselineColor.textFaint)
                    .padding(.leading, 48)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func addedSetRow(index: Int, setLog: SetLog) -> some View {
        if mode.isLogging {
            WorkoutSwipeActionRow(
                actionTitle: "Delete added set",
                systemImage: "trash",
                action: { deleteAddedSet(setLog.id) }
            ) {
                addedSetRowContent(index: index, setLog: setLog)
            }
        } else {
            addedSetRowContent(index: index, setLog: setLog)
        }
    }

    private func addedSetRowContent(index: Int, setLog: SetLog) -> some View {
        let rowBackground = index.isMultiple(of: 2) ? BaselineColor.surface.opacity(0.72) : BaselineColor.base

        return HStack(spacing: 6) {
            if mode.isLogging {
                Menu {
                    Button(role: .destructive) { deleteAddedSet(setLog.id) } label: {
                        Label("Delete Added Set", systemImage: "trash")
                    }
                } label: {
                    Text("\(index + 1)")
                        .font(.body.weight(.bold).monospacedDigit())
                        .foregroundStyle(BaselineColor.accent)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Added set \(index + 1) actions")
            } else {
                Text("\(index + 1)")
                    .font(.body.weight(.bold).monospacedDigit())
                    .foregroundStyle(BaselineColor.accent)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Added set \(index + 1)")
            }

            if previous != nil {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(BaselineColor.textFaint)
                    .frame(maxWidth: .infinity)
            }

            ForEach(metrics, id: \.self) { metric in
                if mode.isLogging {
                    MetricField(
                        metric: metric,
                        unit: store.displayUnit(metric, for: presentedExercise),
                        accessibilityName: "Added set \(index + 1), \(metric.label), \(store.displayUnit(metric, for: presentedExercise).short)",
                        canonical: addedSetBinding(setLogID: setLog.id, metric: metric),
                        color: setLog.completed ? BaselineColor.textFaint : BaselineColor.textHi
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Text(displayValue(setLog.values[metric], metric: metric))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(setLog.completed ? BaselineColor.textHi : BaselineColor.textFaint)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }

            if showsEffortTargetColumn {
                Text("—")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(BaselineColor.textFaint)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("No effort target")
            }

            if mode.isLogging {
                Button { toggleAddedSet(setLog.id) } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(setLog.completed ? BaselineColor.zoneGreen : BaselineColor.surface)
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(setLog.completed ? Color.white : BaselineColor.textFaint.opacity(0.35))
                        }
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(setLog.completed ? "Mark added set incomplete" : "Mark added set complete")
            } else if mode == .completed {
                Image(systemName: setLog.completed ? "checkmark.square.fill" : "square")
                    .foregroundStyle(setLog.completed ? BaselineColor.zoneGreen : BaselineColor.textFaint)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(setLog.completed ? "Added set completed" : "Added set not completed")
            }
        }
        .background(rowBackground)
    }

    @ViewBuilder private func setLabel(index: Int, set: PlannedSet) -> some View {
        if mode.isEditing {
            Menu {
                ForEach(SetRole.allCases, id: \.self) { role in
                    Button {
                        store.edit(mode.editScope) { $0.updateSet(set.id) { $0.role = role } }
                    } label: {
                        Label(role.fullLabel, systemImage: set.role == role ? "checkmark" : role.symbol)
                    }
                }
                Divider()
                Button { duplicateSet(set.id) } label: {
                    Label("Duplicate Set", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) { deleteSet(set.id) } label: {
                    Label("Delete Set", systemImage: "trash")
                }
            } label: {
                setMarker(index: index, role: set.role)
            }
        } else {
            setMarker(index: index, role: set.role)
        }
    }

    private func setMarker(index: Int, role: SetRole) -> some View {
        Text(role.marker(defaultNumber: index + 1))
            .font(.body.weight(.bold).monospacedDigit())
            .foregroundStyle(role.color)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Set \(index + 1), \(role.fullLabel)")
    }

    private var showsEffortTargetColumn: Bool {
        presentedExercise.prescription.sets.contains { $0.effortTarget != nil }
    }

    private var effortTargetColumnHeader: String {
        let targets = presentedExercise.prescription.sets.compactMap(\.effortTarget)
        let onlyRPE = targets.allSatisfy {
            if case .rpe = $0 { return true }
            return false
        }
        return onlyRPE && !metrics.contains(.rpe) ? "RPE" : "TARGET"
    }

    private func effortTargetValue(_ target: EffortTarget?) -> String {
        guard let target else { return "—" }
        return switch target {
        case .rpe(let value): value.formatted()
        case .rir(let value): "\(value.formatted()) RIR"
        case .toFailure: "Failure"
        case .maxEffort: "Max"
        }
    }

    private func effortTargetAccessibilityLabel(_ target: EffortTarget?) -> String {
        guard let target else { return "No effort target" }
        return switch target {
        case .rpe(let value): "Target RPE \(value.formatted())"
        case .rir(let value): "Target \(value.formatted()) reps in reserve"
        case .toFailure: "Target to failure"
        case .maxEffort: "Target maximum effort"
        }
    }

    @ViewBuilder private func metricCell(
        set: PlannedSet,
        setNumber: Int,
        metric: MetricType,
        complete: Bool,
        skipped: Bool
    ) -> some View {
        switch mode {
        case .view:
            let value = displayValue(set.expectedValues(iteration: iteration ?? 1)[metric], metric: metric)
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(skipped ? BaselineColor.textFaint : BaselineColor.textHi)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("Set \(setNumber), \(metric.label), \(store.displayUnit(metric, for: presentedExercise).short)")
                .accessibilityValue(value)

        case .editTemplate:
            MetricField(
                metric: metric,
                unit: store.displayUnit(metric, for: presentedExercise),
                accessibilityName: "Set \(setNumber), \(metric.label), \(store.displayUnit(metric, for: presentedExercise).short)",
                canonical: planBinding(set: set, metric: metric)
            )
            .frame(maxWidth: .infinity, minHeight: 44)

        case .log:
            MetricField(
                metric: metric,
                unit: store.displayUnit(metric, for: presentedExercise),
                placeholder: displayValue(set.expectedValues(iteration: iteration ?? 1)[metric], metric: metric),
                accessibilityName: "Set \(setNumber), \(metric.label), \(store.displayUnit(metric, for: presentedExercise).short)",
                canonical: logBinding(set: set, metric: metric),
                color: complete || skipped ? BaselineColor.textFaint : BaselineColor.textHi
            )
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(skipped)

        case .completed:
            let value = displayValue(loggedValue(set: set, metric: metric), metric: metric)
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(complete && !skipped ? BaselineColor.textHi : BaselineColor.textFaint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("Set \(setNumber), \(metric.label), \(store.displayUnit(metric, for: presentedExercise).short)")
                .accessibilityValue(value)
        }
    }

    private var editActions: some View {
        Button { addSet() } label: {
            Label("Add Set", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaselineColor.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(BaselineColor.surface.opacity(0.45))
        }
        .buttonStyle(.plain)
    }

    private var addPerformedSetButton: some View {
        Button { addPerformedSet() } label: {
            Label("Add Set", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaselineColor.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(BaselineColor.surface.opacity(0.45))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adds a set to this log without changing the workout template")
    }

    private var exerciseMenu: some View {
        Menu {
            Button { sheet = .history(presentedExercise) } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

            if mode.isEditing {
                Button {
                    labelDraft = presentedExercise.displayLabel ?? ""
                    showLabelEditor = true
                } label: {
                    Label("Edit Workout Label", systemImage: "character.cursor.ibeam")
                }
                Button { sheet = .substituteTemplate(exercise.id, exercise.exerciseName) } label: {
                    Label("Replace Exercise", systemImage: "arrow.triangle.2.circlepath")
                }
                Button { sheet = .configure(exercise.id, exercise.exerciseName, .metrics) } label: {
                    Label("Metrics", systemImage: "slider.horizontal.3")
                }
                Button { sheet = .configure(exercise.id, exercise.exerciseName, .units) } label: {
                    Label("Units", systemImage: "ruler")
                }

                let otherBlocks = (store.current?.blocks ?? []).filter { $0.id != blockID }
                if !otherBlocks.isEmpty {
                    Menu {
                        ForEach(otherBlocks) { block in
                            Button(block.name.isEmpty ? "Main" : block.name) {
                                store.edit(mode.editScope) { $0.moveExercise(exercise.id, toBlock: block.id) }
                            }
                        }
                    } label: {
                        Label("Move to Block", systemImage: "arrow.up.arrow.down")
                    }
                }

                Button { store.edit(mode.editScope) { $0.duplicateExercise(exercise.id) } } label: {
                    Label("Duplicate Exercise", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) { store.edit(mode.editScope) { $0.removeExercise(exercise.id) } } label: {
                    Label("Remove Exercise", systemImage: "trash")
                }
            } else if mode.isLogging {
                if let groupID, let iteration {
                    Button { sheet = .substituteLog(exercise.id, presentedExercise.exerciseName, groupID, iteration) } label: {
                        Label("Replace This Round", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button { sheet = .substituteLog(exercise.id, presentedExercise.exerciseName, groupID, nil) } label: {
                        Label("Replace All Rounds", systemImage: "repeat")
                    }
                    Divider()
                    Button(role: .destructive) { removeExercise(groupID: groupID, iteration: iteration) } label: {
                        Label("Remove This Round", systemImage: "trash")
                    }
                    Button(role: .destructive) { removeExercise(groupID: groupID, iteration: nil) } label: {
                        Label("Remove All Rounds", systemImage: "trash.slash")
                    }
                } else {
                    Button { sheet = .substituteLog(exercise.id, presentedExercise.exerciseName, nil, nil) } label: {
                        Label("Replace Exercise", systemImage: "arrow.triangle.2.circlepath")
                    }
                    // Mid-workout prescription and logging-config edits. These change what the workout
                    // asks for (not what was logged), apply to this session only, and are what the
                    // completion "update your template?" prompt offers to promote to the plan.
                    Button { sheet = .prescription(exercise.id) } label: {
                        Label("Edit Sets & Targets", systemImage: "slider.horizontal.below.rectangle")
                    }
                    Button { sheet = .configure(exercise.id, exercise.exerciseName, .metrics) } label: {
                        Label("Metrics", systemImage: "slider.horizontal.3")
                    }
                    Button { sheet = .configure(exercise.id, exercise.exerciseName, .units) } label: {
                        Label("Units", systemImage: "ruler")
                    }
                    Divider()
                    // A true structural removal from this session — not the reversible skip. It also
                    // purges any logged sets, so completion can't resurrect work for an exercise the
                    // athlete removed. Confirmed first when there is real logged work to lose.
                    Button(role: .destructive) {
                        if store.hasLoggedWork(forExercise: exercise.id) {
                            showRemoveConfirmation = true
                        } else {
                            store.removeExerciseFromWorkout(exercise.id, scope: mode.editScope)
                        }
                    } label: {
                        Label("Remove from This Workout", systemImage: "trash")
                    }
                }

                if let adjustment, adjustment.outcome != .original {
                    Divider()
                    Button(action: restoreActiveAdjustment) {
                        Label(
                            adjustment.iteration == nil && groupID != nil
                                ? "Restore All Rounds"
                                : adjustment.iteration != nil
                                    ? "Restore This Round"
                                    : "Restore Exercise",
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(BaselineColor.textFaint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(presentedExercise.exerciseName)")
    }

    private func saveDisplayLabel() {
        let value = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.edit(mode.editScope) { workout in
            workout.updateExercise(exercise.id) { planned in
                planned.displayLabel = value.isEmpty ? nil : value
            }
        }
    }

    private var exerciseGuidanceBinding: Binding<String> {
        Binding(
            get: {
                store.current?.exercise(exercise.id)?.guidance?.formCues
                    .joined(separator: "\n\n") ?? ""
            },
            set: { value in
                store.edit(mode.editScope) { workout in
                    workout.updateExercise(exercise.id) { updated in
                        updated.guidance = updatedGuidance(updated.guidance, notesText: value)
                    }
                }
            }
        )
    }

    private func updatedGuidance(_ current: CoachGuidance?, notesText: String) -> CoachGuidance? {
        var guidance = current ?? CoachGuidance()
        let notes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guidance.formCues = notes.isEmpty ? [] : [notes]
        let isEmpty = guidance.goal == nil && guidance.tempo == nil && guidance.formCues.isEmpty
            && guidance.commonMistakes.isEmpty && guidance.progressionNotes == nil
        return isEmpty ? nil : guidance
    }

    @ViewBuilder private func exerciseSheet(_ destination: ExerciseSheet) -> some View {
        switch destination {
        case .history(let exercise):
            ExerciseHistoryView(exercise: exercise)
        case .substituteTemplate(let id, let current):
            SubstituteExerciseFlow(currentName: current) { definition in
                store.replaceExercise(id, with: definition, scope: mode.editScope)
            }
        case .substituteLog(_, let current, let targetGroupID, let targetIteration):
            SubstituteExerciseFlow(currentName: current) { definition in
                substituteForLog(
                    definition,
                    groupID: targetGroupID,
                    iteration: targetIteration
                )
            }
        case .configure(let id, let name, let focus):
            if let current = store.current?.exercise(id) {
                MetricConfigSheet(
                    exercise: current,
                    focus: focus,
                    unitFor: { store.displayUnit($0, for: current) },
                    onSetDefault: { enabled, units in
                        store.setExercisePreference(
                            exerciseNamed: name,
                            scope: .exercise,
                            units: units,
                            selected: enabled
                        )
                    }
                ) { enabled, units in
                    store.setLoggingConfig(exerciseID: id, enabled: enabled, units: units, scope: mode.editScope)
                }
            }
        case .prescription(let id):
            EditPrescriptionSheet(exerciseID: id)
        }
    }

    private func substituteForLog(
        _ definition: ExerciseDefinition,
        groupID targetGroupID: UUID?,
        iteration targetIteration: Int?
    ) {
        let supported = Set(definition.supported)
        var selectedMetrics = presentedExercise.selectedMetrics.filter { supported.contains($0) }
        if selectedMetrics.isEmpty { selectedMetrics = definition.defaults }
        let substitution = LoggedExerciseSubstitution(
            exerciseName: definition.name,
            definitionId: definition.id == ExerciseCatalog.generic.id ? nil : definition.id,
            selectedMetrics: selectedMetrics,
            displayUnits: presentedExercise.displayUnits.filter { supported.contains($0.key) },
            prescription: presentedExercise.prescription
        )
        store.editLog {
            $0.setExerciseAdjustment(
                plannedExerciseID: exercise.id,
                groupID: targetGroupID,
                iteration: targetIteration,
                outcome: .substituted,
                substitution: substitution,
                name: exercise.exerciseName
            )
        }
    }

    private func removeExercise(groupID targetGroupID: UUID?, iteration targetIteration: Int?) {
        store.editLog {
            $0.setExerciseAdjustment(
                plannedExerciseID: exercise.id,
                groupID: targetGroupID,
                iteration: targetIteration,
                outcome: .skipped,
                name: exercise.exerciseName
            )
        }
    }

    private func restoreActiveAdjustment() {
        guard let adjustment else { return }
        store.editLog {
            $0.restoreExercise(
                plannedExerciseID: exercise.id,
                groupID: adjustment.groupID,
                iteration: adjustment.iteration,
                name: exercise.exerciseName
            )
        }
    }

    private func displayValue(_ value: Double?, metric: MetricType) -> String {
        guard let value else { return "—" }
        return MetricFormat.editText(value, metric, unit: store.displayUnit(metric, for: presentedExercise))
    }

    private func loggedValue(set: PlannedSet, metric: MetricType) -> Double? {
        store.currentLog?.setLog(
            forPlanned: exercise.id,
            plannedSetID: set.id,
            groupID: groupID,
            iteration: iteration
        )?.values[metric]
    }

    private func previousCell(_ previous: ExercisePerformance, index: Int) -> String {
        guard index < previous.sets.count else { return "—" }
        let values = previous.sets[index]
        let parts = metrics.compactMap { metric -> String? in
            guard let value = values[metric] else { return nil }
            return MetricFormat.editText(value, metric, unit: store.displayUnit(metric, for: presentedExercise))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " × ")
    }

    private func planBinding(set: PlannedSet, metric: MetricType) -> Binding<Double?> {
        Binding(
            get: {
                store.current?.exercise(exercise.id)?.prescription.sets
                    .first(where: { $0.id == set.id })?.values[metric]
            },
            set: { value in
                store.edit(mode.editScope) { workout in
                    workout.updateSet(set.id) { $0.values[metric] = value.map { max(0, $0) } }
                }
            }
        )
    }

    private func alternativeBinding(
        setID: UUID,
        alternativeID: UUID,
        metric: MetricType
    ) -> Binding<Double?> {
        Binding(
            get: {
                store.current?.exercise(exercise.id)?.prescription.sets
                    .first(where: { $0.id == setID })?.alternatives
                    .first(where: { $0.id == alternativeID })?.values[metric]
            },
            set: { value in
                store.edit(mode.editScope) { workout in
                    workout.updateSet(setID) { set in
                        guard let index = set.alternatives.firstIndex(where: { $0.id == alternativeID }) else { return }
                        set.alternatives[index].values[metric] = value.map { max(0, $0) }
                    }
                }
            }
        )
    }

    private func logBinding(set: PlannedSet, metric: MetricType) -> Binding<Double?> {
        Binding(
            get: {
                store.currentLog?.setLog(
                    forPlanned: exercise.id,
                    plannedSetID: set.id,
                    groupID: groupID,
                    iteration: iteration
                )?.values[metric]
            },
            set: { value in
                store.editLog { log in
                    log.upsertSetLog(
                        forPlanned: exercise.id,
                        name: presentedExercise.exerciseName,
                        plannedSetID: set.id,
                        groupID: groupID,
                        iteration: iteration
                    ) { actual in
                        actual.values[metric] = value.map { max(0, $0) }
                    }
                }
            }
        )
    }

    private func addedSetBinding(setLogID: UUID, metric: MetricType) -> Binding<Double?> {
        Binding(
            get: {
                store.currentLog?.performed(forPlanned: exercise.id)?.setLogs
                    .first(where: { $0.id == setLogID })?.values[metric]
            },
            set: { value in
                store.editLog { log in
                    log.updateSetLog(setLogID) {
                        $0.values[metric] = value.map { max(0, $0) }
                    }
                }
            }
        )
    }

    private func isComplete(_ set: PlannedSet) -> Bool {
        guard mode.usesPerformedData else { return false }
        return store.currentLog?.setLog(
            forPlanned: exercise.id,
            plannedSetID: set.id,
            groupID: groupID,
            iteration: iteration
        )?.completed ?? false
    }

    private func isSetSkipped(_ set: PlannedSet) -> Bool {
        guard mode.usesPerformedData else { return false }
        return store.currentLog?.setLog(
            forPlanned: exercise.id,
            plannedSetID: set.id,
            groupID: groupID,
            iteration: iteration
        )?.outcome == .skipped
    }

    private func toggleSetSkipped(_ set: PlannedSet) {
        store.editLog { log in
            let existing = log.setLog(
                forPlanned: exercise.id,
                plannedSetID: set.id,
                groupID: groupID,
                iteration: iteration
            )
            log.upsertSetLog(
                forPlanned: exercise.id,
                name: presentedExercise.exerciseName,
                plannedSetID: set.id,
                groupID: groupID,
                iteration: iteration
            ) {
                $0.outcome = existing?.outcome == .skipped ? .pending : .skipped
            }
            updateTopLevelStatus(in: &log)
        }
    }

    private func toggle(_ set: PlannedSet) {
        store.editLog { log in
            let existing = log.setLog(
                forPlanned: exercise.id,
                plannedSetID: set.id,
                groupID: groupID,
                iteration: iteration
            )
            log.upsertSetLog(
                forPlanned: exercise.id,
                name: presentedExercise.exerciseName,
                plannedSetID: set.id,
                groupID: groupID,
                iteration: iteration
            ) { actual in
                if existing?.completed != true {
                    let expected = set.expectedValues(iteration: iteration ?? 1)
                    for metric in metrics where actual.values[metric] == nil {
                        actual.values[metric] = expected[metric]
                    }
                }
                actual.completed = !(existing?.completed ?? false)
            }

            updateTopLevelStatus(in: &log)
        }
    }

    private func addPerformedSet() {
        let values = addedSetLogs.last?.values
            ?? presentedExercise.prescription.sets.last?.expectedValues(iteration: iteration ?? 1)
            ?? MetricValues()
        let added = SetLog(
            plannedSetID: nil,
            groupID: groupID,
            iteration: iteration,
            values: values
        )
        store.editLog { log in
            log.logSet(added, forPlanned: exercise.id, name: presentedExercise.exerciseName)
            if groupID == nil {
                log.setStatus(.modified, forPlanned: exercise.id, name: presentedExercise.exerciseName)
            }
        }
    }

    private func toggleAddedSet(_ setLogID: UUID) {
        store.editLog { log in
            log.updateSetLog(setLogID) { $0.completed.toggle() }
            updateTopLevelStatus(in: &log)
        }
    }

    private func deleteAddedSet(_ setLogID: UUID) {
        store.editLog { log in
            log.removeSetLog(setLogID)
            updateTopLevelStatus(in: &log)
        }
    }

    private func updateTopLevelStatus(in log: inout WorkoutLog) {
        guard groupID == nil else { return }
        if let adjustment = log.exerciseAdjustment(for: exercise.id) {
            if adjustment.outcome == .skipped {
                log.setStatus(.skipped, forPlanned: exercise.id, name: presentedExercise.exerciseName)
                return
            }
            if adjustment.outcome == .substituted {
                log.setStatus(.substituted, forPlanned: exercise.id, name: presentedExercise.exerciseName)
                return
            }
        }
        let setIDs = presentedExercise.prescription.sets.map(\.id)
        let setLogs = setIDs.compactMap { log.setLog(forPlanned: exercise.id, plannedSetID: $0) }
        let plannedHandled = !setIDs.isEmpty && setIDs.allSatisfy {
            log.setLog(forPlanned: exercise.id, plannedSetID: $0)?.isHandled == true
        }
        let anySkipped = setLogs.contains { $0.outcome == .skipped }
        let added = log.performed(forPlanned: exercise.id)?.setLogs.filter {
            $0.plannedSetID == nil && $0.groupID == nil && $0.iteration == nil
        } ?? []
        let addedComplete = added.allSatisfy(\.completed)
        let status: PerformedStatus
        if plannedHandled && addedComplete && !anySkipped {
            status = .completed
        } else if anySkipped || !added.isEmpty {
            status = .modified
        } else {
            status = .pending
        }
        log.setStatus(status, forPlanned: exercise.id, name: presentedExercise.exerciseName)
    }

    private func addSet() {
        store.edit(mode.editScope) { workout in
            workout.updateExercise(exercise.id) { planned in
                var copy = planned.prescription.sets.last ?? PlannedSet()
                copy.id = UUID()
                planned.prescription.sets.append(copy)
            }
        }
    }

    private func duplicateSet(_ setID: UUID) {
        store.edit(mode.editScope) { workout in
            workout.updateExercise(exercise.id) { planned in
                guard let index = planned.prescription.sets.firstIndex(where: { $0.id == setID }) else { return }
                var copy = planned.prescription.sets[index]
                copy.id = UUID()
                planned.prescription.sets.insert(copy, at: index + 1)
            }
        }
    }

    private func deleteSet(_ setID: UUID) {
        store.edit(mode.editScope) { workout in
            workout.updateExercise(exercise.id) {
                $0.prescription.sets.removeAll { $0.id == setID }
            }
        }
    }

    private func removeAlternative(_ alternativeID: UUID, from setID: UUID) {
        store.edit(mode.editScope) { workout in
            workout.updateSet(setID) { set in
                set.alternatives.removeAll { $0.id == alternativeID }
            }
        }
    }

}

private enum ExerciseSheet: Identifiable {
    case history(PlannedExercise)
    case substituteTemplate(UUID, String)
    case substituteLog(UUID, String, UUID?, Int?)
    case configure(UUID, String, MetricConfigFocus)
    case prescription(UUID)

    var id: String {
        switch self {
        case .history(let exercise): "history-\(exercise.id)"
        case .substituteTemplate(let id, _): "substitute-template-\(id)"
        case .substituteLog(let id, _, let groupID, let iteration):
            "substitute-log-\(id)-\(groupID?.uuidString ?? "top")-\(iteration.map(String.init) ?? "all")"
        case .configure(let id, _, let focus): "configure-\(id)-\(focus)"
        case .prescription(let id): "prescription-\(id)"
        }
    }
}

private struct WorkoutNoteEntry: View {
    let prompt: String
    let onSubmit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(prompt, text: $text)
                .font(.body)
                .foregroundStyle(BaselineColor.textHi)
                .onSubmit(submit)
            if !text.isEmpty {
                Button("Add", action: submit)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
    }

    private func submit() {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        onSubmit(note)
        text = ""
    }
}

// MARK: - Presentation helpers

private extension WorkoutNode {
    var label: String {
        switch self {
        case .exercise(let exercise): exercise.exerciseName
        case .group(let group): group.label
        case .rest(let rest): rest.label
        case .choice(let choice): choice.label
        }
    }

    var betweenRest: PlannedRest? {
        guard case .rest(let rest) = self, rest.placement == .betweenRepetitions else { return nil }
        return rest
    }
}

private extension GroupExecution {
    var isRepeated: Bool {
        switch repetition {
        case .once: false
        case .count(let count): count > 1
        case .until: true
        }
    }

    var symbol: String {
        if cadence != nil { return "metronome" }
        if repetition.durationSeconds != nil { return "timer" }
        if repetition.fixedCount != nil { return "repeat" }
        return "list.bullet"
    }
}

private extension PlannedSet {
    func detailLine(unitFor: (MetricType) -> MetricUnit) -> String? {
        var details: [String] = []
        for range in ranges {
            let unit = unitFor(range.metric)
            let lower = MetricFormat.value(range.lower, range.metric, unit: unit)
            let upper = MetricFormat.value(range.upper, range.metric, unit: unit)
            details.append("\(lower)–\(upper)")
        }
        for progression in progressions {
            // `MetricFormat.value` converts from canonical itself, so the magnitude handed to it must
            // stay canonical — converting first made a +400 m progression read "+0 mi".
            let unit = unitFor(progression.metric)
            let value = MetricFormat.value(abs(progression.delta), progression.metric, unit: unit)
            details.append("\(progression.delta >= 0 ? "+" : "−")\(value) every \(progression.every) \(progression.unit.rawValue)")
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }
}

private extension PlannedSetAlternative {
    func detailLine(unitFor: (MetricType) -> MetricUnit) -> String? {
        let details = ranges.map { range in
            let unit = unitFor(range.metric)
            let lower = MetricFormat.value(range.lower, range.metric, unit: unit)
            let upper = MetricFormat.value(range.upper, range.metric, unit: unit)
            return "\(lower)–\(upper)"
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }
}

private extension SetRole {
    var fullLabel: String {
        switch self {
        case .warmup: "Warm-up"
        case .working: "Working"
        case .top: "Top set"
        case .backoff: "Back-off"
        case .drop: "Drop set"
        }
    }

    var symbol: String {
        switch self {
        case .warmup: "flame"
        case .working: "circle"
        case .top: "bolt.fill"
        case .backoff: "arrow.down.right"
        case .drop: "arrow.down"
        }
    }

    var color: Color {
        switch self {
        case .warmup: BaselineColor.zoneAmber
        case .working: BaselineColor.textHi
        case .top: BaselineColor.accent
        case .backoff: BaselineColor.zoneBlue
        case .drop: BaselineColor.zoneRed
        }
    }

    func marker(defaultNumber: Int) -> String {
        switch self {
        case .warmup: "W"
        case .working: "\(defaultNumber)"
        case .top: "T"
        case .backoff: "B"
        case .drop: "D"
        }
    }
}

private extension PerformedStatus {
    var presentation: (label: String, color: Color) {
        switch self {
        case .pending: ("", BaselineColor.textFaint)
        case .completed: ("Done", BaselineColor.zoneGreen)
        case .skipped: ("Skipped", BaselineColor.zoneAmber)
        case .substituted: ("Subbed", BaselineColor.accent)
        case .modified: ("Modified", BaselineColor.accent)
        }
    }
}

private extension Int {
    var durationLabel: String {
        if self % 60 == 0 { return "\(self / 60) min" }
        return Duration.seconds(self).formatted(.time(pattern: .minuteSecond))
    }
}

private extension View {
    func workoutChip(color: Color) -> some View {
        font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
