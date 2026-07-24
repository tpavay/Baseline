import SwiftUI

/// SwiftUI-layer resolvers for the SwiftUI-free share-composer model enums.
extension ShareStickerFont {
    func swiftUIFont(size: CGFloat) -> Font {
        switch self {
        case .baseline:
            .system(size: size, weight: .bold, design: .default)
        case .rounded:
            .system(size: size, weight: .bold, design: .rounded)
        case .mono:
            .system(size: size, weight: .bold, design: .monospaced)
        case .thin:
            .system(size: size, weight: .ultraLight)
        case .serif:
            .system(size: size, weight: .semibold, design: .serif)
        }
    }
}

extension RGBAColor {
    var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
