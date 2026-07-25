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
}

/// Visual treatment for a stat sticker.
enum ShareStickerStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case display
    case stacked
    case chip

    var id: String { rawValue }
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
}

/// SwiftUI-free RGBA color stored on the model so view models stay out of SwiftUI.
struct RGBAColor: Equatable, Codable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let textHi = RGBAColor(r: 0.953, g: 0.941, b: 0.973, a: 1)
}

/// One placed sticker on the share canvas.
struct ShareStickerInstance: Identifiable, Equatable {
    let id: UUID
    var kind: ShareStatStickerKind
    var style: ShareStickerStyle
    /// Center point normalized to the canvas, clamped to 0...1 on every write.
    ///
    /// The export canvas clips to the card, so a sticker whose centre escaped the canvas would be
    /// visible while editing and simply absent from the shared image. Clamping here rather than in the
    /// drag handler means no future writer can reintroduce that.
    var position: CGPoint {
        get { normalizedPosition }
        set { normalizedPosition = Self.clampedToCanvas(newValue) }
    }
    private var normalizedPosition: CGPoint
    var scale: CGFloat
    /// Rotation in radians, stored without SwiftUI `Angle`.
    var rotationRadians: Double
    var font: ShareStickerFont
    var color: RGBAColor
    var textBackground: ShareTextBackground

    init(
        id: UUID = UUID(),
        kind: ShareStatStickerKind,
        style: ShareStickerStyle = .display,
        position: CGPoint = CGPoint(x: 0.5, y: 0.5),
        scale: CGFloat = 1,
        rotationRadians: Double = 0,
        font: ShareStickerFont = .baseline,
        color: RGBAColor = .textHi,
        textBackground: ShareTextBackground = .none
    ) {
        self.id = id
        self.kind = kind
        self.style = style
        self.normalizedPosition = Self.clampedToCanvas(position)
        self.scale = scale
        self.rotationRadians = rotationRadians
        self.font = font
        self.color = color
        self.textBackground = textBackground
    }

    private static func clampedToCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}

/// Display-ready stat resolved from canonical Baseline data.
struct ResolvedShareStat: Equatable {
    let kind: ShareStatStickerKind
    let label: String
    let value: String
}
