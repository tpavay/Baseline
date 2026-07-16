import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct WorkoutImageTransfer: Transferable {
    private let fileURL: URL

    private init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            WorkoutImageTransfer(fileURL: try WorkoutImageTransferFiles.copyProtectedFile(at: received.file))
        }
    }

    func loadData() async throws -> Data {
        try await WorkoutImageTransferFiles.loadDataAndRemove(at: fileURL)
    }
}

struct SourceEvidenceCrop: Identifiable {
    var id: Int { sourceImageIndex }
    let sourceImageIndex: Int
    let normalizedBounds: CGRect
}

enum WorkoutImportProgressCopy {
    static func retryingDetail(completed: Int, total: Int) -> String {
        guard total > 0 else { return "Keep Baseline open until the retry is handed off." }
        return "Progress saved: \(completed) of \(total) sections. Keep Baseline open until the retry is handed off."
    }
}

enum WorkoutImportPreviewRenderer {
    /// Produces a bounded JPEG so review UI never decodes a full OCR source image while scrolling.
    nonisolated static func render(
        data: Data,
        normalizedCrop: CGRect?,
        maximumPixelSize: Int
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        if let normalizedCrop {
            let pixels = CGRect(
                x: normalizedCrop.minX * CGFloat(image.width),
                y: normalizedCrop.minY * CGFloat(image.height),
                width: normalizedCrop.width * CGFloat(image.width),
                height: normalizedCrop.height * CGFloat(image.height)
            ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard pixels.width >= 1, pixels.height >= 1, let cropped = image.cropping(to: pixels) else {
                return nil
            }
            image = cropped
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

struct CachedWorkoutImportPreview: View {
    let data: Data?
    let loadData: (@Sendable () async -> Data?)?
    let normalizedCrop: CGRect?
    let maximumPixelSize: Int
    let cacheID: String
    let accessibilityLabel: String

    @State private var image: UIImage?
    @State private var failed = false

    init(
        data: Data,
        normalizedCrop: CGRect?,
        maximumPixelSize: Int,
        cacheID: String,
        accessibilityLabel: String
    ) {
        self.data = data
        loadData = nil
        self.normalizedCrop = normalizedCrop
        self.maximumPixelSize = maximumPixelSize
        self.cacheID = cacheID
        self.accessibilityLabel = accessibilityLabel
    }

    init(
        loadData: @escaping @Sendable () async -> Data?,
        normalizedCrop: CGRect?,
        maximumPixelSize: Int,
        cacheID: String,
        accessibilityLabel: String
    ) {
        data = nil
        self.loadData = loadData
        self.normalizedCrop = normalizedCrop
        self.maximumPixelSize = maximumPixelSize
        self.cacheID = cacheID
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(accessibilityLabel)
            } else if failed {
                Label("Preview unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(BaselineColor.textFaint)
                    .accessibilityLabel("\(accessibilityLabel). Preview unavailable.")
            } else {
                ProgressView()
                    .tint(BaselineColor.accent)
                    .accessibilityLabel("Preparing \(accessibilityLabel.lowercased())")
            }
        }
        .task(id: cacheID) {
            guard image == nil, !failed else { return }
            let sourceData: Data?
            if let data {
                sourceData = data
            } else {
                sourceData = await loadData?()
            }
            guard let sourceData else {
                failed = true
                return
            }
            let crop = normalizedCrop
            let pixelSize = maximumPixelSize
            let rendered = await Task.detached(priority: .utility) {
                WorkoutImportPreviewRenderer.render(
                    data: sourceData,
                    normalizedCrop: crop,
                    maximumPixelSize: pixelSize
                )
            }.value
            guard !Task.isCancelled else { return }
            image = rendered.flatMap(UIImage.init(data:))
            failed = image == nil
        }
    }
}

struct WorkoutImportView: View {
    private enum FocusTarget: Hashable {
        case selection
        case progress
        case review
        case failure
        case saved
    }

    @Environment(WorkoutStore.self) private var workouts
    @Environment(PlanStore.self) private var plan
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: WorkoutImportViewModel
    @State private var reviewStore: WorkoutStore?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var selectedScheduleDate: Date
    @State private var showCancelConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var showStartOverConfirmation = false
    @State private var showSources = false
    @AccessibilityFocusState private var focusTarget: FocusTarget?

    private let restoresPersistedImport: Bool
    let onScheduled: (ScheduledWorkout) -> Void

    init(suggestedDate: Date? = nil, onScheduled: @escaping (ScheduledWorkout) -> Void = { _ in }) {
        _model = State(initialValue: WorkoutImportViewModel(scheduleDate: suggestedDate))
        _reviewStore = State(initialValue: nil)
        _selectedScheduleDate = State(initialValue: suggestedDate ?? Date())
        restoresPersistedImport = true
        self.onScheduled = onScheduled
    }

#if DEBUG
    init(
        debugSession: ImportSession,
        debugJob: WorkoutImportJob?,
        onScheduled: @escaping (ScheduledWorkout) -> Void = { _ in }
    ) {
        _model = State(initialValue: WorkoutImportViewModel(initialSession: debugSession, initialJob: debugJob))
        _reviewStore = State(initialValue: nil)
        _selectedScheduleDate = State(initialValue: Date())
        restoresPersistedImport = false
        self.onScheduled = onScheduled
    }
#endif

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                if !isReviewing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(toolbarDismissLabel, action: dismissFromToolbar)
                        .foregroundStyle(BaselineColor.textMid)
                    }
                    if showsMoreActions {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                if showsDestructiveImportAction {
                                    Button(destructiveImportLabel, role: .destructive) {
                                        showCancelConfirmation = true
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("More import actions")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSources) {
            WorkoutImportSourceGallery(model: model)
        }
        .confirmationDialog("Cancel this import?", isPresented: $showCancelConfirmation) {
            Button("Cancel import", role: .destructive) {
                model.cancel()
                dismiss()
            }
            Button("Keep importing", role: .cancel) {}
        } message: {
            Text("The saved import progress and server job will be removed.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $showDiscardConfirmation) {
            Button("Discard workout", role: .destructive) {
                model.cancel()
                dismiss()
            }
            Button("Keep reviewing", role: .cancel) {}
        } message: {
            Text("Your imported draft and its source photos will be removed.")
        }
        .confirmationDialog("Start over with other photos?", isPresented: $showStartOverConfirmation) {
            Button("Delete saved import and start over", role: .destructive) {
                model.cancel()
                model = WorkoutImportViewModel(scheduleDate: model.scheduleDate)
                reviewStore = nil
                photoItems = []
            }
            Button("Keep saved import", role: .cancel) {}
        } message: {
            Text("This deletes the saved import progress and all photos already copied into Baseline.")
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            reviewStore = nil
            let identifiers = items.map(\.itemIdentifier)
            let load: @Sendable (Int) async throws -> Data = { index in
                try await withTaskCancellationHandler {
                    do {
                        guard let transfer = try await items[index]
                            .loadTransferable(type: WorkoutImageTransfer.self) else {
                            throw WorkoutImagePipelineError.unreadable
                        }
                        return try await transfer.loadData()
                    } catch is CancellationError {
                        WorkoutImageTransferFiles.removeAll()
                        throw CancellationError()
                    } catch let error as WorkoutImagePipelineError {
                        WorkoutImageTransferFiles.removeAll()
                        throw error
                    } catch {
                        WorkoutImageTransferFiles.removeAll()
                        throw WorkoutImagePipelineError.unreadable
                    }
                } onCancel: {
                    WorkoutImageTransferFiles.removeAll()
                }
            }
            if model.requiresSourceReselection {
                model.reconcileMissingSources(
                    count: items.count,
                    catalog: workouts.allDefinitions,
                    loadImage: load
                )
            } else {
                model.importImages(
                    count: items.count,
                    sourceItemIdentifiers: identifiers,
                    catalog: workouts.allDefinitions,
                    loadImage: load
                )
            }
            Task { @MainActor in
                photoItems = []
            }
        }
        .onChange(of: model.session.status) { _, status in
            prepareReviewStore(for: status)
            moveAccessibilityFocus(for: status)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.suspendForBackground()
            case .active:
                if restoresPersistedImport, model.currentJob != nil {
                    model.restore(catalog: workouts.allDefinitions)
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .task {
            if restoresPersistedImport {
                await model.restore(catalog: workouts.allDefinitions).value
            }
            prepareReviewStore(for: model.session.status)
            moveAccessibilityFocus(for: model.session.status)
        }
        .onDisappear {
            model.pause()
        }
        .interactiveDismissDisabled(isReviewing && !model.reviewDraftIsPersisted)
    }

    private var title: String {
        switch model.session.status {
        case .reviewing, .saving: "Review Workout"
        case .saved: "Workout saved"
        default: "Import workout"
        }
    }

    private var isReviewing: Bool {
        if case .reviewing = model.session.status { return true }
        return false
    }

    private var hasDurableHandoff: Bool {
        model.hasDurableCheckpoint
    }

    private var toolbarDismissLabel: String {
        if model.savedTemplate != nil { return "Done" }
        return hasDurableHandoff ? "Close" : "Cancel"
    }

    private var showsDestructiveImportAction: Bool {
        model.savedTemplate == nil && hasDurableHandoff
    }

    private var sourceCount: Int {
        max(model.session.sourceImages.count, model.session.sourcePages.count)
    }

    private var showsMoreActions: Bool {
        showsDestructiveImportAction || (isReviewing && sourceCount > 0)
    }

    private var destructiveImportLabel: String {
        isReviewing ? "Discard workout" : "Cancel import"
    }

    private func dismissFromToolbar() {
        if model.savedTemplate != nil {
            dismiss()
        } else if isReviewing {
            guard model.reviewDraftIsPersisted else { return }
            model.pause()
            dismiss()
        } else if hasDurableHandoff {
            model.pause()
            dismiss()
        } else {
            model.cancel()
            dismiss()
        }
    }

    private func moveAccessibilityFocus(for status: WorkoutImportStatus) {
        let target: FocusTarget
        switch status {
        case .selecting: target = .selection
        case .loadingImages, .recognizing, .preparingSections, .waitingForHandoff,
             .retryingSections, .processingSections, .parsing, .saving: target = .progress
        case .reviewing: target = .review
        case .saved: target = .saved
        case .failed: target = .failure
        }
        Task { @MainActor in
            await Task.yield()
            focusTarget = target
        }
    }

    @ViewBuilder private var content: some View {
        switch model.session.status {
        case .selecting:
            ScrollView { selection }
                .accessibilityFocused($focusTarget, equals: .selection)
        case .loadingImages(let completed, let total):
            progress(
                "Creating your workout",
                status: "Preparing photos",
                detail: total > 0
                    ? "Image \(min(completed + 1, total)) of \(total). Large iCloud photos can take a moment."
                    : ""
            )
        case .recognizing(let completed, let total):
            progress(
                "Creating your workout",
                status: "Reading workout",
                detail: total > 0
                    ? "Finished \(completed) of \(total) photos privately on your iPhone."
                    : "This happens privately on your iPhone."
            )
        case .preparingSections:
            progress(
                "Creating your workout",
                status: "Organizing exercises",
                detail: "Baseline is separating exercises, notes, and workout sections."
            )
        case .waitingForHandoff:
            progress(
                "Creating your workout",
                status: "Organizing exercises",
                detail: "Keep Baseline open until the workout is handed off. This usually takes a moment."
            )
        case .retryingSections(let completed, let total):
            progress(
                "Creating your workout",
                status: "Organizing exercises",
                detail: WorkoutImportProgressCopy.retryingDetail(completed: completed, total: total)
            )
        case .processingSections(let completed, let total):
            progress(
                "Creating your workout",
                status: total > 0 && completed >= total ? "Preparing editor" : "Organizing exercises",
                detail: "You can close this screen. Baseline will keep working."
            )
        case .parsing:
            progress(
                "Creating your workout",
                status: "Organizing exercises",
                detail: "Baseline is translating the text into editable exercises and sets."
            )
        case .reviewing:
            review.accessibilityFocused($focusTarget, equals: .review)
        case .saving:
            progress("Saving workout", status: nil, detail: "")
        case .saved:
            ScrollView { saved }
                .accessibilityFocused($focusTarget, equals: .saved)
        case .failed(let message):
            ScrollView { failure(message) }
                .accessibilityFocused($focusTarget, equals: .failure)
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(BaselineColor.accent)
                .accessibilityHidden(true)
            Text("Turn workout photos into a native Baseline template.")
                .font(.title2.weight(.bold))
                .foregroundStyle(BaselineColor.textHi)
            Text("Choose up to 10 clear images in workout order. Baseline keeps longer instructions as notes, and you’ll review everything before it is saved.")
                .font(.body)
                .foregroundStyle(BaselineColor.textMid)
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: WorkoutImageImportLimits.maximumImageCount,
                selectionBehavior: .ordered,
                matching: .images
            ) {
                importButton("Choose workout photos", systemImage: "photo.stack")
            }
            Spacer()
        }
        .padding(24)
    }

    nonisolated private func importButton(_ label: String, systemImage: String) -> some View {
        Label(label, systemImage: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(hex: 0x120B21))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 14).fill(BaselineColor.accent))
            .contentShape(Rectangle())
    }

    private func progress(_ headline: String, status: String?, detail: String) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    ProgressView().tint(BaselineColor.accent).scaleEffect(1.2)
                    Text(headline)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(BaselineColor.textHi)
                    if let status {
                        Text(status)
                            .font(.body.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(BaselineColor.accent)
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(BaselineColor.textMid)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(0, geometry.size.height - 60)
                )
                .padding(30)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityFocused($focusTarget, equals: .progress)
    }

    @ViewBuilder private var review: some View {
        if let reviewStore {
            WorkoutImportReviewView(
                model: model,
                sourceCount: sourceCount,
                onClose: dismissFromToolbar,
                onViewSources: { showSources = true },
                onDiscard: { showDiscardConfirmation = true }
            )
                .environment(reviewStore)
        } else {
            ProgressView()
                .tint(BaselineColor.accent)
                .task { prepareReviewStore(for: model.session.status) }
        }
    }

    private func prepareReviewStore(for status: WorkoutImportStatus) {
        guard case .reviewing = status,
              reviewStore == nil,
              let workout = model.session.draft?.workout,
              !workout.allExercises.isEmpty else { return }
        reviewStore = WorkoutStore(transientWorkout: workout, configurationFrom: workouts)
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(BaselineColor.zoneGreen)
                .accessibilityHidden(true)
            Text("Template saved")
                .font(.title2.weight(.bold))
                .foregroundStyle(BaselineColor.textHi)
            Text("It is now a normal Baseline workout template - fully editable and reusable.")
                .font(.body)
                .foregroundStyle(BaselineColor.textMid)
            DatePicker("Add to plan", selection: $selectedScheduleDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .foregroundStyle(BaselineColor.textHi)
                .tint(BaselineColor.accent)
            if let error = model.scheduleError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(BaselineColor.zoneAmber)
                    .accessibilityLabel("Scheduling failed. \(error)")
            }
            Button {
                if let scheduled = model.addSavedTemplateToPlan(selectedScheduleDate, plan: plan) {
                    onScheduled(scheduled)
                    dismiss()
                }
            } label: {
                importButton("Add to plan", systemImage: "calendar.badge.plus")
            }
            Button("Done") { dismiss() }
                .foregroundStyle(BaselineColor.textMid)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            Spacer()
        }
        .padding(24)
    }

    private func failure(_ message: String) -> some View {
        let missingSourceCount = model.missingSourceCount

        return VStack(spacing: 16) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 42))
                .foregroundStyle(BaselineColor.zoneRed)
                .accessibilityHidden(true)
            Text("Import didn't finish")
                .font(.title3.weight(.bold))
                .foregroundStyle(BaselineColor.textHi)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(BaselineColor.textMid)
            if model.canRetry {
                Button("Try again") {
                    model.retry(catalog: workouts.allDefinitions)
                }
                .buttonStyle(WorkoutImportPrimaryButtonStyle())
            }
            if model.requiresSourceReselection {
                PhotosPicker(
                    selection: $photoItems,
                    maxSelectionCount: missingSourceCount,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    importButton(
                        missingSourceCount == 1
                            ? "Choose 1 remaining photo"
                            : "Choose \(missingSourceCount) remaining photos",
                        systemImage: "photo.badge.plus"
                    )
                }
                .accessibilityHint("Keeps saved photos and fills only the missing positions")
            }
            Button("Start over with other photos") {
                showStartOverConfirmation = true
            }
            .foregroundStyle(BaselineColor.accent)
            .font(.body.weight(.semibold))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .padding(28)
    }
}

struct WorkoutImportPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(hex: 0x120B21))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isEnabled ? BaselineColor.accent : BaselineColor.textFaint)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(Rectangle())
    }
}
