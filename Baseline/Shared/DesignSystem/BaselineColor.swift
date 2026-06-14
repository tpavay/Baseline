import SwiftUI

/// Baseline design tokens — dark "calm precision". Source of truth: docs/design.md.
enum BaselineColor {
    // Surfaces & text
    static let base      = Color(hex: 0x0C0A10)
    static let surface   = Color(hex: 0x1C1822)
    static let amethyst  = Color(hex: 0x33203E)
    static let accent    = Color(hex: 0x9B6DFF)
    static let textHi    = Color(hex: 0xF3F0F8)
    static let textMid   = Color(hex: 0x9B94A8)
    static let textFaint = Color(hex: 0x6A6478)
    static let line      = Color(hex: 0x272231)

    // Recovery zones (semantic — never reused as the brand accent)
    static let zoneBlue  = Color(hex: 0x4C8DFF)
    static let zoneGreen = Color(hex: 0x34D27B)
    static let zoneAmber = Color(hex: 0xF5A623)
    static let zoneRed   = Color(hex: 0xFF5247)
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
