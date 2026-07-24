import SwiftUI

/// A placed sticker with pan, pinch, rotate, snap, and delete interactions.
struct ShareStickerView: View {
    @Binding var instance: ShareStickerInstance
    let stat: ResolvedShareStat
    let canvasSize: CGSize
    var canvasScale: CGFloat = 1
    let isSelected: Bool
    var isOverTrash: Bool = false

    let onSelect: () -> Void
    let onDragChanged: (CGPoint) -> Void
    let snapCenter: (CGPoint) -> CGPoint
    let onDragEnded: (CGPoint) -> Void
    let onDragCancelled: () -> Void

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1
    @GestureState private var gestureRotation: Angle = .zero
    @State private var rotationSnapped = false
    @State private var dragActive = false
    @State private var scaleActive = false
    @State private var rotationActive = false

    private let rotationSnapThreshold = Double.pi / 36
    private let editingHitSlop: CGFloat = 22

    private var transformActive: Bool { scaleActive || rotationActive }

    /// The scale the sticker is actually drawn at. The chrome divides its own line metrics by this so a
    /// hairline outline stays a hairline on a sticker the athlete has pinched to 6x.
    private var effectiveScale: CGFloat {
        max(instance.scale * gestureScale * canvasScale, 0.01)
    }

    private var baseCenter: CGPoint {
        CGPoint(x: instance.position.x * canvasSize.width, y: instance.position.y * canvasSize.height)
    }

    var body: some View {
        let effectiveDrag = transformActive ? .zero : dragTranslation
        let rawCenter = CGPoint(x: baseCenter.x + effectiveDrag.width, y: baseCenter.y + effectiveDrag.height)
        let displayCenter = snapCenter(rawCenter)
        let displayRotation = snappedAngle(instance.rotationRadians + gestureRotation.radians)

        ShareStickerVisual(instance: instance, stat: stat)
            .overlay(selectionChrome)
            .padding(editingHitSlop)
            .contentShape(Rectangle())
            .scaleEffect(effectiveScale * (isOverTrash ? 0.35 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOverTrash)
            .rotationEffect(.radians(displayRotation))
            .position(displayCenter)
            .highPriorityGesture(combinedGesture)
            .onTapGesture(perform: onSelect)
    }

    /// Drawn as an overlay on the sticker content so the outline tracks the real bounds of whatever the
    /// stat renders as — a long value or a chip-style row is boxed correctly rather than to a guess.
    @ViewBuilder
    private var selectionChrome: some View {
        if isSelected {
            let scale = effectiveScale
            RoundedRectangle(cornerRadius: BaselineRadius.control / scale, style: .continuous)
                .stroke(
                    BaselineColor.accent.opacity(0.75),
                    style: StrokeStyle(lineWidth: 1 / scale, dash: [5 / scale, 4 / scale])
                )
                .padding(-6 / scale)
                .allowsHitTesting(false)
        }
    }

    private func snappedAngle(_ radians: Double) -> Double {
        let quarter = Double.pi / 2
        let nearest = (radians / quarter).rounded() * quarter
        return abs(radians - nearest) <= rotationSnapThreshold ? nearest : radians
    }

    private func isNearRotationSnap(_ radians: Double) -> Bool {
        let quarter = Double.pi / 2
        let nearest = (radians / quarter).rounded() * quarter
        return abs(radians - nearest) <= rotationSnapThreshold
    }

    private var combinedGesture: some Gesture {
        let drag = DragGesture()
            .updating($dragTranslation) { value, state, _ in
                guard !transformActive else {
                    state = .zero
                    return
                }
                state = value.translation
            }
            .onChanged { value in
                guard !transformActive else {
                    cancelDragIfNeeded()
                    return
                }
                beginDrag()
                onSelect()
                let center = CGPoint(x: baseCenter.x + value.translation.width, y: baseCenter.y + value.translation.height)
                onDragChanged(center)
            }
            .onEnded { value in
                guard dragActive, !transformActive, canvasSize.width > 0, canvasSize.height > 0 else {
                    cancelDragIfNeeded()
                    return
                }
                let raw = CGPoint(x: baseCenter.x + value.translation.width, y: baseCenter.y + value.translation.height)
                let snapped = snapCenter(raw)
                instance.position = CGPoint(x: snapped.x / canvasSize.width, y: snapped.y / canvasSize.height)
                onDragEnded(snapped)
                dragActive = false
            }

        let magnify = MagnifyGesture()
            .updating($gestureScale) { value, state, _ in state = value.magnification }
            .onChanged { _ in beginScale() }
            .onEnded { value in
                instance.scale = max(0.3, min(instance.scale * value.magnification, 6))
                scaleActive = false
            }

        let rotate = RotateGesture()
            .updating($gestureRotation) { value, state, _ in state = value.rotation }
            .onChanged { value in
                beginRotation()
                let live = instance.rotationRadians + value.rotation.radians
                let near = isNearRotationSnap(live)
                if near && !rotationSnapped { Haptics.tap() }
                rotationSnapped = near
            }
            .onEnded { value in
                rotationSnapped = false
                instance.rotationRadians = snappedAngle(instance.rotationRadians + value.rotation.radians)
                rotationActive = false
            }

        return drag.simultaneously(with: magnify).simultaneously(with: rotate)
    }

    private func beginDrag() {
        dragActive = true
    }

    private func beginScale() {
        onSelect()
        scaleActive = true
        cancelDragIfNeeded()
    }

    private func beginRotation() {
        onSelect()
        rotationActive = true
        cancelDragIfNeeded()
    }

    private func cancelDragIfNeeded() {
        guard dragActive else { return }
        dragActive = false
        onDragCancelled()
    }
}
