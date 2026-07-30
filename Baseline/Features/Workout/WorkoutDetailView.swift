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
    /// The screen's repository state, resolved in one pass on appear and per plan mutation
    /// (`plan.revision`). Every derived value (zone summaries, heart-rate samples, set counts) reads
    /// from this snapshot so nothing re-fetches inside `body`.
    @State private var snapshot: DetailSnapshot?
    /// Distinguishes "not resolved yet" from "resolved and missing": the unavailable state renders
    /// only after a load attempt, so the first frame never flashes a false error.
    @State private var hasLoadedSnapshot = false
    @State private var heartRateSamples: [Double] = []
    @State private var zoneSummaries: [ZoneSummary] = []

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

    private struct DetailSnapshot {
        let scheduled: ScheduledWorkout
        let session: WorkoutSession?
        let completed: CompletedWorkoutLog?
        let workout: Workout
        /// The persisted live heart-rate trace + summary, resolved in the same single pass as
        /// everything else on this screen. Nil for a workout performed without a strap, and for every
        /// workout completed before Baseline recorded traces.
        let heartRate: WorkoutHeartRateCapture?
        var log: WorkoutLog? { completed?.log ?? session?.log }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()

                if let snapshot {
                    let workout = snapshot.workout
                    ScrollView {
                        VStack(alignment: .leading, spacing: BaselineSpacing.large) {
                            detailHeader(scheduled: snapshot.scheduled, workout: workout)
                            muscleMapCard(workout: workout)

                            if hasHeartRateEvidence {
                                heartRateCard
                            }

                            if zoneSummaries.contains(where: { $0.seconds > 0 }) {
                                zonesCard
                            }

                            InstrumentLabel("EXERCISES", tracking: 1.2)
                                .padding(.top, BaselineSpacing.xxSmall)

                            ForEach(workout.allExercises) { exercise in
                                WorkoutDetailExerciseSection(
                                    planned: effectiveExercise(exercise),
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
                } else if hasLoadedSnapshot {
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
        .onAppear(perform: reloadSnapshot)
        .onChange(of: plan.revision) { reloadSnapshot() }
    }

    /// Resolve the scheduled workout, its session and completed log, and the derived summaries in one
    /// repository pass. The session's own workout copy wins - it is what the athlete performed.
    private func reloadSnapshot() {
        defer { hasLoadedSnapshot = true }
        guard let scheduled = plan.scheduledWorkout(scheduledWorkoutID) else {
            snapshot = nil
            heartRateSamples = []
            zoneSummaries = []
            return
        }
        let session = plan.session(for: scheduledWorkoutID)
        let completed = plan.completed(for: scheduledWorkoutID)
        let workout = session?.workout ?? scheduled.workout
        // The sidecar is decoded only when this screen is (re)loaded, never from `body`.
        let series = plan.heartRateSeries(for: scheduledWorkoutID)
        let resolved = DetailSnapshot(
            scheduled: scheduled,
            session: session,
            completed: completed,
            workout: workout,
            heartRate: series.map { WorkoutHeartRateCapture(trace: $0.trace, summary: $0.summary) }
        )
        snapshot = resolved
        // Measured heart rate only - planned prescription targets are intent, not data, and must never
        // render as AVG/MAX measurements. No performed samples ⇒ no heart-rate card.
        heartRateSamples = resolved.log?.exercises.flatMap(\.setLogs).compactMap { $0.values[.heartRate] } ?? []
        zoneSummaries = computeZoneSummaries(
            workout: workout,
            log: resolved.log,
            heartRate: resolved.heartRate?.summary ?? resolved.log?.heartRateSummary
        )
    }

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

    /// Any measured heart rate at all: a recorded live trace, or per-set readings the athlete logged
    /// by hand. Planned target zones are intent and never count.
    private var hasHeartRateEvidence: Bool {
        heartRateTrace != nil || heartRateSamples.isEmpty == false
    }

    private var heartRateTrace: WorkoutHeartRateCapture? {
        guard let heartRate = snapshot?.heartRate, heartRate.trace.hasSamples else { return nil }
        return heartRate
    }

    @ViewBuilder private var heartRateCard: some View {
        BaselineCard {
            // A recorded trace is a real time series and wins; the per-set sparkline stays the honest
            // fallback for older logs and manually entered readings, where the x axis is an index and
            // nothing else would be true.
            if let trace = heartRateTrace {
                WorkoutHeartRateTraceChart(
                    capture: trace,
                    startedAt: snapshot?.session?.startedAt,
                    finishedAt: snapshot?.completed?.finishedAt
                )
            } else {
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

    private var heartRateSummary: String {
        let average = heartRateSamples.isEmpty ? 0 : heartRateSamples.reduce(0, +) / Double(heartRateSamples.count)
        let maximum = heartRateSamples.max() ?? 0
        return "AVG \(Int(average.rounded())) · MAX \(Int(maximum.rounded())) BPM"
    }

    /// Seconds per zone, measured only.
    ///
    /// A recorded session hands over real seconds-in-zone, credited sample by sample against the zone
    /// model in force at the time. Otherwise the fallback is what the athlete logged against
    /// zone-targeted exercises. There is deliberately no *planned* fallback: this card sits directly
    /// under one that refuses to render prescription targets as measurements, and rendering intent as
    /// time-in-zone here would be the same lie in a different shape.
    private func computeZoneSummaries(
        workout: Workout,
        log: WorkoutLog?,
        heartRate: WorkoutHeartRateSummary?
    ) -> [ZoneSummary] {
        if let heartRate, heartRate.totalZoneSeconds > 0 {
            return heartRate.secondsByZoneOrdered.map { ZoneSummary(zone: $0.zone.rawValue, seconds: $0.seconds) }
        }
        return HeartRateZone.allCases.map { zone in
            let exercises = workout.allExercises.filter { $0.prescription.targetZone == zone.rawValue }
            let seconds = exercises.reduce(0.0) { total, exercise in
                guard let performed = performedExercise(for: exercise, in: log) else { return total }
                return total + performed.setLogs.reduce(0.0) { partial, set in
                    partial + (set.values[.heartRateZoneTime] ?? set.values[.duration] ?? 0)
                }
            }
            return ZoneSummary(zone: zone.rawValue, seconds: seconds)
        }
    }

    private func zoneFraction(_ seconds: Double) -> CGFloat {
        let maximum = max(zoneSummaries.map(\.seconds).max() ?? 1, 1)
        return CGFloat(seconds / maximum)
    }

    /// The one five-colour zone ramp, shared with the live spectrum and the settings preview. This
    /// screen used to carry its own (Z3 accent, Z4 amber), so the same zone changed colour as the
    /// athlete moved between screens.
    private func zoneColor(_ zone: Int) -> Color {
        HeartRateZone(rawValue: zone)?.color ?? BaselineColor.textFaint
    }

    /// Fold any live-log substitution into the exercise so history renders the movement the athlete
    /// actually performed — its identity, muscles, and metric schema — rather than the original plan.
    /// A declined "update plan?" leaves the substitution on the log only, so this is where it surfaces.
    private func effectiveExercise(_ exercise: PlannedExercise) -> PlannedExercise {
        snapshot?.log?.effectiveExercise(for: exercise) ?? exercise
    }

    private func performedExercise(for exercise: PlannedExercise) -> PerformedExercise? {
        performedExercise(for: exercise, in: snapshot?.log)
    }

    private func performedExercise(for exercise: PlannedExercise, in log: WorkoutLog?) -> PerformedExercise? {
        log?.exercises.first {
            $0.plannedExerciseID == exercise.id || $0.exerciseName == exercise.exerciseName
        }
    }

    private func detailSetCount(_ workout: Workout) -> Int {
        let logged = snapshot?.log?.exercises.flatMap(\.setLogs).filter(\.isHandled).count ?? 0
        return logged > 0 ? logged : workout.allExercises.reduce(0) { $0 + $1.prescription.sets.count }
    }

    private func detailDuration(_ scheduled: ScheduledWorkout) -> String {
        if let completed = snapshot?.completed {
            // The athlete-confirmed duration is a performed fact carried by the completed record
            // itself, so it stands whether or not the session row survived alongside it. Only the
            // elapsed-time fallback needs the session's start instant.
            if let duration = completed.durationSeconds {
                return MetricFormat.durationLong(duration)
            }
            if let session = snapshot?.session {
                let elapsed = completed.finishedAt.timeIntervalSince(session.startedAt)
                if elapsed >= 60 { return MetricFormat.durationLong(elapsed) }
            }
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
            guard let workout = snapshot?.workout else { return }
            _ = plan.saveAsTemplate(name: workout.title, from: workout)
            showTemplateSaved = true
        case .delete:
            requestDelete()
        }
    }

    private func beginEditing() {
        guard let scheduled = plan.scheduledWorkout(scheduledWorkoutID) else { return }
        let defaults = UserDefaults(suiteName: "workout.detail.buffer") ?? .standard
        let store = WorkoutStore(units: settings, defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: true)
        editingBuffer = store
        editingOriginal = scheduled.workout
        editContext = EditContext(id: scheduled.id, store: store)
    }

    private func finishEditing() {
        let deleteQueued = queuedDeleteAfterEdit
        queuedDeleteAfterEdit = false
        if deleteQueued == false {
            if let editingBuffer, let editingOriginal, editingBuffer.current != editingOriginal {
                editingBuffer.flush()
            }
            plan.reload()
        }
        editContext = nil
        editingBuffer = nil
        editingOriginal = nil
        if deleteQueued {
            // The workout is being removed - skip the write-through flush so no revision is written
            // for content about to be deleted (mirrors PlanView.flushExecution).
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
