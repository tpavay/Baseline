import SwiftUI

/// The optional weight step of the morning flow, between the reading's averages and the
/// check-in: one number, prefilled from the most recent known weight, written to Apple Health
/// as body mass on save. Skippable - optional evidence stays optional, and the check-in never
/// blocks on it or on a Health denial.
struct MorningWeightEntryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HealthService.self) private var health

    /// Prefill of last resort, from Baseline's own profile - nil when it never captured one.
    let profileFallbackKilograms: Double?
    /// Called with the confirmed canonical kilograms; the flow records it Baseline-side.
    let onSave: (Double) -> Void
    let onSkip: () -> Void

    @State private var recorder: MorningWeightRecorder?
    @State private var text: String
    @State private var saving = false
    @State private var healthNote: String?
    @FocusState private var focused: Bool

    init(
        profileFallbackKilograms: Double? = nil,
        initialText: String? = nil,   // test seam: reach typed states without a keyboard
        onSave: @escaping (Double) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.profileFallbackKilograms = profileFallbackKilograms
        self.onSave = onSave
        self.onSkip = onSkip
        _text = State(initialValue: initialText ?? "")
    }

    /// The athlete's display unit for a body weight - same door as every load in the app.
    private var unit: MetricUnit { settings.unitSystem.displayUnit(metric: .load, exercise: nil) }
    private var kilograms: Double? { MetricFormat.parse(text, .load, unit: unit) }
    private var isValid: Bool { kilograms.map(MorningWeightPolicy.isValid(kilograms:)) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OnboardingHeadline("This morning's\nweight?", size: 26)
                Spacer()
                Button(action: onSkip) {
                    Text("SKIP").font(.bMono(12, .bold)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                }
            }
            .padding(.top, 12)

            Text("Optional - it keeps your training context current and is saved to Apple Health.")
                .font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Spacer(minLength: 24)

            VStack(spacing: 8) {
                InstrumentLabel("WEIGHT", tracking: 1.5)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("", text: $text, prompt: Text("0").foregroundStyle(BaselineColor.textFaint))
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .font(.bMono(52, .bold))
                        .foregroundStyle(BaselineColor.textHi)
                        .multilineTextAlignment(.center)
                        .fixedSize()   // hug the digits so number + unit center as one readout
                        .frame(minWidth: 44)
                    Text(unit.short.uppercased())
                        .font(.bMono(14)).foregroundStyle(BaselineColor.textFaint)
                }
                if let kilograms, !MorningWeightPolicy.isValid(kilograms: kilograms) {
                    Text("Enter a weight between \(bound(MorningWeightPolicy.kilogramRange.lowerBound)) and \(bound(MorningWeightPolicy.kilogramRange.upperBound)).")
                        .font(.system(size: 12)).foregroundStyle(BaselineColor.zoneAmber)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 24)

            if let healthNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                        .padding(.top, 1)
                    Text(healthNote)
                        .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 12)
            }

            Button { Task { await save() } } label: {
                Text(healthNote == nil ? "SAVE WEIGHT" : "CONTINUE")
            }
            .buttonStyle(InstrumentButtonStyle())
            .disabled(!isValid || saving)
            .opacity(isValid ? 1 : 0.45)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .task { await prefill() }
    }

    private func bound(_ canonicalKilograms: Double) -> String {
        MetricFormat.value(canonicalKilograms, .load, unit: unit)
    }

    private func prefill() async {
        guard recorder == nil else { return }
        let recorder = MorningWeightRecorder(health: health)
        self.recorder = recorder
        guard text.isEmpty,
              let kg = await recorder.prefillKilograms(fallback: profileFallbackKilograms) else { return }
        // Don't clobber anything typed while the Health read was in flight.
        if text.isEmpty { text = MetricFormat.editText(kg, .load, unit: unit) }
    }

    private func save() async {
        guard let kilograms, MorningWeightPolicy.isValid(kilograms: kilograms),
              let recorder, !saving else { return }
        saving = true
        defer { saving = false }
        let outcome = await recorder.record(kilograms: kilograms, on: .now)
        switch outcome {
        case .savedToHealth, .alreadySaved:
            onSave(kilograms)
        case .healthDenied, .healthUnavailable, .healthError:
            // First failure shows the calm note and the button becomes CONTINUE; the next tap
            // re-attempts (in case access was just granted) and then always moves on. The entry
            // itself is never lost - Baseline keeps it either way.
            if healthNote == nil {
                healthNote = note(for: outcome)
            } else {
                onSave(kilograms)
            }
        }
    }

    private func note(for outcome: MorningWeightRecorder.Outcome) -> String? {
        switch outcome {
        case .savedToHealth, .alreadySaved:
            nil   // unreachable: notes exist only for the not-saved outcomes
        case .healthDenied:
            "Not saved to Apple Health - access is off. Baseline keeps your entry; you can allow Weight for Baseline in the Health app anytime."
        case .healthUnavailable:
            "Apple Health isn't available on this device - Baseline keeps your entry."
        case .healthError:
            "Couldn't reach Apple Health right now - Baseline keeps your entry."
        }
    }
}
