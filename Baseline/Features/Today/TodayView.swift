import SwiftUI
import SwiftData

/// Signed-in home for v0.1: take a reading and see your recent ones. No prescription /
/// session card yet — that arrives once there's content to recommend.
struct TodayView: View {
    @Environment(AuthViewModel.self) private var authVM
    @Environment(AppSettings.self) private var settings
    @Environment(OnboardingStore.self) private var profile
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]
    @Query(sort: \ReadinessEntry.date, order: .reverse) private var entries: [ReadinessEntry]
    @State private var activeModal: TodayModal?
    @State private var autoPromptedDate: Date?
    @State private var showChat = false

    /// Live readiness formula, edited in Profile → sourced from the shared profile store.
    private var readinessConfig: ReadinessConfig { profile.draft.config }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        todayPlanCard
                        askBaselineBar
                        lastReadingCard
                        startButtons
                        if !readings.isEmpty { historyLink }
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
        }
        .fullScreenCover(item: $activeModal) { modal in
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
        .sheet(isPresented: $showChat) { AskBaselineSheet() }
        .onAppear { maybeShowMorningPrompt(auto: true) }
        .onChange(of: readings.count) { _, _ in maybeShowMorningPrompt(auto: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { maybeShowMorningPrompt(auto: true) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting).font(.system(size: 28, weight: .bold)).foregroundStyle(BaselineColor.textHi)
            Text(Date.now, format: .dateTime.weekday(.wide).month().day())
                .font(.system(size: 15, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var lastReadingCard: some View {
        if let last = readings.first {
            card {
                Text("LAST READING").font(.system(size: 12, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.accent)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(last.rmssd.rounded()))").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(BaselineColor.textHi)
                    Text("ms HRV").font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Text("\(Int(last.meanHR.rounded())) bpm")
                    Text("·")
                    Text(last.kind.title)
                    Text("·")
                    Text(last.date, format: .relative(presentation: .named))
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(BaselineColor.textMid)
            }
        } else {
            card {
                Text("No readings yet").font(.system(size: 17, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                Text("Put on your chest strap and take your first reading.")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textMid)
            }
        }
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

    @ViewBuilder private var todayPlanCard: some View {
        if let e = todayEntry, let summary = e.planSummary {
            card {
                HStack {
                    Text("TODAY'S PLAN").font(.system(size: 12, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.accent)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(bandColor(e.band)).frame(width: 8, height: 8)
                        Text("\(e.score)").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(BaselineColor.textHi)
                        Text("READINESS").font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.textFaint)
                    }
                }
                Text(summary).font(.system(size: 16, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                    .fixedSize(horizontal: false, vertical: true)
                if let raw = e.primaryLimiter, let d = DecisionEngine.Domain(rawValue: raw) {
                    Text("Limited by \(d.title.lowercased())")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(BaselineColor.textMid)
                }
            }
        }
    }

    private var todayEntry: ReadinessEntry? {
        entries.first { Calendar.current.isDateInToday($0.date) }
    }
    private func bandColor(_ band: String) -> Color {
        switch band {
        case "green": BaselineColor.zoneGreen
        case "red": BaselineColor.zoneRed
        default: BaselineColor.zoneAmber
        }
    }

    private var startButtons: some View {
        VStack(spacing: 12) {
            startButton(.morning, filled: true)
            startButton(.snapshot, filled: false)
        }
    }

    private func startButton(_ type: ReadingType, filled: Bool) -> some View {
        Button { start(type) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.title).font(.system(size: 16, weight: .semibold))
                    Text(type.blurb).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(filled ? .black.opacity(0.6) : BaselineColor.textFaint)
                }
                Spacer()
                Text(lengthLabel(for: type)).font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundStyle(filled ? .black : BaselineColor.textHi)
            .padding(.horizontal, 18).frame(height: 64).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(filled ? BaselineColor.accent : BaselineColor.surface))
        }
        .buttonStyle(.plain)
    }

    private var historyLink: some View {
        NavigationLink { ReadingHistoryView() } label: {
            HStack {
                Text("History").font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                Spacer()
                Text("\(readings.count)").font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(BaselineColor.textFaint)
            }
            .padding(.horizontal, 18).frame(height: 52).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
        }
        .buttonStyle(.plain)
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

    private var hasMorningReadingToday: Bool {
        readings.contains { reading in
            reading.kind == .morning && Calendar.current.isDateInToday(reading.date)
        }
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
            // Always route morning through the start screen so position + length stay editable,
            // even later in the day when the auto-prompt no longer fires.
            activeModal = readinessConfig.heartSource != nil ? .morningPrompt : readingModal(for: .morning)
        case .snapshot:
            activeModal = .snapshotStart
        }
    }

    private func readingModal(for type: ReadingType) -> TodayModal {
        .dailyReading(type)
    }

    private func duration(for type: ReadingType) -> TimeInterval {
        type == .morning ? TimeInterval(settings.morningReadingDurationSeconds) : type.duration
    }

    private func lengthLabel(for type: ReadingType) -> String {
        type == .morning ? ReadingLength.label(settings.morningReadingDurationSeconds) : type.lengthLabel
    }
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
        .environment(OnboardingStore())
        .modelContainer(for: Reading.self, inMemory: true)
}
