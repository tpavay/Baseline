import SwiftData
import SwiftUI

/// The signed-in home screen. Live evidence and persisted training facts are assembled here, then
/// passed to a presentation-only view that mirrors the approved Today prototype.
struct TodayView: View {
    /// Switches the shell to the Plan tab. The "Today's Plan" card must never *push* `PlanView`:
    /// it owns its own `NavigationStack`, and a nested stack inside a `navigationDestination`
    /// pops straight back and then corrupts the outer path (a `comparisonTypeMismatch` fatal on
    /// the next push). See `TodayPlanNavigationTests`.
    let openPlanTab: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(OnboardingStore.self) private var profile
    @Environment(HealthService.self) private var health
    @Environment(TrainingContextStore.self) private var context
    @Environment(PlanStore.self) private var planStore
    @Environment(HeartRateZoneSettingsStore.self) private var heartRateZones
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]
    @Query(sort: \ReadinessEntry.date, order: .reverse) private var entries: [ReadinessEntry]
    @Query private var completedLogs: [SDCompletedLog]
    @Query private var completedExercises: [SDCompletedExercise]
    @Query private var workoutSessions: [SDWorkoutSession]

    init(openPlanTab: @escaping () -> Void = {}) {
        self.openPlanTab = openPlanTab
        let calendar = Calendar.planWeek
        let weekStart = calendar.weekStart(for: .now)
        let windowStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        _completedLogs = Query(
            filter: #Predicate<SDCompletedLog> { $0.finishedAt >= windowStart },
            sort: \SDCompletedLog.finishedAt, order: .reverse
        )
        _completedExercises = Query(
            filter: #Predicate<SDCompletedExercise> { $0.date >= windowStart },
            sort: \SDCompletedExercise.date, order: .reverse
        )
        _workoutSessions = Query(
            filter: #Predicate<SDWorkoutSession> { $0.startedAt >= windowStart },
            sort: \SDWorkoutSession.startedAt, order: .reverse
        )
    }

    @State private var activeModal: TodayModal?
    @State private var autoPromptedDate: Date?
    @State private var homeModel: TodayHomeModel?
    @State private var todaySleep: SleepDetailContext?
    @State private var path: [TodayRoute] = []

    private var readinessConfig: ReadinessConfig { profile.draft.config }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let homeModel {
                    TodayHomeView(
                        model: homeModel,
                        openSleep: openSleep,
                        openHRV: { path.append(.hrv) },
                        openPlan: openPlanTab
                    )
                } else {
                    ZStack {
                        BaselineColor.base.ignoresSafeArea()
                        ProgressView().tint(BaselineColor.accent)
                    }
                }
            }
            .floatingTabBarClearance()
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .navigationDestination(for: TodayRoute.self, destination: destination)
        }
        .fullScreenCover(item: $activeModal, onDismiss: reassembleAfterDismissal) { modal in
            switch modal {
            case .morningPrompt:
                if let source = readinessConfig.heartSource {
                    MorningReadinessPromptView(
                        source: source,
                        onStart: { activeModal = readingModal(for: .morning) },
                        onDismiss: { activeModal = nil }
                    )
                }
            case .dailyReading(let type):
                DailyReadingFlowView(type: type, config: readinessConfig, duration: duration(for: type))
            }
        }
        .task(id: refreshKey) { await reassemble() }
        .onAppear { maybeShowMorningPrompt(auto: true) }
        .onChange(of: readings.count) { _, _ in maybeShowMorningPrompt(auto: true) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await reassemble() }
            maybeShowMorningPrompt(auto: true)
        }
    }

    @ViewBuilder
    private func destination(_ route: TodayRoute) -> some View {
        switch route {
        case .sleep:
            if let todaySleep {
                SleepDetailView(
                    night: todaySleep.night,
                    analysis: todaySleep.analysis,
                    decision: todaySleep.decision
                )
                .floatingTabBarClearance()
            }
        case .hrv:
            ReadingHistoryView()
                .floatingTabBarClearance()
        }
    }

    private var refreshKey: String {
        TodayRefreshSignature.make(
            readings: readings,
            entries: entries,
            completedLogs: completedLogs,
            completedExercises: completedExercises,
            workoutSessions: workoutSessions,
            zoneModel: heartRateZones.resolvedModel
        )
    }

    private func reassembleAfterDismissal() {
        Task { await reassemble() }
    }

    private func openSleep() {
        guard todaySleep != nil else { return }
        path.append(.sleep)
    }

    // MARK: Live assembly

    private func reassemble() async {
        context.rolloverIfNeeded()
        let todayEntry = entries.first { Calendar.current.isDateInToday($0.date) }
        // The repository derives with the user's configured sleep need; the provider reads the same
        // cached analysis, so the displayed and decision scores agree by construction.
        let sleepRepository = SwiftDataSleepRepository(
            context: modelContext,
            derivation: .engine(need: readinessConfig.sleepNeed)
        )
        let sleepProvider = RepositorySleepEvidenceProvider(repository: sleepRepository)
        let base = await TodayEvidence.baseInputs(
            readings: readings,
            todayEntry: todayEntry,
            health: health,
            sleepProvider: sleepProvider,
            referenceDate: .now
        )
        let (decision, plan) = PlanAssembler.assemble(
            base: base,
            dailyContext: context.daily,
            constraints: context.activeConstraints
        )

        // A superseded run must not publish its stale evidence over the newer one's. `.task(id:)`
        // cancels the previous assembly when the signature moves, but cancellation only takes effect
        // where it is observed, and every state write below happens after an await.
        guard !Task.isCancelled else { return }

        if let night = sleepRepository.night(for: .now),
           let analysis = sleepRepository.analysis(for: .now) {
            todaySleep = SleepDetailContext(night: night, analysis: analysis, decision: decision)
        } else {
            todaySleep = nil
        }

        let zoneModel = heartRateZones.resolvedModel
        let weekly = TodayWeeklySummary.build(
            sessions: completedSessionSamples,
            exercises: completedExerciseSamples,
            zoneModel: zoneModel
        )
        let zoneRanges = Dictionary(uniqueKeysWithValues: HeartRateZonePreview(model: zoneModel).rows.map {
            ($0.zone, $0.rangeText)
        })
        homeModel = TodayHomeModel(
            greeting: greeting,
            readings: readingCards,
            plan: planCardModel(decision: decision, plan: plan),
            week: weekly,
            zoneRanges: zoneRanges
        )
    }

    private var completedSessionSamples: [TodayCompletedSessionSample] {
        completedLogs.map { completed in
            let startedAt = workoutSessions.first {
                $0.scheduledWorkoutID == completed.scheduledWorkoutID
                    && $0.startedAt <= completed.finishedAt
            }?.startedAt
            return TodayCompletedSessionSample(
                completedLogID: completed.id,
                finishedAt: completed.finishedAt,
                startedAt: startedAt
            )
        }
    }

    private var completedExerciseSamples: [TodayCompletedExerciseSample] {
        completedExercises.map {
            TodayCompletedExerciseSample(
                completedLogID: $0.completedLogID,
                date: $0.date,
                definitionID: $0.exerciseDefinitionID,
                metrics: (try? JSONDecoder().decode([MetricValues].self, from: $0.metricsJSON)) ?? []
            )
        }
    }

    private var readingCards: [TodayReadingCard] {
        var cards: [TodayReadingCard] = []
        if let todaySleep, let sleepCard = TodaySleepCardModel.make(todaySleep.analysis) {
            cards.append(.sleep(sleepCard))
        }
        if let todayReading {
            cards.append(.hrv(TodayHRVCardModel(
                value: Int(todayReading.rmssd.rounded()),
                comparisonText: hrvComparison(for: todayReading),
                isPositive: hrvDelta(for: todayReading).map { $0 >= 0 } ?? true
            )))
        }
        return cards
    }

    private var todayReading: Reading? {
        readings.first { Calendar.current.isDateInToday($0.date) }
    }

    private func hrvDelta(for reading: Reading) -> Int? {
        let dayStart = Calendar.current.startOfDay(for: reading.date)
        guard let oldest = Calendar.current.date(byAdding: .day, value: -30, to: dayStart) else { return nil }
        let history = readings.filter { $0.date >= oldest && $0.date < dayStart && $0.rmssd > 0 }
        guard !history.isEmpty else { return nil }
        let mean = history.reduce(0.0) { $0 + $1.rmssd } / Double(history.count)
        return Int((reading.rmssd - mean).rounded())
    }

    private func hrvComparison(for reading: Reading) -> String {
        guard let delta = hrvDelta(for: reading) else { return "Today's reading" }
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(delta) ms vs 30-day"
    }

    private func planCardModel(
        decision: DecisionEngine.Result,
        plan: PlanningEngine.Plan
    ) -> TodayPlanCardModel {
        let scheduled = planStore.todayScheduled()
        let title = scheduled?.workout.title ?? planTitle(plan.type)
        var lead: [String] = []
        if let scheduled {
            let contributions = AggregateProvider.contributions(of: scheduled.workout)
            if let seconds = contributions.first(where: { $0.key == .duration })?.amount, seconds > 0 {
                lead.append(TodayWeeklySummary.durationText(seconds))
            }
            let modalities = scheduled.workout.allExercises.map(\.definition.category)
            let unique = modalities.reduce(into: [ActivityCategory]()) { result, category in
                if !result.contains(category) { result.append(category) }
            }
            lead.append(contentsOf: unique.prefix(2).map(PlanStatusStyle.modalityLabel))
        }

        let certainty = decision.calibrating
            ? "Calibrating"
            : "\(decision.certainty.rawValue.capitalized) certainty"
        let evidence = evidenceDescription
        let context = [certainty, evidence].filter { !$0.isEmpty }.joined(separator: " - ")
        let prefix = lead.isEmpty ? "" : lead.joined(separator: " · ") + ". "
        return TodayPlanCardModel(title: title, detail: prefix + context + ".")
    }

    private func planTitle(_ type: PlanningEngine.PlanType) -> String {
        switch type {
        case .hardIntensity: "Intensity"
        case .threshold: "Threshold"
        case .aerobicBase: "Aerobic base"
        case .easyAerobic: "Easy aerobic"
        case .lowImpact: "Low-impact training"
        case .activeRecovery: "Active recovery"
        }
    }

    private var evidenceDescription: String {
        let sleep = todaySleep?.analysis.score
        let hrv = todayReading
        switch (sleep, hrv) {
        case (.some(let score), .some(let reading)):
            return "sleep \(score), HRV \(hrvComparison(for: reading).lowercased())"
        case (.some(let score), .none):
            return "sleep \(score), no HRV reading"
        case (.none, .some(let reading)):
            return "HRV \(hrvComparison(for: reading).lowercased()), no sleep data"
        case (.none, .none):
            return "no readings this morning"
        }
    }

    private var greeting: String {
        let salutation = switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        let name = profile.draft.name
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        return name.map { "\(salutation), \($0)" } ?? salutation
    }

    // MARK: Reading flow

    private var hasMorningReadingToday: Bool {
        readings.contains { $0.kind == .morning && Calendar.current.isDateInToday($0.date) }
    }

    private func maybeShowMorningPrompt(auto: Bool) {
        guard MorningReadinessPromptPolicy.shouldPresent(
            now: .now,
            hasMorningReadingToday: hasMorningReadingToday,
            config: readinessConfig
        ) else { return }
        if auto {
            if let autoPromptedDate, Calendar.current.isDateInToday(autoPromptedDate) { return }
            autoPromptedDate = .now
        }
        activeModal = .morningPrompt
    }

    private func readingModal(for type: ReadingType) -> TodayModal {
        .dailyReading(type)
    }

    private func duration(for type: ReadingType) -> TimeInterval {
        type == .morning ? TimeInterval(settings.morningReadingDurationSeconds) : type.duration
    }
}

/// The identity fed to `TodayView`'s `.task(id:)` so the weekly summary reassembles on the data changes
/// that actually move the "This Week" / "Movement Balance" cards. It hashes the *identity and content* of
/// the performed rows, not just their counts: a count-only key never changed when a completed session was
/// deleted (or edited in place), so the cards stayed stale. Reading the performed rows and folding each
/// row's id plus its content marker in means a delete drops an id, and a future in-place log edit changes
/// a metrics blob — either way the signature moves and `reassemble()` re-fires. `Hasher` is seeded per
/// process, which is fine: this value is only ever compared against the previous value within one run.
///
/// The resolved zone model is folded in too, so a zone edit in Profile rebuilds the time-in-zone
/// durations and BPM ranges through the *same* `.task(id:)` the data changes use. That coalescing is
/// deliberate: the zone editor commits to the shared store on every valid keystroke, and routing
/// those edits through one cancellable task means typing "185" reassembles once at the end rather
/// than racing three overlapping evidence assemblies whose writes could land out of order.
enum TodayRefreshSignature {
    static func make(
        readings: [Reading],
        entries: [ReadinessEntry],
        completedLogs: [SDCompletedLog],
        completedExercises: [SDCompletedExercise],
        workoutSessions: [SDWorkoutSession],
        zoneModel: HeartRateZoneModel
    ) -> String {
        var hasher = Hasher()
        hasher.combine(zoneModel)
        hasher.combine(readings.count)
        hasher.combine(entries.count)
        for log in completedLogs {
            hasher.combine(log.id)
            hasher.combine(log.finishedAt)
        }
        for exercise in completedExercises {
            hasher.combine(exercise.id)
            hasher.combine(exercise.metricsJSON)
        }
        for session in workoutSessions {
            hasher.combine(session.id)
            hasher.combine(session.statusRaw)
        }
        return String(hasher.finalize())
    }
}

private enum TodayRoute: Hashable {
    case sleep
    case hrv
}

private enum TodayModal: Identifiable, Equatable {
    case morningPrompt
    case dailyReading(ReadingType)

    var id: String {
        switch self {
        case .morningPrompt: "morningPrompt"
        case .dailyReading(let type): "dailyReading.\(type.rawValue)"
        }
    }
}

#Preview {
    let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models + SleepSchema.models
    let container = try! ModelContainer(for: Schema(models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return TodayView()
        .environment(AppSettings())
        .environment(BluetoothManager())
        .environment(HealthService())
        .environment(TrainingContextStore())
        .environment(OnboardingStore())
        .environment(PlanStore(context: container.mainContext))
        .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
        .modelContainer(container)
}
