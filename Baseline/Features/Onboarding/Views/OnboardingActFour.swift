import SwiftUI

// MARK: - Shared picker components

/// A two-option segmented pill (FT-IN / CM, LB / KG). `isRight` false = the left option.
/// `fillsWidth` stretches the segments across the available width; `track` recolors the pill's
/// background so it stays visible when the control sits on a matching surface.
struct Segmented2: View {
    let left: String
    let right: String
    @Binding var isRight: Bool
    var fillsWidth = false
    var track: Color = BaselineColor.surface

    var body: some View {
        HStack(spacing: 4) {
            segment(left, selected: !isRight) { isRight = false }
            segment(right, selected: isRight) { isRight = true }
        }
        .padding(4)
        .background(Capsule().fill(track))
    }

    private func segment(_ title: String, selected: Bool, tap: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            tap()
        } label: {
            Text(title)
                .font(.bMono(11, .bold)).tracking(1)
                .lineLimit(1)
                // A segment label never wraps: the control claims the label's width instead of
                // letting a tight proposal break "IMPERIAL" across two lines.
                .fixedSize()
                .foregroundStyle(selected ? BaselineColor.base : BaselineColor.textMid)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Capsule().fill(selected ? BaselineColor.accent : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

/// A horizontal ruler picker: drag the tick strip under a fixed centre marker; the centred tick is
/// the value. View-aligned scrolling snaps to each tick. Works in integer units; screens convert
/// to/from canonical (cm, kg) around it.
struct TickRulerPicker: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var majorEvery: Int = 5
    var majorLabel: ((Int) -> String)?

    private var ticks: [Int] { Array(range) }
    @State private var centered: Int?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 9) {
                    ForEach(ticks, id: \.self) { tick($0) }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, geo.size.width / 2, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centered, anchor: .center)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(BaselineColor.accent)
                    .frame(width: 2.5, height: 46)
                    .shadow(color: BaselineColor.accent.opacity(0.6), radius: 6)
            }
            .mask(
                // Fade the ruler at both edges so ticks dissolve rather than hard-clip.
                LinearGradient(
                    colors: [.clear, .black, .black, .clear],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .onChange(of: centered) { _, new in
                guard let new, new != value else { return }
                value = new
                Haptics.select()
            }
            .onChange(of: value) { _, v in
                if v != centered { centered = v }
            }
            .onAppear { centered = value }
        }
        .frame(height: 74)
    }

    private func tick(_ t: Int) -> some View {
        let isMajor = t % majorEvery == 0
        return VStack(spacing: 6) {
            Rectangle()
                .fill(isMajor ? BaselineColor.textMid : BaselineColor.line)
                .frame(width: 2, height: isMajor ? 34 : 20)
            Text(isMajor ? (majorLabel?(t) ?? "") : " ")
                .font(.bMono(9)).foregroundStyle(BaselineColor.textFaint)
                .fixedSize()
        }
        .frame(width: 2)
    }
}

/// The big italic accent number that headlines the age/height/weight screens.
private struct BigValue: View {
    let text: String
    var caption: String?
    var body: some View {
        VStack(spacing: 6) {
            Text(text)
                .font(.system(size: 68, weight: .heavy)).italic()
                .foregroundStyle(BaselineColor.accent)
                .contentTransition(.numericText())
            if let caption {
                InstrumentLabel(caption, tracking: 2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A small "why we ask" note (info glyph + text).
private struct InfoNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(BaselineColor.accent)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5)).italic()
                .foregroundStyle(BaselineColor.textMid)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Training experience

struct TrainingExperienceStepView: View {
    @Bindable var store: OnboardingStore

    var body: some View {
        OnboardingStepScaffold(store: store, ctaEnabled: store.canAdvance) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline("Training\nexperience", size: 28)
                Text("We calibrate prescriptions based on your existing athletic background.")
                    .font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                    .lineSpacing(3).padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 12) {
                    ForEach(TrainingExperience.allCases) { experience in
                        ExperienceCard(
                            experience: experience,
                            isSelected: store.draft.experience == experience,
                            action: { store.draft.experience = experience }
                        )
                    }
                }
                .padding(.top, 22)
            }
        }
    }
}

private struct ExperienceCard: View {
    let experience: TrainingExperience
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: experience.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? BaselineColor.accent : BaselineColor.textMid)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10).fill(BaselineColor.base))
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "LEVEL %02d", experience.level))
                        .font(.bMono(9)).tracking(1.5).foregroundStyle(BaselineColor.textFaint)
                    Text(experience.title)
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                    Text(experience.subtitle)
                        .font(.system(size: 12.5)).foregroundStyle(BaselineColor.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? BaselineColor.accent : BaselineColor.line)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(BaselineColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? BaselineColor.accent : BaselineColor.line, lineWidth: isSelected ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Gender

struct GenderStepView: View {
    @Bindable var store: OnboardingStore

    var body: some View {
        OnboardingStepScaffold(store: store, ctaTitle: "NEXT", ctaEnabled: store.canAdvance) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline("Your gender?", size: 28)
                InfoNote(text: "This calibrates population norms during cold start. We use biological markers to ensure higher baseline accuracy.")
                    .padding(.top, 12)

                VStack(spacing: 10) {
                    ForEach(BiologicalSex.allCases) { sex in
                        SelectableCard(
                            title: sex.title,
                            isSelected: store.draft.biologicalSex == sex,
                            action: { store.draft.biologicalSex = sex }
                        ) { EmptyView() }
                    }
                }
                .padding(.top, 24)
            }
        }
    }
}

// MARK: - Age

struct AgeStepView: View {
    @Bindable var store: OnboardingStore

    var body: some View {
        OnboardingStepScaffold(store: store, ctaTitle: "NEXT") {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline("How old\nare you?", size: 28)
                Spacer(minLength: 24)
                BigValue(text: "\(store.draft.ageYears)", caption: "YEARS OLD")
                TickRulerPicker(
                    value: $store.draft.ageYears, range: 13...100,
                    majorEvery: 5, majorLabel: { "\($0)" }
                )
                .padding(.top, 18)
                Spacer(minLength: 24)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Units (imperial vs metric)

/// One global choice that sets sensible per-dimension defaults (imperial → lb + mi, metric → kg + km)
/// and seeds the body height/weight unit toggles so the next two screens open in the same system.
/// Every default stays overridable per exercise later via the workout unit picker.
struct UnitsStepView: View {
    @Bindable var store: OnboardingStore

    private let options: [(system: UnitSystem, title: String, subtitle: String, icon: String)] = [
        (.imperial, "Imperial", "Pounds · miles · feet", "ruler"),
        (.metric, "Metric", "Kilograms · kilometers · centimeters", "ruler.fill"),
    ]

    var body: some View {
        OnboardingStepScaffold(store: store, ctaTitle: "NEXT") {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline("Units of\nmeasure", size: 28)
                InfoNote(text: "Sets the default for weights, distances, and your profile. You can still switch units per exercise anytime.")
                    .padding(.top, 12)

                VStack(spacing: 10) {
                    ForEach(options, id: \.system) { option in
                        SelectableCard(
                            title: option.title,
                            subtitle: option.subtitle,
                            isSelected: store.draft.unitSystem == option.system,
                            action: { select(option.system) }
                        ) {
                            Image(systemName: option.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(store.draft.unitSystem == option.system ? BaselineColor.accent : BaselineColor.textMid)
                                .frame(width: 38, height: 38)
                                .background(RoundedRectangle(cornerRadius: 10).fill(BaselineColor.base))
                        }
                    }
                }
                .padding(.top, 24)
            }
        }
        // Seed the choice (and body-unit flags) only on first entry, so accepting the pre-selected
        // card without tapping still works while a later manual ft/in or lb toggle survives back-nav.
        .onAppear {
            if store.draft.unitSystemRaw == nil { select(store.draft.unitSystem) }
        }
    }

    /// Record the choice and keep the body height/weight toggles coherent with it, so the following
    /// two screens open showing the matching unit.
    private func select(_ system: UnitSystem) {
        store.draft.unitSystem = system
        store.draft.metricHeight = (system == .metric)
        store.draft.metricWeight = (system == .metric)
    }
}

// MARK: - Height

struct HeightStepView: View {
    @Bindable var store: OnboardingStore

    // Ruler works in whole cm or whole inches, converting to/from the canonical cm.
    private var rulerBinding: Binding<Int> {
        Binding(
            get: {
                store.draft.metricHeight
                    ? Int(store.draft.heightCm.rounded())
                    : Int((store.draft.heightCm / MetricConvert.cmPerInch).rounded())
            },
            set: { new in
                store.draft.heightCm = store.draft.metricHeight ? Double(new) : Double(new) * MetricConvert.cmPerInch
            }
        )
    }

    private var display: String {
        if store.draft.metricHeight {
            return "\(Int(store.draft.heightCm.rounded())) cm"
        }
        let inches = Int((store.draft.heightCm / MetricConvert.cmPerInch).rounded())
        return "\(inches / 12)'\(inches % 12)\""
    }

    var body: some View {
        OnboardingStepScaffold(store: store, ctaTitle: "NEXT") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    OnboardingHeadline("How tall\nare you?", size: 28)
                    Spacer()
                    Segmented2(left: "FT-IN", right: "CM", isRight: $store.draft.metricHeight)
                }
                Spacer(minLength: 24)
                BigValue(text: display)
                if store.draft.metricHeight {
                    TickRulerPicker(value: rulerBinding, range: 120...220, majorEvery: 10, majorLabel: { "\($0)" })
                        .padding(.top, 18)
                } else {
                    TickRulerPicker(value: rulerBinding, range: 48...90, majorEvery: 12, majorLabel: { "\($0 / 12)'" })
                        .padding(.top, 18)
                }
                Spacer(minLength: 24)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Weight

struct WeightStepView: View {
    @Bindable var store: OnboardingStore

    private var rulerBinding: Binding<Int> {
        Binding(
            get: {
                store.draft.metricWeight
                    ? Int(store.draft.weightKg.rounded())
                    : Int((store.draft.weightKg / MetricConvert.kgPerPound).rounded())
            },
            set: { new in
                store.draft.weightKg = store.draft.metricWeight ? Double(new) : Double(new) * MetricConvert.kgPerPound
            }
        )
    }

    private var display: String {
        store.draft.metricWeight
            ? "\(Int(store.draft.weightKg.rounded()))"
            : "\(Int((store.draft.weightKg / MetricConvert.kgPerPound).rounded()))"
    }

    var body: some View {
        OnboardingStepScaffold(store: store, ctaTitle: "NEXT") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    OnboardingHeadline("What is\nyour weight?", size: 28)
                    Spacer()
                    Segmented2(left: "LB", right: "KG", isRight: $store.draft.metricWeight)
                }
                Spacer(minLength: 24)
                BigValue(text: display, caption: store.draft.metricWeight ? "KILOGRAMS" : "POUNDS")
                if store.draft.metricWeight {
                    TickRulerPicker(value: rulerBinding, range: 30...200, majorEvery: 10, majorLabel: { "\($0)" })
                        .padding(.top, 18)
                } else {
                    TickRulerPicker(value: rulerBinding, range: 70...400, majorEvery: 20, majorLabel: { "\($0)" })
                        .padding(.top, 18)
                }
                Spacer(minLength: 24)
            }
            .frame(maxHeight: .infinity)
        }
    }
}
