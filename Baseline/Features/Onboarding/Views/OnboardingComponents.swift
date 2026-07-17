import SwiftUI

/// Shared onboarding scaffolding: the step layout, headline styles, selectable cards, toggle
/// rows, page dots, and the milestone gradients. Forms stay base-dark; milestones get color.
enum OnboardingStyle {
    /// Full-bleed milestone gradients (the "forms are dark, milestones are loud" rule).
    static let violetMilestone = LinearGradient(
        colors: [Color(hex: 0x6A3FD4), Color(hex: 0x2A1846), BaselineColor.base],
        startPoint: .top, endPoint: .bottom
    )
    static let preDawnMilestone = LinearGradient(
        colors: [Color(hex: 0x1B2350), Color(hex: 0x191430), BaselineColor.base],
        startPoint: .top, endPoint: .bottom
    )
    static let warmGlow = RadialGradient(
        colors: [Color(hex: 0x3E2A50).opacity(0.9), BaselineColor.base],
        center: .center, startRadius: 40, endRadius: 420
    )
}

/// Big italic display headline (the mock language's "GOOD MORNING, TYLER" voice).
struct OnboardingHeadline: View {
    let text: String
    var size: CGFloat = 32
    var color: Color = BaselineColor.textHi
    init(_ text: String, size: CGFloat = 32, color: Color = BaselineColor.textHi) {
        self.text = text
        self.size = size
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .heavy))
            .italic()
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The standard step chrome: back chevron + slim progress, content, pinned CTA.
struct OnboardingStepScaffold<Content: View>: View {
    let store: OnboardingStore
    var eyebrow: String?
    var ctaTitle: String = "CONTINUE"
    var ctaEnabled = true
    var showsChrome = true
    var background: AnyShapeStyle = AnyShapeStyle(BaselineColor.base)
    var onCTA: (() -> Void)?
    var skipTitle: String?
    var onSkip: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Rectangle().fill(background).ignoresSafeArea()

            VStack(spacing: 0) {
                if showsChrome { chrome }

                content
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                Button {
                    Haptics.tap()
                    if let onCTA { onCTA() } else { store.advance() }
                } label: {
                    Text(ctaTitle)
                }
                .buttonStyle(InstrumentButtonStyle(
                    tint: ctaEnabled ? BaselineColor.accent : BaselineColor.surface,
                    textColor: ctaEnabled ? BaselineColor.base : BaselineColor.textFaint
                ))
                .disabled(!ctaEnabled)
                .padding(.bottom, skipTitle == nil ? 18 : 0)

                if let skipTitle, let onSkip {
                    QuietLinkButton(title: skipTitle, action: onSkip)
                        .padding(.top, 14)
                        .padding(.bottom, 14)
                }
            }
            .padding(.horizontal, 26)
        }
    }

    private var chrome: some View {
        HStack(spacing: 14) {
            if store.canGoBack {
                Button {
                    Haptics.tap()
                    store.back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(BaselineColor.textMid)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(BaselineColor.surface))
                }
                .accessibilityLabel("Back")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(BaselineColor.line).frame(height: 3)
                    Capsule().fill(BaselineColor.accent)
                        .frame(width: max(8, geo.size.width * store.progress), height: 3)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 38)
            if let eyebrow {
                InstrumentLabel(eyebrow, tracking: 1.5)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 20)
        .animation(.easeInOut(duration: 0.3), value: store.progress)
    }
}

/// A selectable option card (objective, source, attribution rows).
struct SelectableCard<Leading: View>: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    var isDimmed = false
    var badge: String?
    let action: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: 14) {
                leading
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(isDimmed ? BaselineColor.textFaint : BaselineColor.textHi)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(BaselineColor.textMid)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.bMono(9, .bold)).tracking(1)
                        .foregroundStyle(BaselineColor.base)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(BaselineColor.zoneAmber))
                        .offset(x: -10, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.55 : 1)
    }
}

/// A formula/config toggle row (metric name + subtitle + switch).
struct ConfigToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BaselineColor.accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(BaselineColor.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                Text(subtitle)
                    .font(.bMono(10)).tracking(1)
                    .foregroundStyle(BaselineColor.textFaint)
                    .textCase(.uppercase)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(BaselineColor.accent)
                .onChange(of: isOn) { _, _ in Haptics.select() }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BaselineColor.surface)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BaselineColor.line, lineWidth: 1))
        )
    }
}

/// Carousel page indicator.
struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? BaselineColor.accent : BaselineColor.line)
                    .frame(width: i == index ? 8 : 6, height: i == index ? 8 : 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: index)
    }
}

/// Quiet tertiary text-button (the "skip" voice).
struct QuietLinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title.uppercased())
                .font(.bMono(11, .medium)).tracking(1.5)
                .foregroundStyle(BaselineColor.textFaint)
        }
        .buttonStyle(.plain)
    }
}
