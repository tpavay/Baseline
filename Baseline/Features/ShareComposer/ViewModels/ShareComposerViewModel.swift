import CoreGraphics
import Foundation
import Observation
import UIKit

/// Owns share-composer editing state.
///
/// This stays SwiftUI-free by design: Foundation, Observation, CoreGraphics, and UIKit only.
@MainActor
@Observable
final class ShareComposerViewModel {
    let summary: WorkoutLogSummary
    private let unitForMetric: (MetricType) -> MetricUnit

    var stickers: [ShareStickerInstance]
    var selectedID: UUID?
    var background: ShareComposerBackground = .amethyst

    var draggingID: UUID?
    var verticalGuideX: CGFloat?
    var horizontalGuideY: CGFloat?
    var isOverTrash = false

    private let snapThreshold: CGFloat = 18

    init(
        summary: WorkoutLogSummary,
        unitForMetric: @escaping (MetricType) -> MetricUnit
    ) {
        self.summary = summary
        self.unitForMetric = unitForMetric
        self.stickers = Self.defaultStickers(for: summary)
        self.selectedID = stickers.first?.id
    }

    private var resolver: BaselineShareStatResolver {
        BaselineShareStatResolver(summary: summary, unitForMetric: unitForMetric)
    }

    var shareText: String {
        WorkoutShareTextSummary.make(from: summary, unitForMetric: unitForMetric)
    }

    func availableStats() -> [ResolvedShareStat] {
        resolver.availableKinds().compactMap { resolver.resolve($0) }
    }

    func resolved(_ ref: ShareStatRef) -> ResolvedShareStat? {
        resolver.resolve(ref.kind)
    }

    func resolvedStats(for instance: ShareStickerInstance) -> [ResolvedShareStat] {
        instance.statRefs.compactMap { resolved($0) }
    }

    func resolve(_ instance: ShareStickerInstance) -> ResolvedShareStat? {
        resolved(instance.primaryStatRef)
    }

    func paletteRefs(for instance: ShareStickerInstance) -> [ShareStatRef] {
        resolver.availableKinds()
            .filter(\.supportsComposite)
            .map(ShareStatRef.init(kind:))
    }

    func setLayout(_ layout: ShareStatLayout, for id: UUID) {
        guard let i = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[i].layout = layout
    }

    /// Add/remove a metric on a composite sticker. Keeps at least one metric and caps the total at 4.
    func toggleStat(_ ref: ShareStatRef, for id: UUID) {
        guard let i = stickers.firstIndex(where: { $0.id == id }) else { return }
        var sticker = stickers[i]
        guard sticker.kind.supportsComposite, ref.kind.supportsComposite else { return }
        if sticker.primaryStatRef == ref {
            guard !sticker.extraStats.isEmpty else { return }
            let promoted = sticker.extraStats.removeFirst()
            sticker.kind = promoted.kind
        } else if let idx = sticker.extraStats.firstIndex(of: ref) {
            sticker.extraStats.remove(at: idx)
        } else if sticker.statRefs.count < 4 {
            sticker.extraStats.append(ref)
        }
        stickers[i] = sticker
    }

    func addSticker(kind: ShareStatStickerKind, style: ShareStickerStyle = .display) {
        let offset = CGFloat(stickers.count % 5) * 0.04
        let instance = ShareStickerInstance(
            kind: kind,
            style: style,
            position: CGPoint(x: 0.5, y: 0.36 + offset)
        )
        stickers.append(instance)
        selectedID = instance.id
    }

    func deleteSticker(_ id: UUID) {
        stickers.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func select(_ id: UUID) {
        selectedID = id
    }

    func deselect() {
        selectedID = nil
    }

    func trashRect(in canvasSize: CGSize) -> CGRect {
        let w: CGFloat = 150
        let h: CGFloat = 84
        return CGRect(x: (canvasSize.width - w) / 2, y: canvasSize.height - h - 24, width: w, height: h)
    }

    private func verticalSnapTargets(_ canvasSize: CGSize) -> [CGFloat] {
        [canvasSize.width / 2, canvasSize.width * 0.12, canvasSize.width * 0.88]
    }

    private func horizontalSnapTargets(_ canvasSize: CGSize) -> [CGFloat] {
        [canvasSize.height / 2]
    }

    func handleDragChanged(id: UUID, center: CGPoint, canvasSize: CGSize) {
        let isNewDrag = draggingID != id
        draggingID = id
        if isNewDrag { Haptics.tap() }

        let nowOverTrash = trashRect(in: canvasSize).contains(center)
        if nowOverTrash && !isOverTrash { Haptics.milestone() }
        isOverTrash = nowOverTrash

        let newVX = verticalSnapTargets(canvasSize).first { abs(center.x - $0) <= snapThreshold }
        if newVX != nil, verticalGuideX == nil { Haptics.tap() }
        verticalGuideX = newVX

        let newHY = horizontalSnapTargets(canvasSize).first { abs(center.y - $0) <= snapThreshold }
        if newHY != nil, horizontalGuideY == nil { Haptics.tap() }
        horizontalGuideY = newHY
    }

    func snappedCenter(_ raw: CGPoint, canvasSize: CGSize) -> CGPoint {
        let x = verticalSnapTargets(canvasSize).first { abs(raw.x - $0) <= snapThreshold } ?? raw.x
        let y = horizontalSnapTargets(canvasSize).first { abs(raw.y - $0) <= snapThreshold } ?? raw.y
        return CGPoint(x: x, y: y)
    }

    func handleDragEnded(id: UUID, center: CGPoint, canvasSize: CGSize) {
        if trashRect(in: canvasSize).contains(center) {
            deleteSticker(id)
        }
        cancelDragFeedback()
    }

    func cancelDragFeedback() {
        draggingID = nil
        isOverTrash = false
        verticalGuideX = nil
        horizontalGuideY = nil
    }

    private static func defaultStickers(for summary: WorkoutLogSummary) -> [ShareStickerInstance] {
        var stats: [ShareStickerInstance] = [
            ShareStickerInstance(kind: .duration, style: .display, position: CGPoint(x: 0.28, y: 0.46), scale: 1.15),
            ShareStickerInstance(kind: .totalSets, style: .display, position: CGPoint(x: 0.72, y: 0.46), scale: 1.15)
        ]

        if summary.totalVolumeKilograms > 0 {
            stats.append(
                ShareStickerInstance(
                    kind: .totalVolume,
                    style: .chip,
                    position: CGPoint(x: 0.5, y: 0.62),
                    scale: 1.15,
                    textBackground: .dark
                )
            )
        } else if summary.totalDistanceMeters > 0 {
            stats.append(
                ShareStickerInstance(
                    kind: .totalDistance,
                    style: .chip,
                    position: CGPoint(x: 0.5, y: 0.62),
                    scale: 1.15,
                    textBackground: .dark
                )
            )
        }
        return stats
    }
}

enum ShareComposerBackground: String, CaseIterable, Identifiable {
    case amethyst
    case base
    case green

    var id: String { rawValue }
}
