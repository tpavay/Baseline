import SwiftUI

/// Which numeric field a validation message or focus belongs to. Shared by the view (focus) and the
/// pure `HeartRateZoneSettingsForm` (per-field messages).
enum HeartRateZoneField { case maxHR, resting, lthr }

/// Real settings screen behind the Profile "Heart Rate Zones" row (retires the `.soon` stub).
///
/// The athlete sees their **max HR** (defaulted from age via Tanaka, editable — never silently
/// replaced), can set a **resting HR** (which switches zones to the more personal Karvonen/HRR
/// method) and an optional **LTHR**, and a live **Z1–Z5 boundary preview** (BPM ranges + zone
/// colors) that recomputes as they edit. Config persists locally via `HeartRateZoneSettingsStore`.
///
/// All parsing, validation, and preview math lives in `HeartRateZoneSettingsForm` (pure) so `body`
/// only renders. A candidate is committed to the store on every edit *only when valid*; an invalid
/// edit is flagged and left in the fields (never discarded) rather than persisted.
struct HeartRateZoneSettingsView: View {
    @State private var store: HeartRateZoneSettingsStore
    @State private var maxHRText = ""
    @State private var restingText = ""
    @State private var lthrText = ""
    @FocusState private var focused: HeartRateZoneField?

    init(store: HeartRateZoneSettingsStore) {
        _store = State(initialValue: store)
    }

    /// Pure presentation snapshot for the current inputs.
    private var form: HeartRateZoneSettingsForm {
        HeartRateZoneSettingsForm(maxHRText: maxHRText, restingText: restingText,
                                  lthrText: lthrText, ageYears: store.ageYears)
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // Primary inputs → chosen method → the live spectrum, kept above the fold so the
                    // edit→zones loop is visible while editing max/resting. Optional LTHR and the
                    // detailed range table follow.
                    maxHRSection
                    restingSection
                    methodSection
                    zoneStripSection
                    lthrSection
                    previewSection
                }
                .padding(20)
            }
        }
        .navigationTitle("Heart Rate Zones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
                    .font(.bMono(13, .bold)).foregroundStyle(BaselineColor.accent)
            }
        }
        .onAppear(perform: seed)
    }

    // MARK: - Sections

    private var maxHRSection: some View {
        section("Max heart rate") {
            fieldCard {
                fieldRow(label: "MAX HR", text: $maxHRText, field: .maxHR,
                         placeholder: "\(form.tanakaEstimate)")
                Hairline().padding(.horizontal, 16)
                HStack {
                    Text(form.maxHRCaption)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BaselineColor.textMid)
                    Spacer()
                    if form.hasMaxOverride {
                        Button {
                            maxHRText = ""
                            commit()
                        } label: {
                            Text("USE AGE ESTIMATE")
                                .font(.bMono(10, .bold)).tracking(1)
                                .foregroundStyle(BaselineColor.accent)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            validationMessage(for: .maxHR)
        }
    }

    private var restingSection: some View {
        section("Resting heart rate") {
            fieldCard {
                fieldRow(label: "RESTING HR", text: $restingText, field: .resting, placeholder: "Off")
                Hairline().padding(.horizontal, 16)
                caption("Set this to use Karvonen (heart-rate reserve) — zones personalized to your range. Leave off for %-of-max zones.")
            }
            validationMessage(for: .resting)
        }
    }

    private var lthrSection: some View {
        section("Lactate threshold (LTHR)") {
            fieldCard {
                fieldRow(label: "LTHR", text: $lthrText, field: .lthr, placeholder: "Off")
                Hairline().padding(.horizontal, 16)
                caption("Optional threshold anchor for future threshold work. Must sit within your aerobic-to-max range.")
            }
            validationMessage(for: .lthr)
        }
    }

    private var methodSection: some View {
        section("Method") {
            HStack(spacing: 12) {
                Image(systemName: form.method == .heartRateReserve ? "chart.line.uptrend.xyaxis" : "percent")
                    .font(.system(size: 15)).foregroundStyle(BaselineColor.accent)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BaselineColor.amethyst))
                VStack(alignment: .leading, spacing: 2) {
                    Text(form.methodTitle)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                    Text(form.methodSubtitle)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textMid)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BaselineColor.surface))
        }
    }

    /// Compact, always-visible spectrum so the edit→zones loop is visible without scrolling to the
    /// detailed table below.
    private var zoneStripSection: some View {
        section("Zones at a glance") {
            HeartRateZoneStrip(model: form.previewModel)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BaselineColor.surface))
        }
    }

    private var previewSection: some View {
        section("Zone ranges") {
            VStack(spacing: 0) {
                ForEach(Array(form.previewRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Hairline().padding(.horizontal, 16) }
                    zoneRow(row)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BaselineColor.surface))
        }
    }

    private func zoneRow(_ row: HeartRateZonePreview.Row) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(row.zone.color)
                .frame(width: 10, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.zone.displayName)
                    .font(.bMono(14, .bold)).foregroundStyle(BaselineColor.textHi)
                Text(row.zone.title)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
            }
            Spacer()
            HStack(spacing: 5) {
                Text(row.rangeText)
                    .font(.bMono(15, .semibold)).foregroundStyle(BaselineColor.textHi)
                    .contentTransition(.numericText())
                Text("BPM")
                    .font(.bMono(10, .medium)).tracking(1).foregroundStyle(BaselineColor.textFaint)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Field building blocks

    private func fieldRow(label: String, text: Binding<String>, field: HeartRateZoneField, placeholder: String) -> some View {
        HStack(spacing: 12) {
            InstrumentLabel(label, tracking: 1)
            Spacer()
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(BaselineColor.textFaint))
                .keyboardType(.numberPad)
                .focused($focused, equals: field)
                .multilineTextAlignment(.trailing)
                .font(.bMono(22, .bold))
                .foregroundStyle(BaselineColor.textHi)
                .frame(maxWidth: 90)
                .onChange(of: text.wrappedValue) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(3))
                    if digits != newValue { text.wrappedValue = digits }
                    commit()
                }
            Text("BPM").font(.bMono(11, .medium)).tracking(1).foregroundStyle(BaselineColor.textFaint)
        }
        .padding(16)
    }

    @ViewBuilder
    private func validationMessage(for field: HeartRateZoneField) -> some View {
        if let message = form.message(for: field) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                Text(message).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(BaselineColor.zoneRed)
            .padding(.horizontal, 4)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium)).italic()
            .foregroundStyle(BaselineColor.textMid)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func fieldCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BaselineColor.surface))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InstrumentLabel(title)
            content()
        }
    }

    // MARK: - State plumbing

    private func seed() {
        let s = store.settings
        maxHRText = s.maxHROverride.map(String.init) ?? ""
        restingText = s.restingHR.map(String.init) ?? ""
        lthrText = s.lthr.map(String.init) ?? ""
    }

    /// Persist the current inputs when (and only when) they form a valid config. Invalid edits stay
    /// in the fields and are surfaced by `validationMessage`; they are never written.
    private func commit() {
        store.update(form.candidate)
    }
}

/// Pure parsing / validation / preview for the settings screen — no SwiftUI, so it is unit-testable
/// and keeps `body` free of logic. Digits-only text is guaranteed by the field's input filter, so an
/// empty field parses to `nil` (unset) and any non-empty field to an `Int`.
struct HeartRateZoneSettingsForm {
    let maxHRText: String
    let restingText: String
    let lthrText: String
    let ageYears: Int?

    private func intOrNil(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    var candidate: HeartRateZoneSettings {
        HeartRateZoneSettings(maxHROverride: intOrNil(maxHRText),
                              restingHR: intOrNil(restingText),
                              lthr: intOrNil(lthrText))
    }

    /// Tanaka(age) estimate shown as the max-HR placeholder / age-derived default.
    var tanakaEstimate: Int { HeartRateZoneModel(age: ageYears).maxHR }

    var hasMaxOverride: Bool { intOrNil(maxHRText) != nil }

    var maxHRCaption: String {
        hasMaxOverride ? "Your entered max HR" : "Estimated from age (Tanaka 208 − 0.7·age)"
    }

    // MARK: Method (honest about inputs)

    var method: HeartRateZoneModel.Method { candidate.method(ageYears: ageYears) }

    var methodTitle: String {
        method == .heartRateReserve ? "Karvonen · Heart-rate reserve" : "Percent of max HR"
    }

    var methodSubtitle: String {
        method == .heartRateReserve
            ? "Zones scaled between resting and max HR"
            : "Set a resting HR to personalize with HRR"
    }

    // MARK: Preview (always well-formed)

    /// A guaranteed non-degenerate model for the live preview / strip: the resolved max HR with a
    /// resting HR only when it validates (an out-of-band resting is dropped from the *preview* while
    /// the error banner explains why it isn't committed). So the preview can render for any input.
    var previewModel: HeartRateZoneModel {
        HeartRateZoneModel(maxHR: max(candidate.resolvedMaxHR(ageYears: ageYears), 1),
                           restingHR: candidate.validatedRestingHR(ageYears: ageYears),
                           lthr: candidate.lthr)
    }

    var previewRows: [HeartRateZonePreview.Row] { HeartRateZonePreview(model: previewModel).rows }

    // MARK: Validation surfacing

    /// The per-field validation message, or `nil` when that field is fine. Maps the config-level
    /// error to the field that owns it so the athlete sees it in context.
    func message(for field: HeartRateZoneField) -> String? {
        guard let error = candidate.validate(ageYears: ageYears) else { return nil }
        switch (error, field) {
        case (.maxHROutOfRange, .maxHR):
            let r = HeartRateZoneSettings.maxHROverrideRange
            return "Enter a max HR between \(r.lowerBound) and \(r.upperBound)."
        case (.restingHROutOfRange, .resting):
            let r = HeartRateZoneSettings.restingHRRange
            return "Enter a resting HR between \(r.lowerBound) and \(r.upperBound)."
        case (.restingNotBelowMax, .resting):
            return "Resting HR must be below your max HR (\(candidate.resolvedMaxHR(ageYears: ageYears)))."
        case (.lthrOutOfBand, .lthr):
            let b = candidate.lthrBand(ageYears: ageYears)
            return "LTHR should be between \(b.lowerBound) and \(b.upperBound) BPM."
        default:
            return nil
        }
    }
}

// MARK: - Previews

#Preview("Default · Tanaka") {
    NavigationStack {
        HeartRateZoneSettingsView(store: HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
    }
    .preferredColorScheme(.dark)
}

#Preview("Resting HR · Karvonen") {
    NavigationStack {
        HeartRateZoneSettingsView(store: HeartRateZoneSettingsStore(
            defaults: .previewSeeded(HeartRateZoneSettings(restingHR: 50)), ageYears: { 32 }))
    }
    .preferredColorScheme(.dark)
}

#Preview("With LTHR") {
    NavigationStack {
        HeartRateZoneSettingsView(store: HeartRateZoneSettingsStore(
            defaults: .previewSeeded(HeartRateZoneSettings(maxHROverride: 190, restingHR: 48, lthr: 170)),
            ageYears: { 30 }))
    }
    .preferredColorScheme(.dark)
}

#Preview("Invalid · bad resting HR") {
    // Seeded (bypassing the gated write) with an out-of-band resting HR to exercise the range-band
    // error banner and the dropped-resting fallback preview. In real use `store.update` refuses this.
    NavigationStack {
        HeartRateZoneSettingsView(store: HeartRateZoneSettingsStore(
            defaults: .previewSeeded(HeartRateZoneSettings(maxHROverride: 180, restingHR: 190)),
            ageYears: { 40 }))
    }
    .preferredColorScheme(.dark)
}

#Preview("Invalid · resting ≥ max") {
    // Both values in-band (max 120, resting 120) so validation reaches the *relational* rule and the
    // distinct "Resting HR must be below your max HR" message renders.
    NavigationStack {
        HeartRateZoneSettingsView(store: HeartRateZoneSettingsStore(
            defaults: .previewSeeded(HeartRateZoneSettings(maxHROverride: 120, restingHR: 120)),
            ageYears: { 40 }))
    }
    .preferredColorScheme(.dark)
}

#Preview("Default · Light") {
    NavigationStack {
        HeartRateZoneSettingsView(store: HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
    }
    .preferredColorScheme(.light)
}

private extension UserDefaults {
    /// A throwaway suite for previews so they never touch or mutate real settings.
    static var previewEmpty: UserDefaults {
        UserDefaults(suiteName: "hr-zone-preview-\(UUID().uuidString)")!
    }

    static func previewSeeded(_ settings: HeartRateZoneSettings) -> UserDefaults {
        let d = previewEmpty
        if let data = try? JSONEncoder().encode(settings) {
            d.set(data, forKey: "heartRateZones.settings")
        }
        return d
    }
}
