import SwiftUI

/// Baseline color tokens for the dark, calm-precision visual system.
///
/// Keep these values aligned with `docs/design-system/README.md` and the approved
/// taxonomy prototype.
enum BaselineColor {
    // Surfaces and text
    static let base      = Color(hex: 0x0C0A10)
    static let surface   = Color(hex: 0x1C1822)
    static let amethyst  = Color(hex: 0x33203E)
    static let accent    = Color(hex: 0x9B6DFF)
    static let textHi    = Color(hex: 0xF3F0F8)
    static let textMid   = Color(hex: 0x9B94A8)
    static let textFaint = Color(hex: 0x6A6478)
    static let line      = Color(hex: 0x272231)

    // Semantic status and heart-rate-zone colors. The brand accent stays separate.
    static let zoneBlue  = Color(hex: 0x4C8DFF)
    static let zoneGreen = Color(hex: 0x34D27B)
    static let zoneAmber = Color(hex: 0xF5A623)
    // Z4 of the existing live heart-rate spectrum: a deep orange seated deliberately between amber
    // (0xF5A623) and red (0xFF5247) so the five zones read as a continuous blue-to-red ramp with no
    // two adjacent hues collapsing. Its green channel (0x7A) sits between amber's (0xA6) and red's
    // (0x52), giving a distinctly oranger step than amber and a warmer one than red. First consumer
    // is the zone-settings preview; reused by the Slice-3 live spectrum.
    static let zoneOrange = Color(hex: 0xFF7A33)
    static let zoneRed   = Color(hex: 0xFF5247)

    // Sleep-stage evidence uses a calm indigo-to-lilac ramp in the violet and amethyst
    // family and OFF the readiness zone hues (green/amber/red/blue) so a stage timeline never reads
    // as a good/bad readiness verdict (plan §2 Q-B). Awake is a muted mauve-grey: present in the
    // night but visibly "not asleep". Ordered dark-to-light by depth.
    static let sleepDeep        = Color(hex: 0x4A3A8C)
    static let sleepCore        = Color(hex: 0x7C6BE0)
    static let sleepREM         = Color(hex: 0xB794F6)
    static let sleepAwake       = Color(hex: 0x5E5670)
    static let sleepUnspecified = Color(hex: 0x6C6480)
}

/// Stable spacing tokens used by shared design-system components.
enum BaselineSpacing {
    static let xxxSmall: CGFloat = 2
    static let xxSmall: CGFloat = 4
    static let xSmall: CGFloat = 8
    static let small: CGFloat = 10
    static let medium: CGFloat = 12
    static let formRowVertical: CGFloat = 14
    static let cardContent: CGFloat = 15
    static let large: CGFloat = 16
    static let screen: CGFloat = 24
}

/// Stable corner-radius tokens from the approved prototype.
enum BaselineRadius {
    static let icon: CGFloat = 9
    static let control: CGFloat = 10
    static let search: CGFloat = 11
    static let action: CGFloat = 12
    static let card: CGFloat = 14
    static let pill: CGFloat = 28
}

/// Stable size tokens for shared controls and visual primitives.
enum BaselineSize {
    static let hairline: CGFloat = 1
    static let icon: CGFloat = 32
    static let iconGlyph: CGFloat = 15
    static let selectionGlyph: CGFloat = 17
    static let minimumTapTarget: CGFloat = 44
    static let primaryActionHeight: CGFloat = 50
    static let pickerRowMinimumHeight: CGFloat = 62
    static let exerciseAsset: CGFloat = 92
}

extension Color {
    /// 0xRRGGBB hex initializer.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
