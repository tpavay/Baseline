import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
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
    /// Stages that run on the device pause when Baseline is backgrounded and resume from persisted
    /// page progress on return - nothing is lost, but nothing advances while the app is away.
    static let localStageFootnote =
        "This runs on your iPhone, so it pauses if you leave Baseline and picks up where it left off when you return."

    /// Once the parser owns the job the server keeps working regardless of the app, and foreground
    /// restoration fetches the durable result. Saying otherwise would be a lie.
    static let serverStageFootnote =
        "You can close this screen - the import keeps running on Baseline's server and the result will be here when you come back."

    static func retryingDetail(completed: Int, total: Int) -> String {
        guard total > 0 else { return "Keep Baseline open until the retry is handed off." }
        return "Progress saved: \(completed) of \(total) sections. Keep Baseline open until the retry is handed off."
    }

    /// The server reports queued separately from processing, so the wait can admit the import is in
    /// line behind other work rather than implying a section is actively being parsed.
    static func processingStatus(isQueued: Bool, completed: Int, total: Int) -> String {
        if isQueued { return "Waiting for a parser slot" }
        if total > 0, completed >= total { return "Preparing editor" }
        return "Organizing exercises"
    }

    static func processingDetail(isQueued: Bool, completed: Int, total: Int) -> String {
        if isQueued {
            return "Your import is in line and hasn't started yet. \(serverStageFootnote)"
        }
        guard total > 0 else { return serverStageFootnote }
        return "\(completed) of \(total) sections organized. \(serverStageFootnote)"
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
    /// An unfinished import that belongs to another day; presented as a Resume / Start-new choice instead
    /// of silently reappearing on this day.
    @State private var pendingOtherDayImport: WorkoutImportPendingSummary?
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
            syncKeepAwake()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.suspendForBackground()
                // Never hold the idle timer while Baseline is away; `.active` re-applies it if the
                // import is still working. A leaked disable would drain the battery invisibly.
                releaseKeepAwake()
            case .active:
                if restoresPersistedImport, let job = model.currentJob {
                    model.restore(jobID: job.id, catalog: workouts.allDefinitions)
                }
                syncKeepAwake()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .confirmationDialog(
            "Unfinished import",
            isPresented: Binding(
                get: { pendingOtherDayImport != nil },
                set: { if !$0 { pendingOtherDayImport = nil } }
            ),
            presenting: pendingOtherDayImport
        ) { summary in
            Button(resumeLabel(for: summary)) {
                let jobID = summary.jobID
                pendingOtherDayImport = nil
                Task { await model.restore(jobID: jobID, catalog: workouts.allDefinitions).value }
            }
            Button("Start a new import") { pendingOtherDayImport = nil }
            Button("Cancel", role: .cancel) {
                pendingOtherDayImport = nil
                dismiss()
            }
        } message: { summary in
            Text(pendingImportMessage(for: summary))
        }
        .task {
            if restoresPersistedImport {
                await resolvePendingImport()
            }
            prepareReviewStore(for: model.session.status)
            moveAccessibilityFocus(for: model.session.status)
        }
        .onAppear { syncKeepAwake() }
        .onDisappear {
            model.pause()
            // Leaving the import - dismissed, cancelled, saved, or failed - always restores normal
            // idle behavior. This is the last line of defence behind the per-status sync above.
            releaseKeepAwake()
        }
        .interactiveDismissDisabled(isReviewing && !model.reviewDraftIsPersisted)
    }

    /// Hold the display on only while an import is actually working. A photo import can run for a
    /// minute or more, and a screen that dims and locks mid-run reads as a hang. Review, save, the
    /// saved confirmation, failure, and the picker all keep normal idle behavior.
    private func syncKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = Self.shouldKeepScreenAwake(for: model.session.status)
    }

    private func releaseKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Pure status→keep-awake mapping so the "only while working" rule is testable without a view tree.
    static func shouldKeepScreenAwake(for status: WorkoutImportStatus) -> Bool {
        switch status {
        case .loadingImages, .recognizing, .preparingSections, .waitingForHandoff,
             .retryingSections, .processingSections, .parsing:
            true
        case .selecting, .reviewing, .saving, .saved, .failed:
            false
        }
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

    /// Decide, on appear, how a persisted unfinished import relates to the day this screen was opened for.
    /// Same day → resume silently. No target day (e.g. a non-day entry) → resume the most recent. A draft
    /// for a *different* day → offer Resume / Start-new instead of silently reappearing here.
    private func resolvePendingImport() async {
        guard model.currentJob == nil else { return }
        let pendings = await model.pendingImports()
        switch PendingImportResolution.decide(
            pendings: pendings,
            targetDay: model.scheduleDate,
            calendar: .planWeek
        ) {
        case .resume(let jobID):
            await model.restore(jobID: jobID, catalog: workouts.allDefinitions).value
        case .promptOther(let summary):
            pendingOtherDayImport = summary
        case .fresh:
            break
        }
    }

    private func resumeLabel(for summary: WorkoutImportPendingSummary) -> String {
        guard let day = summary.scheduleDate else { return "Resume unfinished import" }
        return "Resume \(day.formatted(.dateTime.weekday(.wide)))'s import"
    }

    private func pendingImportMessage(for summary: WorkoutImportPendingSummary) -> String {
        let lead: String
        if let day = summary.scheduleDate {
            lead = "You have an unfinished import for \(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))."
        } else {
            lead = "You have an unfinished import in progress."
        }
        return lead + " Resume it, or start a new import for this day."
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
                    ? "Photo \(min(completed + 1, total)) of \(total). Large iCloud photos can take a moment. \(WorkoutImportProgressCopy.localStageFootnote)"
                    : WorkoutImportProgressCopy.localStageFootnote,
                steps: (completed, total)
            )
        case .recognizing(let completed, let total):
            progress(
                "Creating your workout",
                status: "Reading workout",
                detail: total > 0
                    ? "Finished \(completed) of \(total) photos privately on your iPhone. \(WorkoutImportProgressCopy.localStageFootnote)"
                    : "This happens privately on your iPhone. \(WorkoutImportProgressCopy.localStageFootnote)",
                steps: (completed, total)
            )
        case .preparingSections:
            progress(
                "Creating your workout",
                status: "Organizing exercises",
                detail: "Baseline is separating exercises, notes, and workout sections. \(WorkoutImportProgressCopy.localStageFootnote)"
            )
        case .waitingForHandoff:
            progress(
                "Creating your workout",
                status: "Sending to the parser",
                detail: "Keep Baseline open until the workout is handed off. \(WorkoutImportProgressCopy.localStageFootnote)"
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
                status: WorkoutImportProgressCopy.processingStatus(
                    isQueued: model.isQueuedOnServer,
                    completed: completed,
                    total: total
                ),
                detail: WorkoutImportProgressCopy.processingDetail(
                    isQueued: model.isQueuedOnServer,
                    completed: completed,
                    total: total
                ),
                // A queued job has no section underway, so an empty determinate bar would overstate it.
                steps: model.isQueuedOnServer ? nil : (completed, total)
            )
        case .parsing:
            progress(
                "Creating your workout",
                status: "Organizing exercises",
                detail: "Baseline is translating the text into editable exercises and sets. \(WorkoutImportProgressCopy.serverStageFootnote)"
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

    /// `steps` is real, server- or device-reported work, never a synthetic timer. When a stage cannot
    /// report countable units the spinner stays indeterminate rather than inventing a fraction.
    private func progress(
        _ headline: String,
        status: String?,
        detail: String,
        steps: (completed: Int, total: Int)? = nil
    ) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    if let steps, steps.total > 0 {
                        ProgressView(
                            value: Double(min(max(steps.completed, 0), steps.total)),
                            total: Double(steps.total)
                        )
                        .tint(BaselineColor.accent)
                        .frame(maxWidth: 260)
                        .accessibilityLabel("Step \(min(steps.completed + 1, steps.total)) of \(steps.total)")
                    } else {
                        ProgressView().tint(BaselineColor.accent).scaleEffect(1.2)
                    }
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
