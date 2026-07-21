import SwiftUI

/// Dynamic Type-aware semantic text styles for Baseline.
///
/// Prose uses the native iOS sans-serif face and instrumentation uses the native
/// monospaced face. This matches the approved prototype's Apple-system fallback
/// without bundling a second copy of platform fonts.
enum BaselineTypography: ViewModifier {
    case screenTitle
    case navigationTitle
    case prose
    case proseSmall
    case rowTitle
    case rowSubtitle
    case instrumentMetric
    case instrumentValue
    case instrumentLabel
    case instrumentMeta
    case button

    var font: Font {
        switch self {
        case .screenTitle:
            .system(.title2, design: .default, weight: .bold)
        case .navigationTitle:
            .system(.headline, design: .default, weight: .semibold)
        case .prose:
            .system(.body, design: .default, weight: .regular)
        case .proseSmall:
            .system(.subheadline, design: .default, weight: .regular)
        case .rowTitle:
            .system(.body, design: .default, weight: .regular)
        case .rowSubtitle:
            .system(.caption, design: .default, weight: .regular)
        case .instrumentMetric:
            .system(.title2, design: .monospaced, weight: .bold)
        case .instrumentValue:
            .system(.title3, design: .monospaced, weight: .bold)
        case .instrumentLabel:
            .system(.caption, design: .monospaced, weight: .semibold)
        case .instrumentMeta:
            .system(.caption, design: .monospaced, weight: .medium)
        case .button:
            .system(.subheadline, design: .monospaced, weight: .bold)
        }
    }

    private var tracking: CGFloat {
        switch self {
        case .screenTitle:
            -0.2
        case .instrumentLabel:
            1.2
        case .instrumentMeta:
            0.4
        case .button:
            0.8
        default:
            0
        }
    }

    func body(content: Content) -> some View {
        content
            .font(font)
            .tracking(tracking)
    }
}

extension View {
    func baselineTypography(_ style: BaselineTypography) -> some View {
        modifier(style)
    }
}
