import SwiftUI
import SwiftData

/// Signed-in home. **Today branches on evidence** (see docs/architecture.md): with nothing to stand
/// on, the Context Engine leads — the conversation is the fastest path to a plan; with partial
/// evidence a plan shows but the precise readiness number is withheld; only an established evidence
/// base earns the number. The hero is always *today's plan* — conversation is how you reach or refine
/// it, never a permanent front door.
struct TodayView: View {
    @Environment(AuthViewModel.self) private var authVM
    @Environment(AppSettings.self) private var settings
    @Environment(OnboardingStore.self) private var profile
    @Environment(HealthService.self) private var health
    @Environment(TrainingContextStore.self) private var context
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]
    @Query(sort: \ReadinessEntry.date, order: .reverse) private var entries: [ReadinessEntry]
    @State private var activeModal: TodayModal?
    @State private var autoPromptedDate: Date?
    @State private var showChat = false
    @State private var live: LiveToday?
    /// Today's sleep evidence for the tappable sleep row + detail push. Nil while the Sleep Engine is
    /// dormant (no store registered / no provider), which keeps Today byte-identical to pre-slice
    /// (AC-6/AC-7). Go-live wires a `SleepEvidenceProvider` read here; until then it never populates,
    /// so no sleep row renders and nothing navigates to `SleepDetailView`.
    @State private var todaySleep: SleepDetailContext?

    /// Yesterday's Apple Health activity for the evidence tile — nil (tile hidden) until Health is
    /// connected and the day recorded data, never a misleading zero. Loaded in `reassemble`. Sleep
    /// and HRV tiles read their scores from `todaySleep` / the decision, not a separate load.
    @State private var yesterdayActivity: DayActivity?

    /// Live readiness formula, edited in Profile → sourced from the shared profile store.
    private var readinessConfig: ReadinessConfig { profile.draft.config }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        content
                    }
                    .padding(20)
                    // Clear the floating tab bar so no content — the Ask Baseline entry especially —
                    // gets trapped under it and becomes un-tappable.
                    .padding(.bottom, 72)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
        }
        .fullScreenCover(item: $activeModal, onDismiss: { Task { await reassemble() } }) { modal in
            switch modal {
            case .morningPrompt:
                if let source = readinessConfig.heartSource {
                    MorningReadinessPromptView(
                        source: source,
                        onStart: { activeModal = readingModal(for: .morning) },
                        onDismiss: { activeModal = nil }
                    )
                }
            case .snapshotStart:
                SnapshotStartView(
                    onStart: { activeModal = readingModal(for: .snapshot) },
                    onDismiss: { activeModal = nil }
                )
            case .dailyReading(let type):
                DailyReadingFlowView(type: type, config: readinessConfig, duration: duration(for: type))
            }
        }
        .sheet(isPresented: $showChat, onDismiss: { Task { await reassemble() } }) {
            AskBaselineSheet(surface: .today)
        }
        .task(id: "\(readings.count)-\(entries.count)") { await reassemble() }
        .onAppear { maybeShowMorningPrompt(auto: true) }
        .onChange(of: readings.count) { _, _ in maybeShowMorningPrompt(auto: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await reassemble() }
                maybeShowMorningPrompt(auto: true)
            }
        }
    }

    // MARK: - Content branch

    @ViewBuilder private var content: some View {
        if let live {
            evidenceTiles
            switch live.decision.evidenceTier {
            case .none:        noEvidenceHome
            case .partial:     planFirst(live, showNumber: false)
            case .established: planFirst(live, showNumber: true)
            }
        } else {
            ProgressView().tint(BaselineColor.accent)
                .frame(maxWidth: .infinity).padding(.top, 48)
        }
    }

    // MARK: - State 1 · no evidence → conversation leads

    private var noEvidenceHome: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Let's build today's plan.")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                Text("I don't know enough about today yet. Tell me how you're feeling and what you've got time for — I'll turn it into a plan.")
                    .font(.system(size: 15)).foregroundStyle(BaselineColor.textMid)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { showChat = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 16))
                    Text("Talk to Baseline").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color(hex: 0x120B21))
                .padding(.horizontal, 18).frame(height: 60).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.accent))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 10) {
                Text("OR ADD EVIDENCE FOR A SHARPER PLAN")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.textFaint)
                if !health.requested {
                    evidenceRow(icon: "heart.fill", title: "Connect Apple Health", subtitle: "Sleep & resting HR") { connectHealth() }
                }
                evidenceRow(icon: "waveform.path.ecg", title: "Take an HRV reading", subtitle: "2:30 morning scan") { start(.morning) }
            }
        }
    }

    // MARK: - State 2/3 · plan first

    /// Plan-first home. The evidence tiles (above) now carry sleep / HRV / activity and tap through to
    /// their detail screens, so this stays lean: the plan, anything to avoid, and Ask Baseline.
    @ViewBuilder private func planFirst(_ live: LiveToday, showNumber: Bool) -> some View {
        planCard(live, showNumber: showNumber)
        if !live.plan.avoid.isEmpty { avoidCard(live.plan.avoid) }
        askBaselineBar
    }

    private func planCard(_ live: LiveToday, showNumber: Bool) -> some View {
        let d = live.decision
        return card {
            HStack {
                Text("TODAY'S PLAN").font(.system(size: 12, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.accent)
                Spacer()
                if showNumber {
                    HStack(spacing: 6) {
                        Circle().fill(bandColor(d.band)).frame(width: 8, height: 8)
                        Text("\(d.score)").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(BaselineColor.textHi)
                        Text("READINESS").font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.textFaint)
                    }
                }
            }
            Text(live.plan.summary).font(.system(size: 16, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                certaintyChip(d)
                if let dom = d.primaryLimiter {
                    Text("Limited by \(dom.title.lowercased())")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(BaselineColor.textMid)
                }
            }
        }
    }

    private func avoidCard(_ items: [String]) -> some View {
        card {
            Text("AVOID").font(.system(size: 12, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.zoneAmber)
            ForEach(items, id: \.self) { r in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(BaselineColor.zoneAmber).frame(width: 4, height: 4).padding(.top, 7)
                    Text(r).font(.system(size: 14)).foregroundStyle(BaselineColor.textMid).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Shared pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting).font(.system(size: 28, weight: .bold)).foregroundStyle(BaselineColor.textHi)
            Text(Date.now, format: .dateTime.weekday(.wide).month().day())
                .font(.system(size: 15, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var askBaselineBar: some View {
        Button { showChat = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 15)).foregroundStyle(BaselineColor.accent)
                Text("Ask Baseline").font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                Spacer()
                Image(systemName: "mic.fill").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
            }
            .padding(.horizontal, 16).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BaselineColor.accent.opacity(0.35), lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    private func evidenceRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(BaselineColor.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                    Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(BaselineColor.textFaint)
            }
            .padding(.horizontal, 14).frame(height: 56).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.base)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BaselineColor.line, lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    private func certaintyChip(_ d: DecisionEngine.Result) -> some View {
        Text(certaintyLabel(d).uppercased())
            .font(.system(size: 10, weight: .bold)).tracking(0.4).foregroundStyle(BaselineColor.textMid)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(BaselineColor.base).overlay(Capsule().strokeBorder(BaselineColor.line, lineWidth: 1)))
    }

    private func certaintyLabel(_ d: DecisionEngine.Result) -> String {
        if d.calibrating { return "Calibrating" }
        switch d.certainty {
        case .low: return "Low certainty"
        case .medium: return "Medium certainty"
        case .high: return "High certainty"
        }
    }

    private func bandColor(_ band: DecisionEngine.Band) -> Color {
        switch band {
        case .green: BaselineColor.zoneGreen
        case .red: BaselineColor.zoneRed
        case .amber: BaselineColor.zoneAmber
        }
    }


    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: - Live assembly

    /// The single live recompute for Today — base evidence (reading + Health) layered with the
    /// Context Engine's state, through the same `PlanAssembler` the chat uses.
    private func reassemble() async {
        context.rolloverIfNeeded()   // never plan today off yesterday's context
        let today = entries.first { Calendar.current.isDateInToday($0.date) }
        // Sleep Engine seam (go-live): read the canonical night for today over the shared store,
        // threading the athlete's sleep need from the live config. No night → provider returns nil →
        // the decision falls back to the legacy/manual path, so this stays safe with an empty store.
        let sleepRepo = SwiftDataSleepRepository(context: modelContext)
        let sleepProvider = RepositorySleepEvidenceProvider(repository: sleepRepo, config: readinessConfig)
        let base = await TodayEvidence.baseInputs(
            readings: readings, todayEntry: today, health: health,
            sleepProvider: sleepProvider, referenceDate: .now)
        let (decision, plan) = PlanAssembler.assemble(
            base: base,
            dailyContext: context.daily,
            constraints: context.activeConstraints
        )
        live = LiveToday(decision: decision, plan: plan)
        // Populate the tappable sleep row from the same canonical night. Present only when a night
        // exists for today; otherwise the row stays absent (dormant layout preserved).
        if let night = sleepRepo.night(for: .now), let analysis = sleepRepo.analysis(for: .now) {
            todaySleep = SleepDetailContext(night: night, analysis: analysis, decision: decision)
        } else {
            todaySleep = nil
        }

        // Yesterday's activity for the evidence tile — nil (tile hidden) when Health is
        // unavailable/unconnected or the day had no recorded activity.
        if let a = await health.activitySummary(daysAgo: 1) {
            yesterdayActivity = DayActivity(kcal: a.activeEnergyKcal, minutes: a.exerciseMinutes)
        } else {
            yesterdayActivity = nil
        }
    }

    // MARK: - Evidence tiles (Apple Health + today's reading)

    /// Today's HRV reading if one was taken today, else nil (yesterday's reading is not "today").
    private var todayReading: Reading? {
        readings.first.flatMap { Calendar.current.isDateInToday($0.date) ? $0 : nil }
    }

    /// Sleep score (0–100) from today's canonical night, or nil when the Sleep Engine has none.
    private var sleepScore: Int? { todaySleep?.analysis.score }

    /// Today's HRV on the 0–100 readiness scale — the same `DecisionEngine.hrvScore` mapping the
    /// history trend uses, so the tile and the history agree for the same reading. Present only when a
    /// reading exists today.
    private var hrvScore: Int? {
        todayReading.map { DecisionEngine.hrvScore(lnRMSSD: $0.lnRMSSD) }
    }

    private var hasAnyTile: Bool { sleepScore != nil || hrvScore != nil || yesterdayActivity != nil }

    /// A compact, glanceable evidence row: Sleep · HRV · Activity, each a 0–100 score (activity in its
    /// own units). Each tile appears only when its data exists, and Sleep/HRV tap through to their
    /// detail screens — so the old Sleep card, Last Reading, and reading buttons are no longer needed.
    @ViewBuilder private var evidenceTiles: some View {
        if hasAnyTile {
            HStack(spacing: 10) {
                if let ctx = todaySleep, let score = ctx.analysis.score {
                    NavigationLink {
                        SleepDetailView(night: ctx.night, analysis: ctx.analysis, decision: ctx.decision)
                    } label: {
                        statTile(value: "\(score)", label: "SLEEP", tint: BaselineColor.sleepCore)
                    }
                    .buttonStyle(.plain)
                }
                if let hrv = hrvScore {
                    NavigationLink { ReadingHistoryView() } label: {
                        statTile(value: "\(hrv)", label: "HRV", tint: BaselineColor.accent)
                    }
                    .buttonStyle(.plain)
                }
                if let a = yesterdayActivity {
                    statTile(value: activityValue(a), label: "ACTIVITY", tint: BaselineColor.zoneGreen)
                }
            }
        }
    }

    private func activityValue(_ a: DayActivity) -> String {
        a.minutes >= 1 ? "\(Int(a.minutes.rounded()))m" : "\(Int(a.kcal.rounded()))cal"
    }

    private func statTile(value: String, unit: String = "", label: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(BaselineColor.textHi)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(BaselineColor.textFaint)
                }
            }
            Text(label).font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity).frame(height: 76)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }

    private func connectHealth() {
        Task {
            await health.requestReadAccess()
            await reassemble()
        }
    }

    // MARK: - Reading flow

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

    private func start(_ type: ReadingType) {
        switch type {
        case .morning:
            activeModal = readinessConfig.heartSource != nil ? .morningPrompt : readingModal(for: .morning)
        case .snapshot:
            activeModal = .snapshotStart
        }
    }

    private func readingModal(for type: ReadingType) -> TodayModal { .dailyReading(type) }

    private func duration(for type: ReadingType) -> TimeInterval {
        type == .morning ? TimeInterval(settings.morningReadingDurationSeconds) : type.duration
    }

}

/// Today's live decision + plan, assembled from current evidence + context.
private struct LiveToday {
    let decision: DecisionEngine.Result
    let plan: PlanningEngine.Plan
}

/// Yesterday's activity for the Home evidence tile — Apple exercise minutes with a calorie fallback.
private struct DayActivity: Equatable {
    let kcal: Double
    let minutes: Double
}

private enum TodayModal: Identifiable, Equatable {
    case morningPrompt
    case snapshotStart
    case dailyReading(ReadingType)

    var id: String {
        switch self {
        case .morningPrompt: "morningPrompt"
        case .snapshotStart: "snapshotStart"
        case .dailyReading(let type): "dailyReading.\(type.rawValue)"
        }
    }
}

#Preview {
    TodayView()
        .environment(AuthViewModel())
        .environment(AppSettings())
        .environment(BluetoothManager())
        .environment(HealthService())
        .environment(TrainingContextStore())
        .environment(OnboardingStore())
        .modelContainer(for: Reading.self, inMemory: true)
}
