import SwiftUI
import SwiftData

/// "Ask Baseline" — the Context Engine's surface. Presents the conversation once today's base
/// evidence is assembled, so the agent reasons about the athlete's real state. The tool loop and
/// state live on-device (AgentTools); this view only shows the exchange.
struct AskBaselineSheet: View {
    @Environment(TrainingContextStore.self) private var context
    @Environment(HealthService.self) private var health
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]
    @Query(sort: \ReadinessEntry.date, order: .reverse) private var entries: [ReadinessEntry]

    @State private var service: ConversationService?

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                if let service {
                    ConversationView(service: service)
                } else {
                    ProgressView().tint(BaselineColor.accent)
                }
            }
            .navigationTitle("Baseline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(BaselineColor.accent)
                }
            }
        }
        .task { await setUp() }
    }

    private func setUp() async {
        guard service == nil else { return }
        let today = entries.first { Calendar.current.isDateInToday($0.date) }
        let base = await TodayEvidence.baseInputs(readings: readings, todayEntry: today, health: health)
        service = ConversationService(tools: AgentTools(store: context, base: base))
    }
}

private struct ConversationView: View {
    let service: ConversationService
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if service.log.isEmpty { greeting }
                        ForEach(service.log) { bubble($0) }
                        if service.isThinking { typing }
                    }
                    .padding(16)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: service.log.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: service.isThinking) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            composer
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Baseline").font(.system(size: 20, weight: .bold)).foregroundStyle(BaselineColor.textHi)
            Text("Tell me what changed and I'll adjust today's plan — \u{201C}only 30 minutes\u{201D}, \u{201C}my Achilles hurts\u{201D}, \u{201C}I'm traveling\u{201D} — or ask why.")
                .font(.system(size: 14)).foregroundStyle(BaselineColor.textMid).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    private func bubble(_ m: ConversationService.Message) -> some View {
        HStack {
            if m.role == .you { Spacer(minLength: 40) }
            Text(m.text)
                .font(.system(size: 14.5)).lineSpacing(2)
                .foregroundStyle(m.role == .you ? Color(hex: 0x120B21) : BaselineColor.textHi)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(m.role == .you ? BaselineColor.accent : BaselineColor.surface))
                .overlay(m.role == .you ? nil : RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BaselineColor.line, lineWidth: 1))
            if m.role == .baseline { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: m.role == .you ? .trailing : .leading)
    }

    private var typing: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in Circle().fill(BaselineColor.textFaint).frame(width: 7, height: 7) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft, prompt: Text("Message Baseline\u{2026}").foregroundStyle(BaselineColor.textFaint), axis: .vertical)
                .font(.system(size: 15)).foregroundStyle(BaselineColor.textHi)
                .lineLimit(1...4).focused($inputFocused)
                .padding(.horizontal, 15).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(BaselineColor.surface).overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(BaselineColor.line, lineWidth: 1)))
            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Color(hex: 0x120B21))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSend ? BaselineColor.accent : BaselineColor.line))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        .background(BaselineColor.base)
        .overlay(Rectangle().fill(BaselineColor.line).frame(height: 1), alignment: .top)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !service.isThinking }

    private func send() {
        let text = draft
        draft = ""
        Task { await service.send(text) }
    }
}
