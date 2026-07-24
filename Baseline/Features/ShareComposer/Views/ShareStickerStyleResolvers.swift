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

    init(_ color: Color) {
        let ui = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    var isTextHi: Bool {
        abs(r - Self.textHi.r) < 0.01 && abs(g - Self.textHi.g) < 0.01
            && abs(b - Self.textHi.b) < 0.01 && a > 0.97
    }
}
