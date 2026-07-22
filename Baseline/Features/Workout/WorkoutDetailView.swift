import SwiftUI

struct WorkoutDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlanStore.self) private var plan
    @Environment(AppSettings.self) private var settings

    let scheduledWorkoutID: UUID

    @State private var showActions = false
    @State private var pendingAction: DetailAction?
    @State private var editContext: EditContext?
    @State private var editingBuffer: WorkoutStore?
    @State private var editingOriginal: Workout?
    @State private var queuedDeleteAfterEdit = false
    @State private var deleteProposalID: UUID?
    @State private var showDeleteConfirmation = false
    @State private var showTemplateSaved = false

    private struct EditContext: Identifiable {
        let id: UUID
        let store: WorkoutStore
    }

    private enum DetailAction {
        case edit
        case saveTemplate
        case delete
    }

    private struct ZoneSummary: Identifiable {
        let zone: Int
        let seconds: Double
        var id: Int { zone }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()

                if let scheduled, let workout = effectiveWorkout {
                    ScrollView {
                        VStack(alignment: .leading, spacing: BaselineSpacing.large) {
                            detailHeader(scheduled: scheduled, workout: workout)
                            muscleMapCard(workout: workout)

                            if heartRateSamples.isEmpty == false {
                                heartRateCard
                            }

                            if zoneSummaries.contains(where: { $0.seconds > 0 }) {
                                zonesCard
                            }

                            InstrumentLabel("EXERCISES", tracking: 1.2)
                                .padding(.top, BaselineSpacing.xxSmall)

                            ForEach(workout.allExercises) { exercise in
                                WorkoutDetailExerciseSection(
                                    planned: exercise,
                                    performed: performedExercise(for: exercise)
                                )
                            }

                            if workout.allExercises.isEmpty {
                                Text("No exercises in this workout.")
                                    .font(.subheadline)
                                    .foregroundStyle(BaselineColor.textMid)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, BaselineSpacing.large)
                        .padding(.vertical, BaselineSpacing.large)
                        .padding(.bottom, BaselineSpacing.screen)
                    }
                } else {
                    ContentUnavailableView(
                        "Workout unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This workout may have been removed.")
                    )
                    .foregroundStyle(BaselineColor.textMid)
                }
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left", action: dismiss.callAsFunction)
                        .foregroundStyle(BaselineColor.textMid)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("More", systemImage: "ellipsis", action: { showActions = true })
                        .labelStyle(.iconOnly)
                        .foregroundStyle(BaselineColor.textMid)
                        .frame(width: BaselineSize.minimumTapTarget, height: BaselineSize.minimumTapTarget)
                }
            }
        }
        .sheet(isPresented: $showActions, onDismiss: runPendingAction) {
            WorkoutDetailActionSheet(
                onEdit: { choose(.edit) },
                onSaveTemplate: { choose(.saveTemplate) },
                onDelete: { choose(.delete) },
                onCancel: { showActions = false }
            )
            .presentationDetents([.height(BaselineSize.actionSheetHeight)])
            .presentationDragIndicator(.visible)
            .presentationBackground(BaselineColor.surface)
        }
        .sheet(item: $editContext, onDismiss: finishEditing) { context in
            WorkoutView(onRequestDelete: {
                queuedDeleteAfterEdit = true
                editContext = nil
            })
            .environment(context.store)
        }
        .alert("Delete workout?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: confirmDelete)
            Button("Cancel", role: .cancel) {
                deleteProposalID = nil
            }
        } message: {
            Text("This removes the workout from your plan. You can undo it from Plan.")
        }
        .alert("Template saved", isPresented: $showTemplateSaved) {
        } message: {
            Text("A reusable copy of this workout is now available from Plan.")
        }
    }

    private var scheduled: ScheduledWorkout? { plan.scheduledWorkout(scheduledWorkoutID) }
    private var session: WorkoutSession? { plan.session(for: scheduledWorkoutID) }
    private var completed: CompletedWorkoutLog? { plan.completed(for: scheduledWorkoutID) }
    private var log: WorkoutLog? { completed?.log ?? session?.log }
    private var effectiveWorkout: Workout? { session?.workout ?? scheduled?.workout }

    private func detailHeader(scheduled: ScheduledWorkout, workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: BaselineSpacing.small) {
            Text(scheduled.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.caption.monospaced().weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(BaselineColor.textFaint)
                .textCase(.uppercase)

            Text(workout.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(BaselineColor.textHi)

            HStack(spacing: BaselineSpacing.screen) {
                detailStat("DURATION", value: detailDuration(scheduled))
                detailStat("EXERCISES", value: "\(workout.allExercises.count)")
                detailStat("SETS", value: "\(detailSetCount(workout))")
            }
            .padding(.top, BaselineSpacing.xxSmall)
        }
    }

    private func detailStat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: BaselineSpacing.xxSmall) {
            Text(label)
                .font(.caption2.monospaced().weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(BaselineColor.textFaint)
            Text(value)
                .font(.headline.monospaced().weight(.bold))
                .foregroundStyle(BaselineColor.textHi)
        }
        .accessibilityElement(children: .combine)
    }

    private func muscleMapCard(workout: Workout) -> some View {
        BaselineCard {
            VStack(alignment: .leading, spacing: BaselineSpacing.small) {
                InstrumentLabel("MUSCLE MAP", tracking: 1)
                MuscleMapView(workouts: [workout])
                HStack(spacing: BaselineSpacing.xSmall) {
                    Text("touched")
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [BaselineColor.accent.opacity(0.18), BaselineColor.accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: BaselineSize.minimumTapTarget - BaselineSpacing.small, height: BaselineSpacing.compact)
                    Text("worked hard")
                }
                .font(.caption2)
                .foregroundStyle(BaselineColor.textFaint)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)
            }
        }
    }

    private var heartRateCard: some View {
        BaselineCard {
            VStack(alignment: .leading, spacing: BaselineSpacing.xSmall) {
                HStack {
                    InstrumentLabel("HEART RATE", tracking: 1)
                    Spacer()
                    Text(heartRateSummary)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(BaselineColor.textFaint)
                }
                WorkoutHeartRateChart(samples: heartRateSamples)
            }
        }
    }

    private var zonesCard: some View {
        BaselineCard {
            VStack(alignment: .leading, spacing: BaselineSpacing.small) {
                InstrumentLabel("HEART RATE ZONES", tracking: 1)
                ForEach(zoneSummaries.sorted { $0.zone > $1.zone }) { summary in
                    HStack(spacing: BaselineSpacing.small) {
                        Text("Z\(summary.zone)")
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(zoneColor(summary.zone))
                            .frame(width: BaselineSpacing.screen, alignment: .leading)

                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(BaselineColor.line)
                                Capsule()
                                    .fill(zoneColor(summary.zone))
                                    .frame(width: geometry.size.width * zoneFraction(summary.seconds))
                            }
                        }
                        .frame(height: BaselineSpacing.xxxSmall)

                        Text(MetricFormat.durationLong(summary.seconds))
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(BaselineColor.textHi)
                            .frame(width: BaselineSize.minimumTapTarget, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var heartRateSamples: [Double] {
        let performed = log?.exercises.flatMap(\.setLogs).compactMap { $0.values[.heartRate] } ?? []
        if performed.isEmpty == false { return performed }
        return effectiveWorkout?.allExercises.flatMap(\.prescription.sets).compactMap { $0.values[.heartRate] } ?? []
    }

    private var heartRateSummary: String {
        let average = heartRateSamples.isEmpty ? 0 : heartRateSamples.reduce(0, +) / Double(heartRateSamples.count)
        let maximum = heartRateSamples.max() ?? 0
        return "AVG \(Int(average.rounded())) · MAX \(Int(maximum.rounded())) BPM"
    }

    private var zoneSummaries: [ZoneSummary] {
        guard let workout = effectiveWorkout else { return [] }
        return (1...5).map { zone in
            let exercises = workout.allExercises.filter { $0.prescription.targetZone == zone }
            let seconds = exercises.reduce(0.0) { total, exercise in
                if let performed = performedExercise(for: exercise) {
                    let logged = performed.setLogs.reduce(0.0) { partial, set in
                        partial + (set.values[.heartRateZoneTime] ?? set.values[.duration] ?? 0)
                    }
                    if logged > 0 { return total + logged }
                }
                let planned = exercise.prescription.sets.reduce(0.0) { partial, set in
                    partial + (set.values[.heartRateZoneTime] ?? set.values[.duration] ?? 0)
                }
                return total + planned
            }
            return ZoneSummary(zone: zone, seconds: seconds)
        }
    }

    private func zoneFraction(_ seconds: Double) -> CGFloat {
        let maximum = max(zoneSummaries.map(\.seconds).max() ?? 1, 1)
        return CGFloat(seconds / maximum)
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: BaselineColor.zoneBlue
        case 2: BaselineColor.zoneGreen
        case 3: BaselineColor.accent
        case 4: BaselineColor.zoneAmber
        default: BaselineColor.zoneRed
        }
    }

    private func performedExercise(for exercise: PlannedExercise) -> PerformedExercise? {
        log?.exercises.first {
            $0.plannedExerciseID == exercise.id || $0.exerciseName == exercise.exerciseName
        }
    }

    private func detailSetCount(_ workout: Workout) -> Int {
        let logged = log?.exercises.flatMap(\.setLogs).filter(\.isHandled).count ?? 0
        return logged > 0 ? logged : workout.allExercises.reduce(0) { $0 + $1.prescription.sets.count }
    }

    private func detailDuration(_ scheduled: ScheduledWorkout) -> String {
        if let session, let completed {
            let elapsed = completed.finishedAt.timeIntervalSince(session.startedAt)
            if elapsed >= 60 { return MetricFormat.durationLong(elapsed) }
        }
        let duration = AggregateProvider.aggregates(for: [scheduled]).first { $0.key == .duration }?.total ?? 0
        return duration > 0 ? MetricFormat.durationLong(duration) : "Planned"
    }

    private func choose(_ action: DetailAction) {
        pendingAction = action
        showActions = false
    }

    private func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .edit:
            beginEditing()
        case .saveTemplate:
            guard let workout = effectiveWorkout else { return }
            _ = plan.saveAsTemplate(name: workout.title, from: workout)
            showTemplateSaved = true
        case .delete:
            requestDelete()
        }
    }

    private func beginEditing() {
        guard let scheduled else { return }
        let defaults = UserDefaults(suiteName: "workout.detail.buffer") ?? .standard
        let store = WorkoutStore(units: settings, defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: true)
        editingBuffer = store
        editingOriginal = scheduled.workout
        editContext = EditContext(id: scheduled.id, store: store)
    }

    private func finishEditing() {
        if let editingBuffer, let editingOriginal, editingBuffer.current != editingOriginal {
            editingBuffer.flush()
        }
        plan.reload()
        editContext = nil
        editingBuffer = nil
        editingOriginal = nil
        if queuedDeleteAfterEdit {
            queuedDeleteAfterEdit = false
            requestDelete()
        }
    }

    private func requestDelete() {
        let result = plan.delete(scheduledWorkoutID)
        if case .confirmationRequired(_, _, let proposalID) = result {
            deleteProposalID = proposalID
            showDeleteConfirmation = true
        }
    }

    private func confirmDelete() {
        guard let deleteProposalID else { return }
        let result = plan.delete(scheduledWorkoutID, proposalID: deleteProposalID)
        self.deleteProposalID = nil
        if result.isApplied {
            dismiss()
        }
    }
}
