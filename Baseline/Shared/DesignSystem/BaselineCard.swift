import SwiftUI

/// Shared outlined card chrome from the approved taxonomy prototype.
struct BaselineCard<Content: View>: View {
    enum Variant {
        case standard
        case plan

        fileprivate var fill: AnyShapeStyle {
            switch self {
            case .standard:
                AnyShapeStyle(BaselineColor.surface.opacity(0.55))
            case .plan:
                AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            BaselineColor.amethyst.opacity(0.5),
                            BaselineColor.surface.opacity(0.6)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
        }

        fileprivate var border: Color {
            switch self {
            case .standard:
                BaselineColor.line
            case .plan:
                BaselineColor.accent.opacity(0.3)
            }
        }
    }

    private let variant: Variant
    @ViewBuilder private let content: Content

    init(
        variant: Variant = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.variant = variant
        self.content = content()
    }

    var body: some View {
        content
            .padding(BaselineSpacing.cardContent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: BaselineRadius.card)
                    .fill(variant.fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: BaselineRadius.card)
                            .stroke(variant.border, lineWidth: BaselineSize.hairline)
                    }
            }
    }
}

#if DEBUG
#Preview("Cards") {
    VStack(spacing: BaselineSpacing.large) {
        BaselineCard {
            Text("Supporting training context")
                .baselineTypography(.prose)
                .foregroundStyle(BaselineColor.textHi)
        }

        BaselineCard(variant: .plan) {
            VStack(alignment: .leading, spacing: BaselineSpacing.xSmall) {
                Text("TODAY'S PLAN")
                    .baselineTypography(.instrumentLabel)
                    .foregroundStyle(BaselineColor.textFaint)
                Text("Intensity Block 12")
                    .baselineTypography(.navigationTitle)
                    .foregroundStyle(BaselineColor.textHi)
            }
        }
    }
    .padding(BaselineSpacing.screen)
    .background(BaselineColor.base)
    .preferredColorScheme(.dark)
}
#endif
