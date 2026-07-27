import SwiftUI
import SwiftData

/// The athlete's home base: identity + streak, the Baseline protocol (readiness setup, zones,
/// devices), integrations, reading cues, and sign-out. Devices → Measurements is the live path;
/// rows without a backing surface yet are shown as "Soon" so nothing is a dead tap.
struct ProfileView: View {
    @Environment(OnboardingStore.self) private var profile
    @Environment(AuthViewModel.self) private var authVM
    @Environment(AppSettings.self) private var settings
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(HealthService.self) private var health
    @Environment(PlanStore.self) private var plan
    @Environment(HeartRateZoneSettingsStore.self) private var heartRateZones
    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]
    @State private var selectedSection = ProfileSection.workouts
    @State private var showSettings = false
    @State private var detailWorkout: ScheduledWorkout?
    /// Cached year-to-date training history, derived on appear and once per plan mutation
    /// (`plan.revision`). The year-long repository fetch and its reductions never run inside `body`.
    @State private var history = ProfileHistory()

    /// Completed training only - Profile is the record of what the athlete actually did, so scheduled
    /// sessions that were never performed (or were skipped) contribute nothing here.
    private struct ProfileHistory {
        var yearWorkouts: [ScheduledWorkout] = []
        var thisWeekWorkouts: [ScheduledWorkout] = []
        var lastWeekWorkouts: [ScheduledWorkout] = []
        var weekStreak = 0
        var yearDurationSeconds = 0.0
        var yearExerciseCount = 0
        var yearSetCount = 0
    }

    private enum ReadingFlowStep: String, Identifiable {
        case start
        case reading

        var id: String { rawValue }
    }

    @State private var readingFlow: ReadingFlowStep?

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: BaselineSpacing.large) {
                    profileHeader

                    HStack(spacing: BaselineSpacing.xSmall) {
                        ProfileStatTile(value: "\(history.yearWorkouts.count)", label: "WORKOUTS")
                        ProfileStatTile(value: "\(history.weekStreak)", label: "WEEK STREAK")
                        ProfileStatTile(value: thisYearDuration, label: "THIS YEAR")
                    }
                    .padding(.bottom, BaselineSpacing.xxxSmall)

                    ProfileSegmentedControl(selection: $selectedSection)

                    if selectedSection == .workouts {
                        workoutHistory
                    } else {
                        progressSummary
                    }
                }
                .padding(.horizontal, BaselineSpacing.large)
                .padding(.top, BaselineSpacing.compact)
                .padding(.bottom, BaselineSpacing.screenBottom)
            }
        }
        .onAppear(perform: refreshHistory)
        .onChange(of: plan.revision) { refreshHistory() }
        .sheet(isPresented: $showSettings) {
            settingsScreen
        }
        .fullScreenCover(item: $detailWorkout) { scheduled in
            WorkoutDetailView(scheduledWorkoutID: scheduled.id)
        }
    }

    private var settingsScreen: some View {
        @Bindable var settings = settings
        return NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: BaselineSpacing.screen) {
                        settingsHeaderCard

                        group("Setup") {
                            row(icon: "circle.hexagongrid.fill", title: "Readiness Setup",
                                subtitle: "Which inputs build your score", destination: .soon)
                            NavigationLink {
                                HeartRateZoneSettingsView(store: heartRateZones)
                            } label: {
                                rowBody(icon: "waveform.path.ecg.rectangle.fill", title: "Heart Rate Zones",
                                        subtitle: "Karvonen / LTHR zones", trailing: .chevron)
                            }
                            .buttonStyle(.plain)
                            NavigationLink { MeasurementsView() } label: {
                                rowBody(icon: "dot.radiowaves.left.and.right", title: "Devices",
                                        subtitle: deviceSubtitle, trailing: .chevron)
                            }
                            .buttonStyle(.plain)
                        }

                        group("Integrations") {
                            appleHealthRow
                            row(icon: "bell.fill", title: "Notifications",
                                subtitle: "Morning reading reminder", destination: .soon)
                        }

                        group("Units") {
                            unitSystemRow
                        }

                        group("Reading") {
                            takeReadingRow
                            cardToggle("Live preview", isOn: $settings.livePreviewEnabled)
                        }

                        Button(role: .destructive) { authVM.signOut() } label: {
                            Text("Sign out")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(BaselineColor.zoneRed)
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showSettings = false
                    }
                    .tint(BaselineColor.accent)
                }
            }
        }
        .fullScreenCover(item: $readingFlow) { step in
            switch step {
            case .start:
                SnapshotStartView(
                    onStart: { readingFlow = .reading },
                    onDismiss: { readingFlow = nil }
                )
            case .reading:
                DailyReadingFlowView(
                    type: .snapshot,
                    config: profile.draft.config,
                    duration: ReadingType.snapshot.duration
                )
            }
        }
    }

    // MARK: - Profile dashboard

    private var profileHeader: some View {
        HStack(spacing: BaselineSpacing.row) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [BaselineColor.accent, BaselineColor.amethyst],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: BaselineSize.avatar, height: BaselineSize.avatar)
                .overlay {
                    Text(displayName.prefix(1).uppercased())
                        .font(.title2.bold())
                        .foregroundStyle(BaselineColor.base)
                }
                .accessibilityHidden(true)

            Text(displayName)
                .font(.title3.bold())
                .foregroundStyle(BaselineColor.textHi)

            Spacer()

            Button("Settings", systemImage: "gearshape", action: { showSettings = true })
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(BaselineColor.textMid)
                .frame(width: BaselineSize.minimumTapTarget, height: BaselineSize.minimumTapTarget)
        }
        .padding(.vertical, BaselineSpacing.compact)
    }

    private var workoutHistory: some View {
        VStack(alignment: .leading, spacing: BaselineSpacing.xSmall) {
            workoutSection("THIS WEEK", workouts: history.thisWeekWorkouts)
            workoutSection("LAST WEEK", workouts: history.lastWeekWorkouts)

            if history.thisWeekWorkouts.isEmpty && history.lastWeekWorkouts.isEmpty {
                BaselineCard {
                    VStack(alignment: .leading, spacing: BaselineSpacing.xxSmall) {
                        Text("Your workouts will appear here")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BaselineColor.textHi)
                        Text("Complete a session from Plan to build your history.")
                            .font(.caption)
                            .foregroundStyle(BaselineColor.textMid)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func workoutSection(_ title: String, workouts: [ScheduledWorkout]) -> some View {
        if workouts.isEmpty == false {
            InstrumentLabel(title, tracking: 1)
                .padding(.top, BaselineSpacing.compact)

            ForEach(workouts) { scheduled in
                ProfileWorkoutRow(
                    scheduled: scheduled,
                    subtitle: workoutSubtitle(scheduled),
                    action: { detailWorkout = scheduled }
                )
            }
        }
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: BaselineSpacing.large) {
            BaselineCard {
                VStack(alignment: .leading, spacing: BaselineSpacing.medium) {
                    InstrumentLabel("MUSCLE MAP", tracking: 1)
                    MuscleMapView(workouts: history.yearWorkouts.map(\.workout))
                }
            }

            BaselineCard {
                VStack(alignment: .leading, spacing: BaselineSpacing.small) {
                    InstrumentLabel("TRAINING SUMMARY", tracking: 1)
                    summaryRow("Sessions this week", value: "\(history.thisWeekWorkouts.count)")
                    Hairline()
                    summaryRow("Exercises this year", value: "\(history.yearExerciseCount)")
                    Hairline()
                    summaryRow("Sets this year", value: "\(history.yearSetCount)")
                }
            }
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(BaselineColor.textMid)
            Spacer()
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(BaselineColor.textHi)
        }
    }

    private var calendar: Calendar { .planWeek }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var currentWeekStart: Date { calendar.weekStart(for: today) }

    private func refreshHistory() {
        let yearStart = calendar.date(from: calendar.dateComponents([.year], from: today)) ?? today
        let sessions = plan.days(from: yearStart, through: today)
            .flatMap(\.sessions)
            .filter { $0.date <= today }
        let completedIDs = plan.completedScheduledWorkoutIDs(among: sessions.map(\.id))
        let completed = sessions.filter { completedIDs.contains($0.id) }

        var result = ProfileHistory()
        result.yearWorkouts = completed
        result.thisWeekWorkouts = completed.filter { $0.date >= currentWeekStart }.sorted { $0.date > $1.date }
        if let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: currentWeekStart) {
            result.lastWeekWorkouts = completed
                .filter { $0.date >= lastWeekStart && $0.date < currentWeekStart }
                .sorted { $0.date > $1.date }
        }
        result.weekStreak = weekStreak(of: completed)
        result.yearDurationSeconds = completed.reduce(0.0) { partial, scheduled in
            let duration = AggregateProvider.aggregates(for: [scheduled]).first { $0.key == .duration }?.total ?? 0
            return partial + duration
        }
        result.yearExerciseCount = completed.reduce(0) { $0 + $1.workout.allExercises.count }
        result.yearSetCount = completed.reduce(0) { partial, scheduled in
            partial + scheduled.workout.allExercises.reduce(0) { $0 + $1.prescription.sets.count }
        }
        history = result
    }

    private func weekStreak(of workouts: [ScheduledWorkout]) -> Int {
        let occupiedWeeks = Set(workouts.map { calendar.weekStart(for: $0.date) })
        guard occupiedWeeks.isEmpty == false else { return 0 }
        var cursor = currentWeekStart
        if occupiedWeeks.contains(cursor) == false {
            cursor = calendar.date(byAdding: .day, value: -7, to: cursor) ?? cursor
        }
        var result = 0
        while occupiedWeeks.contains(cursor) {
            result += 1
            guard let previous = calendar.date(byAdding: .day, value: -7, to: cursor) else { break }
            cursor = previous
        }
        return result
    }

    private var thisYearDuration: String {
        let hours = Int((history.yearDurationSeconds / 3600).rounded())
        return "\(hours)h"
    }

    private func workoutSubtitle(_ scheduled: ScheduledWorkout) -> String {
        let descriptors = scheduled.workout.allExercises.prefix(2).map(\.exerciseName)
        let work = descriptors.isEmpty ? (scheduled.workout.goalLine ?? "Training") : descriptors.joined(separator: " + ")
        let duration = AggregateProvider.aggregates(for: [scheduled]).first { $0.key == .duration }
            .map { MetricFormat.durationLong($0.total) } ?? "Planned"
        let weekday = scheduled.date.formatted(.dateTime.weekday(.abbreviated))
        return "\(work) · \(duration) · \(weekday)"
    }

    // MARK: - Settings

    private var settingsHeaderCard: some View {
        VStack(spacing: BaselineSpacing.medium) {
            Circle()
                .fill(BaselineColor.amethyst)
                .frame(width: BaselineSize.avatar, height: BaselineSize.avatar)
                .overlay {
                    Circle()
                        .strokeBorder(BaselineColor.accent, lineWidth: BaselineSize.hairline)
                }
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.title3)
                        .foregroundStyle(BaselineColor.accent)
                }
            Text(displayName.uppercased())
                .font(.title3.bold())
                .foregroundStyle(BaselineColor.textHi)
            HStack(spacing: BaselineSpacing.xSmall) {
                Text("\(readings.count) READINGS")
                Text("·")
                Text("\(streak)-DAY STREAK")
            }
            .font(.caption.monospaced().weight(.medium))
            .tracking(1)
            .foregroundStyle(BaselineColor.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BaselineSpacing.xSmall)
    }

    // MARK: - Rows

    private enum RowDestination { case soon }
    private enum Trailing { case chevron, soon, connected }

    private func row(icon: String, title: String, subtitle: String, destination: RowDestination) -> some View {
        rowBody(icon: icon, title: title, subtitle: subtitle, trailing: .soon)
    }

    /// Apple Health is a real integration (auth is requested here or during onboarding). Once asked,
    /// Health hides whether reads were granted, so we reflect "Connected" from having requested; a
    /// fresh install can tap to connect. Data-off is surfaced by empty tiles on Today, not here.
    private var appleHealthRow: some View {
        Button {
            if !health.requested { Task { await health.requestReadAccess() } }
        } label: {
            rowBody(icon: "heart.text.square.fill", title: "Apple Health",
                    subtitle: health.requested ? "Connected" : "Sleep, resting HR, activity",
                    trailing: health.requested ? .connected : .chevron)
        }
        .buttonStyle(.plain)
        .disabled(health.requested)
    }

    private var takeReadingRow: some View {
        Button { readingFlow = .start } label: {
            rowBody(icon: "waveform.path.ecg", title: "Take a reading",
                    subtitle: "One-minute HRV snapshot", trailing: .chevron)
        }
        .buttonStyle(.plain)
    }

    private func rowBody(icon: String, title: String, subtitle: String, trailing: Trailing) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BaselineColor.amethyst)
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: icon).font(.system(size: 15)).foregroundStyle(BaselineColor.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
            }
            Spacer()
            switch trailing {
            case .chevron:
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(BaselineColor.textFaint)
            case .soon:
                Text("SOON").font(.bMono(10, .bold)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(BaselineColor.line))
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BaselineColor.zoneGreen)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
        .opacity(trailing == .soon ? 0.6 : 1)
    }

    /// The global imperial/metric default. Segmented control matches the onboarding units step;
    /// changing it flips every metric field and body input's default (still overridable per exercise).
    /// Label and control stack vertically: side by side the two cannot share the card's width
    /// without wrapping the label or breaking a segment across two lines.
    private var unitSystemRow: some View {
        let isImperial = Binding(
            get: { settings.unitSystem == .imperial },
            set: { setUnitSystem($0 ? .imperial : .metric) }
        )
        return VStack(alignment: .leading, spacing: BaselineSpacing.medium) {
            Text("Measurement system")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
            Segmented2(left: "METRIC", right: "IMPERIAL", isRight: isImperial,
                       fillsWidth: true, track: BaselineColor.base)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }

    /// Apply a new global unit system from the Profile control. Updates the local default, keeps the
    /// onboarding draft (which `reconcileProfile` writes on every launch) coherent so it stops
    /// pushing the stale value, and persists the choice straight to Firestore for a signed-in user.
    private func setUnitSystem(_ system: UnitSystem) {
        settings.unitSystem = system
        profile.draft.unitSystem = system
        // The body height/weight flags are the one other place a unit choice is stored. Reseed them
        // the same way the onboarding units step does, so the profile can't disagree with itself.
        profile.draft.metricHeight = (system == .metric)
        profile.draft.metricWeight = (system == .metric)
        guard let uid = authVM.user?.uid else { return }
        Task { try? await UserRepository().saveUnitSystem(uid: uid, unitSystem: system) }
    }

    private func cardToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
        }
        .tint(BaselineColor.accent)
        .padding(.horizontal, 16).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InstrumentLabel(title)
            content()
        }
    }

    // MARK: - Derived

    private var displayName: String {
        let n = profile.draft.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Athlete" : n
    }

    private var deviceSubtitle: String {
        switch profile.draft.config.heartSource {
        case .strap:
            if bluetooth.connectedDeviceID != nil { return "\(bluetooth.connectedDeviceName ?? "Strap") connected" }
            return bluetooth.savedDeviceName.map { "\($0) · not connected" } ?? "Chest strap"
        case .camera: return "Phone camera"
        case .none: return "Not set"
        }
    }

    /// Consecutive days ending today (or yesterday) that have at least one reading.
    private var streak: Int {
        let cal = Calendar.current
        let days = Set(readings.map { cal.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        var day = cal.startOfDay(for: .now)
        if !days.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day), days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }
}

#Preview {
    let models: [any PersistentModel.Type] = [Reading.self] + PlanSchema.models
    let container = try! ModelContainer(for: Schema(models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return ProfileView()
        .environment(OnboardingStore())
        .environment(AuthViewModel())
        .environment(AppSettings())
        .environment(BluetoothManager())
        .environment(HealthService())
        .environment(PlanStore(context: container.mainContext))
        .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
        .modelContainer(container)
        .preferredColorScheme(.dark)
}
