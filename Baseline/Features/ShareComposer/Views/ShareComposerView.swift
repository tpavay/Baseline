import SwiftUI
import UIKit

/// Baseline-branded post-workout share composer v1.
struct ShareComposerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ShareComposerViewModel
    @State private var isExporting = false
    @State private var toast: String?
    @State private var showAddStat = false
    @State private var showStyle = false
    @State private var activeInteraction = false

    private let exporter = ShareComposerExporter()

    init(summary: WorkoutLogSummary, unitForMetric: @escaping (MetricType) -> MetricUnit) {
        _viewModel = State(initialValue: ShareComposerViewModel(summary: summary, unitForMetric: unitForMetric))
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            VStack(spacing: 0) {
                ShareComposerHeader(onClose: dismiss.callAsFunction)
                ShareComposerCanvas(viewModel: viewModel, activeInteraction: $activeInteraction)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                ShareComposerControls(
                    viewModel: viewModel,
                    isExporting: isExporting,
                    onCopyText: copyText,
                    onShareText: shareText,
                    onShareImage: shareImage,
                    onSaveImage: saveImage,
                    onAddStat: { showAddStat = true },
                    onStyle: { showStyle = true }
                )
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .baselineTypography(.button)
                        .foregroundStyle(BaselineColor.textHi)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(BaselineColor.surface.opacity(0.94))
                                .overlay(Capsule(style: .continuous).stroke(BaselineColor.line, lineWidth: 1))
                        )
                        .padding(.bottom, 104)
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showAddStat) {
            ShareAddStatSheet(viewModel: viewModel)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showStyle) {
            ShareStickerStyleSheet(viewModel: viewModel)
                .presentationDetents([.height(320)])
        }
        .preferredColorScheme(.dark)
    }

    private func copyText() {
        UIPasteboard.general.string = viewModel.shareText
        showToast("Copied workout text")
    }

    private func shareText() {
        exporter.presentShareSheet(text: viewModel.shareText)
    }

    private func shareImage() {
        Task {
            guard let image = await renderImage() else { return }
            exporter.presentShareSheet(image: image)
        }
    }

    private func saveImage() {
        Task {
            guard let image = await renderImage() else { return }
            let saved = await exporter.saveToPhotos(image)
            showToast(saved ? "Saved to Photos" : "Photos access not granted")
        }
    }

    private func renderImage() async -> UIImage? {
        isExporting = true
        defer { isExporting = false }
        guard let image = await exporter.renderImage(viewModel: viewModel) else {
            showToast("Could not render image")
            return nil
        }
        return image
    }

    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.16)) {
            toast = message
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.16)) {
                if toast == message { toast = nil }
            }
        }
    }
}

private struct ShareComposerHeader: View {
    let onClose: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                InstrumentLabel("Share workout", color: BaselineColor.accent)
                Text("Compose a Baseline card")
                    .baselineTypography(.navigationTitle)
                    .foregroundStyle(BaselineColor.textHi)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close share composer")
        }
        .padding(.horizontal, BaselineSpacing.screen)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct ShareComposerCanvas: View {
    @Bindable var viewModel: ShareComposerViewModel
    @Binding var activeInteraction: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let canvasScale = size.width / 390

            ZStack {
                ShareCardBackground(background: viewModel.background)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
                    )
                ShareExportHeader(summary: viewModel.summary, canvasScale: canvasScale)
                    .allowsHitTesting(false)

                ForEach($viewModel.stickers) { $sticker in
                    let stats = viewModel.resolvedStats(for: sticker)
                    if stats.isEmpty == false {
                        ShareStickerView(
                            instance: $sticker,
                            stats: stats,
                            canvasSize: size,
                            canvasScale: canvasScale,
                            isSelected: viewModel.selectedID == sticker.id,
                            isOverTrash: viewModel.draggingID == sticker.id && viewModel.isOverTrash,
                            onSelect: { viewModel.select(sticker.id) },
                            onDragChanged: { center in
                                viewModel.handleDragChanged(id: sticker.id, center: center, canvasSize: size)
                            },
                            snapCenter: { viewModel.snappedCenter($0, canvasSize: size) },
                            onDragEnded: { center in
                                viewModel.handleDragEnded(id: sticker.id, center: center, canvasSize: size)
                            },
                            onDragCancelled: viewModel.cancelDragFeedback,
                            onInteractionChanged: { activeInteraction = $0 }
                        )
                    }
                }

                ShareComposerGuides(viewModel: viewModel, canvasSize: size)
                ShareComposerTrash(viewModel: viewModel, canvasSize: size)

                VStack {
                    Spacer()
                    BaselineWordmark(size: 14 * canvasScale, color: BaselineColor.textHi.opacity(0.92))
                        .shadow(color: .black.opacity(0.45), radius: 4 * canvasScale, x: 0, y: 1)
                        .padding(.bottom, 24 * canvasScale)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel.deselect() }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }
}

private struct ShareExportHeader: View {
    let summary: WorkoutLogSummary
    let canvasScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InstrumentLabel("Workout complete", color: BaselineColor.textMid, tracking: 1.8)
            Text(summary.title)
                .font(.system(size: 26 * canvasScale, weight: .bold, design: .default))
                .foregroundStyle(BaselineColor.textHi)
                .lineLimit(3)
                .minimumScaleFactor(0.45)
                .padding(.top, 8 * canvasScale)
            Text(WorkoutPresentationFormatter.elapsedDuration(from: summary.startedAt, to: summary.finishedAt))
                .font(.system(size: 11 * canvasScale, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(BaselineColor.textMid)
                .padding(.top, 10 * canvasScale)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28 * canvasScale)
        .padding(.top, 48 * canvasScale)
    }
}

private struct ShareComposerGuides: View {
    let viewModel: ShareComposerViewModel
    let canvasSize: CGSize

    var body: some View {
        ZStack {
            if let x = viewModel.verticalGuideX {
                Rectangle()
                    .fill(BaselineColor.accent.opacity(0.82))
                    .frame(width: 1, height: canvasSize.height)
                    .position(x: x, y: canvasSize.height / 2)
            }
            if let y = viewModel.horizontalGuideY {
                Rectangle()
                    .fill(BaselineColor.accent.opacity(0.82))
                    .frame(width: canvasSize.width, height: 1)
                    .position(x: canvasSize.width / 2, y: y)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ShareComposerTrash: View {
    let viewModel: ShareComposerViewModel
    let canvasSize: CGSize

    var body: some View {
        if viewModel.draggingID != nil {
            let rect = viewModel.trashRect(in: canvasSize)
            VStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .semibold))
                Text("DELETE")
                    .baselineTypography(.instrumentLabel)
            }
            .foregroundStyle(viewModel.isOverTrash ? BaselineColor.base : BaselineColor.textMid)
            .frame(width: rect.width, height: rect.height)
            .background(
                RoundedRectangle(cornerRadius: BaselineRadius.pill, style: .continuous)
                    .fill(viewModel.isOverTrash ? BaselineColor.zoneRed : BaselineColor.surface.opacity(0.86))
            )
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }
    }
}

private struct ShareComposerControls: View {
    @Bindable var viewModel: ShareComposerViewModel
    let isExporting: Bool
    let onCopyText: () -> Void
    let onShareText: () -> Void
    let onShareImage: () -> Void
    let onSaveImage: () -> Void
    let onAddStat: () -> Void
    let onStyle: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Picker("Background", selection: $viewModel.background) {
                Text("Amethyst").tag(ShareComposerBackground.amethyst)
                Text("Base").tag(ShareComposerBackground.base)
                Text("Green").tag(ShareComposerBackground.green)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Button("Copy", systemImage: "doc.on.doc", action: onCopyText)
                    .accessibilityLabel("Copy workout text")
                Button("Text", systemImage: "square.and.arrow.up", action: onShareText)
                    .accessibilityLabel("Share workout text")
                Button("Image", systemImage: "photo", action: onShareImage)
                    .accessibilityLabel("Share workout image")
                Button("Save", systemImage: "square.and.arrow.down", action: onSaveImage)
                    .accessibilityLabel("Save workout image")
            }
            .buttonStyle(ShareComposerIconButtonStyle())
            .disabled(isExporting)

            HStack(spacing: 10) {
                Button("Add Stat", systemImage: "plus", action: onAddStat)
                    .buttonStyle(InstrumentOutlineButtonStyle(color: BaselineColor.textHi))
                Button("Style", systemImage: "slider.horizontal.3", action: onStyle)
                    .buttonStyle(InstrumentOutlineButtonStyle(color: BaselineColor.textHi))
            }
        }
        .padding(.horizontal, BaselineSpacing.screen)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }
}

private struct ShareComposerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(BaselineColor.textHi)
            .frame(maxWidth: .infinity)
            .frame(height: BaselineSize.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: BaselineRadius.control, style: .continuous)
                    .fill(BaselineColor.surface.opacity(configuration.isPressed ? 0.72 : 0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: BaselineRadius.control, style: .continuous)
                            .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
                    )
            )
    }
}

private struct ShareAddStatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ShareComposerViewModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.availableStats(), id: \.kind) { stat in
                    Button {
                        viewModel.addSticker(kind: stat.kind)
                        dismiss()
                    } label: {
                        HStack {
                            Text(stat.label)
                            Spacer()
                            Text(stat.value)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add Stat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
    }
}

private struct ShareStickerStyleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ShareComposerViewModel

    private var selectedIndex: Int? {
        guard let id = viewModel.selectedID else { return nil }
        return viewModel.stickers.firstIndex { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let selectedIndex {
                    Picker("Style", selection: $viewModel.stickers[selectedIndex].style) {
                        Text("Display").tag(ShareStickerStyle.display)
                        Text("Stacked").tag(ShareStickerStyle.stacked)
                        Text("Chip").tag(ShareStickerStyle.chip)
                    }
                    Picker("Font", selection: $viewModel.stickers[selectedIndex].font) {
                        ForEach(ShareStickerFont.allCases) { font in
                            Text(font.displayName).tag(font)
                        }
                    }
                    Picker("Plate", selection: $viewModel.stickers[selectedIndex].textBackground) {
                        Text("None").tag(ShareTextBackground.none)
                        Text("Dark").tag(ShareTextBackground.dark)
                        Text("Surface").tag(ShareTextBackground.surface)
                    }
                    Picker("Layout", selection: $viewModel.stickers[selectedIndex].layout) {
                        Text("Row").tag(ShareStatLayout.row)
                        Text("Grid").tag(ShareStatLayout.grid)
                        Text("Column").tag(ShareStatLayout.column)
                    }
                } else {
                    Text("Select a sticker to edit its style.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sticker Style")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
    }
}
