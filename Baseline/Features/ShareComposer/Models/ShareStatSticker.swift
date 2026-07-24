import CoreGraphics
import Foundation

/// A Baseline workout stat that can be dropped onto the share canvas as a draggable sticker.
///
/// Stat stickers are typed references whose values are resolved live from the completed workout.
/// Adding a stat is a new catalog case plus resolver branch, not a new visual path.
enum ShareStatStickerKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case workoutName
    case date
    case duration
    case exerciseCount
    case totalSets
    case totalReps
    case totalVolume
    case heaviestLoad
    case totalDistance
    case totalDuration
    case totalCalories
    case avgPace

    var id: String { rawValue }

    var supportsComposite: Bool { true }
}

/// Visual treatment for a stat sticker.
enum ShareStickerStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case display
    case stacked
    case chip

    var id: String { rawValue }

    func next() -> ShareStickerStyle {
        let all = ShareStickerStyle.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

/// System-font-only type choices for v1.
enum ShareStickerFont: String, CaseIterable, Identifiable, Codable, Sendable {
    case baseline
    case rounded
    case mono
    case thin
    case serif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .baseline: return "Baseline"
        case .rounded: return "Round"
        case .mono: return "Mono"
        case .thin: return "Thin"
        case .serif: return "Serif"
        }
    }
}

/// Optional backing plate behind sticker text for legibility.
enum ShareTextBackground: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case dark
    case surface

    var id: String { rawValue }

    func next() -> ShareTextBackground {
        let all = ShareTextBackground.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

/// SwiftUI-free RGBA color stored on the model so view models stay out of SwiftUI.
struct RGBAColor: Equatable, Codable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let textHi = RGBAColor(r: 0.953, g: 0.941, b: 0.973, a: 1)
    static let accent = RGBAColor(r: 0.608, g: 0.427, b: 1, a: 1)
    static let green = RGBAColor(r: 0.204, g: 0.824, b: 0.482, a: 1)
    static let blue = RGBAColor(r: 0.298, g: 0.553, b: 1, a: 1)
}

/// Arrangement for a multi-metric sticker.
enum ShareStatLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case row
    case grid
    case column

    var id: String { rawValue }
}

/// A reference to one resolvable stat.
struct ShareStatRef: Hashable, Codable, Sendable {
    var kind: ShareStatStickerKind
}

/// One placed sticker on the share canvas.
struct ShareStickerInstance: Identifiable, Equatable {
    let id: UUID
    var kind: ShareStatStickerKind
    var style: ShareStickerStyle
    /// Center point normalized to the canvas, 0...1.
    var position: CGPoint
    var scale: CGFloat
    /// Rotation in radians, stored without SwiftUI `Angle`.
    var rotationRadians: Double
    var font: ShareStickerFont
    var color: RGBAColor
    var textBackground: ShareTextBackground
    var extraStats: [ShareStatRef]
    var layout: ShareStatLayout

    var primaryStatRef: ShareStatRef { ShareStatRef(kind: kind) }
    var statRefs: [ShareStatRef] { [primaryStatRef] + extraStats }
    var isComposite: Bool { !extraStats.isEmpty }

    init(
        id: UUID = UUID(),
        kind: ShareStatStickerKind,
        style: ShareStickerStyle = .display,
        position: CGPoint = CGPoint(x: 0.5, y: 0.5),
        scale: CGFloat = 1,
        rotationRadians: Double = 0,
        font: ShareStickerFont = .baseline,
        color: RGBAColor = .textHi,
        textBackground: ShareTextBackground = .none,
        extraStats: [ShareStatRef] = [],
        layout: ShareStatLayout = .row
    ) {
        self.id = id
        self.kind = kind
        self.style = style
        self.position = position
        self.scale = scale
        self.rotationRadians = rotationRadians
        self.font = font
        self.color = color
        self.textBackground = textBackground
        self.extraStats = extraStats
        self.layout = layout
    }
}

/// Display-ready stat resolved from canonical Baseline data.
struct ResolvedShareStat: Equatable {
    let kind: ShareStatStickerKind
    let label: String
    let value: String
}
