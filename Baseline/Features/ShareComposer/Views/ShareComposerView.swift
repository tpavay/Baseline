import SwiftUI
import UIKit

/// Everything the composer needs, captured at the moment the athlete asks to share.
///
/// Presenting on this rather than a bool is what guarantees the composer always has content: there is
/// no state in which the cover is up and the summary is gone.
struct ShareComposerRequest: Identifiable {
    let id = UUID()
    let summary: WorkoutLogSummary
    let units: ShareUnitResolver
}

/// Baseline-branded post-workout share composer v1.
struct ShareComposerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ShareComposerViewModel
    @State private var isExporting = false
    @State private var toast: String?
    @State private var showAddStat = false
    @State private var showStyle = false

    private let exporter = ShareComposerExporter()

    init(summary: WorkoutLogSummary, units: ShareUnitResolver) {
        _viewModel = State(initialValue: ShareComposerViewModel(summary: summary, units: units))
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            VStack(spacing: 0) {
                ShareComposerHeader(onClose: dismiss.callAsFunction)
                ShareComposerCanvas(viewModel: viewModel)
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
        if !exporter.presentShareSheet(text: viewModel.shareText) {
            showToast("Could not open the share sheet")
        }
    }

    private func shareImage() {
        Task {
            guard let image = await renderImage() else { return }
            if !exporter.presentShareSheet(image: image) {
                showToast("Could not open the share sheet")
            }
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

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ShareCardMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let canvasScale = size.width / ShareCardMetrics.designWidth

            ZStack {
                ShareCardBackground(background: viewModel.background, canvasScale: canvasScale)

                ShareCardHeader(summary: viewModel.summary, canvasScale: canvasScale)
                    .allowsHitTesting(false)

                ForEach($viewModel.stickers) { $sticker in
                    if let stat = viewModel.resolve(sticker) {
                        ShareStickerView(
                            instance: $sticker,
                            stat: stat,
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
                            onDragCancelled: viewModel.cancelDragFeedback
                        )
                    }
                }

                ShareComposerGuides(viewModel: viewModel, canvasSize: size)
                ShareComposerTrash(viewModel: viewModel, canvasSize: size)

                ShareCardWordmark(canvasScale: canvasScale)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel.deselect() }
            // The export clips to the card, so the preview has to as well: anything the athlete cannot
            // see here is not in the image they share.
            .clipShape(cardShape)
            .overlay(cardShape.stroke(BaselineColor.line, lineWidth: BaselineSize.hairline))
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
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
