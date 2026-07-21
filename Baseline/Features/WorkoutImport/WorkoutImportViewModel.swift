import Foundation
import Observation

enum WorkoutImportSaveOutcome: Equatable {
    case saved
    case requiresDuplicateChoice
    case failed
}

/// How opening the import screen for a given day should treat any unfinished import(s).
enum PendingImportResolution: Equatable {
    /// Silently resume this job — it belongs to the day being opened (or the screen has no target day).
    case resume(UUID)
    /// Offer to resume this other-day draft or start fresh, rather than silently reusing it here.
    case promptOther(WorkoutImportPendingSummary)
    /// No unfinished import — start a fresh selection.
    case fresh

    /// Pure decision used on appear. `pendings` are most-recent-first.
    static func decide(
        pendings: [WorkoutImportPendingSummary],
        targetDay: Date?,
        calendar: Calendar
    ) -> PendingImportResolution {
        guard let mostRecent = pendings.first else { return .fresh }
        guard let day = targetDay else { return .resume(mostRecent.jobID) }
        if let sameDay = pendings.first(where: { summary in
            summary.scheduleDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        }) {
            return .resume(sameDay.jobID)
        }
        return .promptOther(mostRecent)
    }
}

@MainActor
@Observable
final class WorkoutImportViewModel {
    private(set) var session = ImportSession()
    private(set) var duplicateTemplates: [WorkoutTemplate] = []
    private(set) var savedTemplate: WorkoutTemplate?
    private(set) var scheduleError: String?
    private(set) var saveError: String?
    private(set) var reviewPersistenceError: String?
    private(set) var reviewDraftIsPersisted = false
    private(set) var currentJob: WorkoutImportJob?
    var scheduleDate: Date?
    var canRetry: Bool { currentJob?.failure?.isRetryable == true }
    var canRefreshStructuredResult: Bool {
        guard currentJob?.stage == .reviewing,
              let status = currentJob?.serverProgress?.status else { return false }
        return status == WorkoutImportRemoteJobState.queued.rawValue
            || status == WorkoutImportRemoteJobState.processing.rawValue
    }
    /// The server has accepted the job but has not started parsing it. Distinct from `processing` so the
    /// wait can say the import is queued instead of implying sections are being worked on right now.
    var isQueuedOnServer: Bool {
        currentJob?.serverProgress?.status == WorkoutImportRemoteJobState.queued.rawValue
    }
    var hasCompletedServerResult: Bool {
        currentJob?.stage == .reviewing
            && currentJob?.serverProgress?.status == WorkoutImportRemoteJobState.completed.rawValue
    }
    var hasDurableCheckpoint: Bool {
        guard let job = currentJob else { return false }
        if job.stage == .reviewing { return reviewDraftIsPersisted }
        return job.serverProgress != nil || job.stage == .reviewing
    }
    private var sourceReplacementIndexes: [Int] {
        guard let currentJob else { return [] }
        let pages = Dictionary(uniqueKeysWithValues: currentJob.pages.map { ($0.index, $0) })
        guard let first = (0..<currentJob.expectedPageCount).first(where: { index in
            guard let page = pages[index] else { return true }
            return page.stage == .failed
        }) else { return [] }
        return Array(first..<currentJob.expectedPageCount)
    }
    var missingSourceCount: Int {
        sourceReplacementIndexes.count
    }
    var firstMissingSourcePosition: Int? { sourceReplacementIndexes.first.map { $0 + 1 } }
    var requiresSourceReselection: Bool {
        guard missingSourceCount > 0, let reason = currentJob?.failure?.reasonCode else { return false }
        return [
            "source_intake_incomplete", "source_reselection_count_mismatch", "source_resolution_required",
            "image_too_large", "image_unreadable", "stored_image_unreadable",
        ]
            .contains(reason)
    }
    var sourceReselectionPrompt: String {
        guard let position = firstMissingSourcePosition, missingSourceCount > 0 else {
            return "Choose the remaining workout photos to continue."
        }
        let photosAfter = missingSourceCount - 1
        let remainder: String
        switch photosAfter {
        case 0:
            remainder = "Choose a replacement for photo \(position) to continue."
        case 1:
            remainder = "Choose photo \(position) and the photo after it to continue."
        default:
            remainder = "Choose photo \(position) and the \(photosAfter) photos after it to continue."
        }
        if currentJob?.failure?.reasonCode == "image_too_large" {
            return "Photo \(position) is over the 20 MB limit. \(remainder)"
        }
        return "Baseline could not read photo \(position). \(remainder)"
    }

    private let coordinator: WorkoutImportCoordinator
    private var task: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var operationGeneration: UInt = 0
    private var activeOperationSessionID: UUID?
    private var reviewMutationRevision: UInt = 0

    init(scheduleDate: Date? = nil,
         normalizer: any WorkoutImageNormalizing = WorkoutImageNormalizer(),
         recognizer: any WorkoutTextRecognizing = VisionWorkoutTextRecognizer(),
         parser: (any WorkoutParsing)? = nil,
         jobParser: (any WorkoutImportJobParsing)? = nil,
         repository: any WorkoutImportJobStoring = FileWorkoutImportJobRepository(),
         coordinatorConfiguration: WorkoutImportCoordinatorConfiguration = .init(),
         initialSession: ImportSession? = nil,
         initialJob: WorkoutImportJob? = nil) {
        self.scheduleDate = scheduleDate
        let selectedParser: any WorkoutImportJobParsing
        if let jobParser {
            selectedParser = jobParser
        } else if let parser {
            selectedParser = LegacyWorkoutImportJobParser(parser: parser)
        } else {
            selectedParser = FirebaseWorkoutImportJobParser()
        }
        coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: normalizer,
            recognizer: recognizer,
            parser: selectedParser,
            configuration: coordinatorConfiguration
        )
        session = initialSession ?? ImportSession()
        currentJob = initialJob
        reviewDraftIsPersisted = initialJob?.stage == .reviewing
            && initialJob?.draft?.workout.allExercises.isEmpty == false
    }

    @discardableResult
    func importImage(_ data: Data, catalog: [ExerciseDefinition]) -> Task<Void, Never> {
        importImages([data], catalog: catalog)
    }

    @discardableResult
    func importImages(_ data: [Data], catalog: [ExerciseDefinition]) -> Task<Void, Never> {
        startImport(imageCount: data.count, catalog: catalog) { index in data[index] }
    }

    @discardableResult
    func importImages(
        count: Int,
        sourceItemIdentifiers: [String?] = [],
        catalog: [ExerciseDefinition],
        loadImage: @escaping @Sendable (Int) async throws -> Data
    ) -> Task<Void, Never> {
        startImport(
            imageCount: count,
            sourceItemIdentifiers: sourceItemIdentifiers,
            catalog: catalog,
            loadImage: loadImage
        )
    }

    private func startImport(
        imageCount: Int,
        sourceItemIdentifiers: [String?] = [],
        catalog: [ExerciseDefinition],
        loadImage: @escaping @Sendable (Int) async throws -> Data
    ) -> Task<Void, Never> {
        task?.cancel()
        persistenceTask?.cancel()
        let previousJob = currentJob
        let sessionID = UUID()
        let generation = beginOperation(sessionID: sessionID)
        session = ImportSession(id: sessionID, status: .loadingImages(completed: 0, total: imageCount))
        currentJob = nil
        reviewDraftIsPersisted = false
        reviewPersistenceError = nil
        let nextTask = Task { [weak self] in
            guard let self else { return }
            if let previousJob { await coordinator.cancel(previousJob) }
            let result = await coordinator.start(
                jobID: sessionID,
                imageCount: imageCount,
                scheduleDate: scheduleDate,
                sourceItemIdentifiers: sourceItemIdentifiers,
                catalog: catalog,
                loadImage: loadImage,
                progress: { [weak self] job in
                    await self?.apply(job, generation: generation)
                }
            )
            guard !Task.isCancelled else { return }
            apply(result, generation: generation)
        }
        task = nextTask
        return nextTask
    }

    @discardableResult
    func cancel() -> Task<Void, Never> {
        let jobID = currentJob?.id ?? activeOperationSessionID
        let serverJobID = currentJob?.serverProgress?.serverJobID
        invalidateOperation()
        task?.cancel()
        persistenceTask?.cancel()
        let cancellation: Task<Void, Never>
        if let jobID {
            cancellation = Task { await coordinator.cancel(jobID: jobID, serverJobID: serverJobID) }
        } else {
            cancellation = Task {}
        }
        cleanupTask = cancellation
        currentJob = nil
        reviewDraftIsPersisted = false
        reviewPersistenceError = nil
        clearTransientSourceState()
        session.status = .selecting
        touch()
        return cancellation
    }

    @discardableResult
    func reconcileMissingSources(
        count: Int,
        catalog: [ExerciseDefinition],
        loadImage: @escaping @Sendable (Int) async throws -> Data
    ) -> Task<Void, Never>? {
        guard let job = currentJob, requiresSourceReselection else { return nil }
        task?.cancel()
        persistenceTask?.cancel()
        let generation = beginOperation(sessionID: job.id)
        let nextTask = Task { [weak self] in
            guard let self else { return }
            let reconciled = await coordinator.reconcileMissingSources(
                job,
                replacementCount: count,
                catalog: catalog,
                loadReplacement: loadImage,
                progress: { [weak self] update in
                    await self?.apply(update, generation: generation)
                }
            )
            guard !Task.isCancelled else { return }
            apply(reconciled, generation: generation)
        }
        task = nextTask
        return nextTask
    }

    func waitForPendingCleanup() async {
        await cleanupTask?.value
    }

    func waitForPendingReviewPersistence() async {
        await persistenceTask?.value
    }

    func pause() {
        task?.cancel()
        task = nil
    }

    /// Keep local Photos and Vision work alive across a brief lock or app switch so iOS can
    /// suspend and resume the same task. Once the server owns the job, stop only client polling;
    /// foreground restoration will fetch durable progress without repeating local work.
    func suspendForBackground() {
        guard currentJob?.stage == .processingSections else { return }
        task?.cancel()
        task = nil
    }

    @discardableResult
    func restore(catalog: [ExerciseDefinition]) -> Task<Void, Never> {
        guard task == nil else { return task! }
        let generation = beginOperation(sessionID: currentJob?.id)
        let nextTask = Task { [weak self] in
            guard let self else { return }
            let restored = await coordinator.restoreLatest(catalog: catalog) { [weak self] job in
                await self?.apply(job, generation: generation)
            }
            guard !Task.isCancelled, let restored else { return }
            apply(restored, generation: generation)
        }
        task = nextTask
        return nextTask
    }

    /// Unfinished imports, most recent first. Lets the view decide whether opening import for a day should
    /// silently resume that day's draft or offer to resume another day's.
    func pendingImports() async -> [WorkoutImportPendingSummary] {
        await coordinator.pendingImports()
    }

    /// Resume a specific persisted import (day-scoped). Adopts the resumed job's day so a later save
    /// schedules it back onto the day it belongs to.
    @discardableResult
    func restore(jobID: UUID, catalog: [ExerciseDefinition]) -> Task<Void, Never> {
        guard task == nil else { return task! }
        let generation = beginOperation(sessionID: jobID)
        let nextTask = Task { [weak self] in
            guard let self else { return }
            let restored = await coordinator.restore(jobID: jobID, catalog: catalog) { [weak self] job in
                await self?.apply(job, generation: generation)
            }
            guard !Task.isCancelled, let restored else { return }
            if let day = restored.scheduleDate { scheduleDate = day }
            apply(restored, generation: generation)
        }
        task = nextTask
        return nextTask
    }

    @discardableResult
    func retry(catalog: [ExerciseDefinition]) -> Task<Void, Never>? {
        guard let job = currentJob, job.failure?.isRetryable == true else { return nil }
        task?.cancel()
        var retrying = job
        retrying.failure = nil
        currentJob = retrying
        session.status = .retryingSections(
            completed: retrying.serverProgress?.completedSections ?? 0,
            total: retrying.serverProgress?.totalSections ?? retrying.sections.count
        )
        touch()
        let generation = beginOperation(sessionID: job.id)
        let nextTask = Task { [weak self] in
            guard let self else { return }
            let retried = await coordinator.retry(job, catalog: catalog) { [weak self] update in
                await self?.apply(update, generation: generation)
            }
            guard !Task.isCancelled else { return }
            apply(retried, generation: generation)
        }
        task = nextTask
        return nextTask
    }

    /// Reconciles an immediate OCR review with the durable server job only when the user asks.
    /// This avoids silently replacing edits made while the detailed import was still running.
    @discardableResult
    func refreshStructuredResult(catalog: [ExerciseDefinition]) -> Task<Void, Never>? {
        guard let job = currentJob, canRefreshStructuredResult else { return nil }
        task?.cancel()
        persistenceTask?.cancel()
        let generation = beginOperation(sessionID: job.id)
        let startingReviewRevision = reviewMutationRevision
        let nextTask = Task { [weak self] in
            guard let self else { return }
            let refreshed = await coordinator.refreshStructuredResult(
                job,
                catalog: catalog,
                progress: { _ in }
            )
            guard !Task.isCancelled else { return }
            guard startingReviewRevision == reviewMutationRevision else {
                if let currentJob {
                    try? await coordinator.saveReviewState(currentJob)
                }
                return
            }
            apply(refreshed, generation: generation)
        }
        task = nextTask
        return nextTask
    }

    func sourceImageData(at index: Int) async -> Data? {
        if session.sourceImages.indices.contains(index) { return session.sourceImages[index].data }
        guard let job = currentJob,
              let page = job.pages.first(where: { $0.index == index }),
              !page.sourceRelativeFilename.isEmpty || !page.relativeFilename.isEmpty else { return nil }
        let filename = page.sourceRelativeFilename.isEmpty
            ? page.relativeFilename
            : page.sourceRelativeFilename
        return try? await coordinator.imageData(jobID: job.id, relativeFilename: filename)
    }

    func updateWorkout(_ transform: (inout Workout) -> Void) {
        guard var draft = session.draft else { return }
        let previous = draft.workout
        transform(&draft.workout)
        session.draft = draft
        reconcileIssues(with: draft.workout, previous: previous)
        touch()
    }

    /// Keeps the import document synchronized with the same transient `WorkoutStore` used by the
    /// ordinary editor. Review-only issue metadata remains outside canonical workout state.
    func replaceDraftWorkout(_ workout: Workout) {
        guard var draft = session.draft else { return }
        let previous = draft.workout
        draft.workout = workout
        session.draft = draft
        reconcileIssues(with: workout, previous: previous)
        touch()
    }

    /// Pulls the authoritative ordinary-editor value into the import document before any action
    /// (especially save) that consumes `session.draft`.
    func synchronizeDraft(from reviewStore: WorkoutStore) {
        guard let workout = reviewStore.current else { return }
        replaceDraftWorkout(workout)
    }

    func canUseWatts(for issue: WorkoutImportIssue) -> Bool {
        wattsReplacement(for: issue) != nil
    }

    @discardableResult
    func useWatts(for issue: WorkoutImportIssue, in reviewStore: WorkoutStore) -> Bool {
        guard let replacement = wattsReplacement(for: issue) else { return false }
        return resolveUnresolvedIntensity(issue, replacement: replacement, in: reviewStore)
    }

    @discardableResult
    func removeIntensityTarget(for issue: WorkoutImportIssue, in reviewStore: WorkoutStore) -> Bool {
        guard issue.code == .unsupportedIntensityTarget,
              session.issues.contains(where: { $0.id == issue.id }),
              issue.unresolvedIntensity != nil else { return false }
        return resolveUnresolvedIntensity(issue, replacement: nil, in: reviewStore)
    }

    func resolveExercise(_ exerciseID: UUID, with definition: ExerciseDefinition) {
        updateWorkout { workout in
            _ = workout.updateExercise(exerciseID) { exercise in
                exercise.exerciseName = definition.name
                exercise.definitionId = definition.id
                let supported = Set(definition.supported)
                exercise.selectedMetrics = exercise.selectedMetrics.filter { supported.contains($0) }
                if exercise.selectedMetrics.isEmpty { exercise.selectedMetrics = definition.defaults }
            }
        }
        session.issues.removeAll { $0.code == .unknownExercise && $0.exerciseID == exerciseID }
        touch()
    }

    func updateMetric(setID: UUID, metric: MetricType, value: Double?) {
        updateWorkout { workout in
            _ = workout.updateSet(setID) { set in set.values[metric] = value.map { max(0, $0) } }
        }
    }

    func findDuplicates(in plan: PlanStore) {
        guard let workout = session.draft?.workout else { duplicateTemplates = []; return }
        let exact = plan.templates(matchingFingerprintOf: workout)
        let sameName = plan.templates().filter { $0.name.localizedCaseInsensitiveCompare(workout.title) == .orderedSame }
        duplicateTemplates = Array(Dictionary(uniqueKeysWithValues: (exact + sameName).map { ($0.id, $0) }).values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The single save boundary for the shared import editor. Pulling from `reviewStore` here keeps
    /// a last text-field/edit transaction from being lost if SwiftUI has not delivered `onChange`.
    @discardableResult
    func saveReviewedDraft(from reviewStore: WorkoutStore, in plan: PlanStore) -> WorkoutImportSaveOutcome {
        synchronizeDraft(from: reviewStore)
        findDuplicates(in: plan)
        if !duplicateTemplates.isEmpty { return .requiresDuplicateChoice }
        return saveNewTemplate(in: plan) == nil ? .failed : .saved
    }

    @discardableResult
    func saveNewTemplate(in plan: PlanStore) -> WorkoutTemplate? {
        guard let draft = session.draft, session.canSave else { return nil }
        saveError = nil
        session.status = .saving
        do {
            let workout = WorkoutImportMaterializer.materialize(draft)
            let template = try plan.saveImportedTemplate(name: workout.title, workout: workout, tags: draft.tags)
            completeSave(template)
            return template
        } catch {
            saveError = "Baseline couldn't save that template. \(error.localizedDescription)"
            session.status = .reviewing
            return nil
        }
    }

    @discardableResult
    func updateTemplate(_ templateID: UUID, in plan: PlanStore) -> WorkoutTemplate? {
        guard let draft = session.draft, session.canSave else { return nil }
        saveError = nil
        session.status = .saving
        do {
            let workout = WorkoutImportMaterializer.materialize(draft)
            guard let template = try plan.updateImportedTemplate(templateID, workout: workout) else {
                saveError = "That template no longer exists."
                session.status = .reviewing
                return nil
            }
            completeSave(template)
            return template
        } catch {
            saveError = "Baseline couldn't update that template. \(error.localizedDescription)"
            session.status = .reviewing
            return nil
        }
    }

    func clearSaveError() {
        saveError = nil
    }

    func retryReviewDraftPersistence() {
        guard let job = currentJob, job.stage == .reviewing else { return }
        reviewPersistenceError = nil
        scheduleReviewPersistence(job, revision: reviewMutationRevision, delay: false)
    }

    @discardableResult
    func addSavedTemplateToPlan(_ date: Date, plan: PlanStore) -> ScheduledWorkout? {
        guard let id = savedTemplate?.id else { return nil }
        guard let scheduled = plan.instantiateTemplate(id, on: date) else {
            scheduleError = "The template was saved, but Baseline couldn't add it to the plan. You can schedule it later from Templates."
            return nil
        }
        scheduleError = nil
        return scheduled
    }

    private func apply(_ job: WorkoutImportJob, generation: UInt) {
        guard generation == operationGeneration else { return }
        if let activeOperationSessionID, activeOperationSessionID != job.id { return }
        activeOperationSessionID = job.id
        guard currentJob == nil || currentJob?.id == job.id || session.id == job.id else { return }
        currentJob = job
        session.id = job.id
        session.sourcePages = job.pages
        session.observations = job.pages.flatMap(\.observations)
        session.draft = job.draft
        session.issues = job.issues
        session.evidence = job.evidence
        session.diagnostics = job.diagnostics
        session.startedAt = job.startedAt
        session.lastUpdated = job.lastUpdated
        switch job.stage {
        case .loadingImages:
            session.status = .loadingImages(
                completed: job.pages.count { $0.stage != .pending },
                total: job.expectedPageCount
            )
        case .recognizingText:
            session.status = .recognizing(
                completed: job.pages.count { [.recognized, .noText, .failed].contains($0.stage) },
                total: job.expectedPageCount
            )
        case .preparingSections:
            session.status = .preparingSections
        case .waitingForHandoff:
            session.status = .waitingForHandoff
        case .processingSections:
            let progress = job.serverProgress
            session.status = .processingSections(
                completed: progress?.completedSections ?? 0,
                total: progress?.totalSections ?? job.sections.count
            )
        case .reviewing:
            if job.draft?.workout.allExercises.isEmpty == false {
                reviewDraftIsPersisted = true
                reviewPersistenceError = nil
                session.status = .reviewing
            } else {
                reviewDraftIsPersisted = false
                session.draft = nil
                session.issues = []
                session.status = .failed(
                    message: "Baseline could not build a usable workout from those photos."
                )
            }
        case .failed:
            reviewDraftIsPersisted = false
            session.status = .failed(message: failureMessage(job.failure))
        }
    }

    @discardableResult
    private func beginOperation(sessionID: UUID?) -> UInt {
        operationGeneration &+= 1
        activeOperationSessionID = sessionID
        return operationGeneration
    }

    private func invalidateOperation() {
        operationGeneration &+= 1
        activeOperationSessionID = nil
    }

    private func failureMessage(_ failure: WorkoutImportFailure?) -> String {
        switch failure?.reasonCode {
        case "source_resolution_required":
            sourceReselectionPrompt
        case "source_intake_incomplete":
            missingSourceCount == 1
                ? "One selected photo still needs to be added. Choose that remaining photo to continue."
                : "\(missingSourceCount) selected photos still need to be added. Choose only those remaining photos to continue."
        case "source_reselection_count_mismatch":
            missingSourceCount == 1
                ? "Choose exactly 1 remaining photo so Baseline can continue the saved import."
                : "Choose exactly \(missingSourceCount) remaining photos so Baseline can continue the saved import."
        case "manifest_schema_incompatible":
            "This saved import was created by an older Baseline version and cannot be resumed. Start a new import with the original photos."
        case "no_text":
            "Baseline could not find readable workout text in those photos."
        case "image_too_large":
            sourceReselectionPrompt
        case "workout_too_large":
            "That workout contains more text than Baseline can safely import at once. Try fewer photos."
        case "semantic_unit_too_large":
            "One uninterrupted note is too long to import safely. Shorten that note or import a smaller portion."
        case "image_unreadable", "stored_image_unreadable":
            sourceReselectionPrompt
        case "too_many_images":
            "Choose up to \(WorkoutImageImportLimits.maximumImageCount) photos."
        case "remote_unavailable":
            "The import is saved, but Baseline could not reach the workout parser. Try again."
        case "remote_timeout":
            "Parsing took too long. Your import is saved, so you can try again."
        case "draft_persistence_failed":
            "Baseline could not safely save the workout draft. Try again."
        case "section_invalid", "cross_section_assembly", "result_too_large", "worker_budget_exhausted", "schema_incompatible":
            "Baseline could not safely turn this workout into an editable template. Review the photos and start a new import."
        case "section_failed":
            "Baseline could not interpret one part of that workout. Try again."
        case "server_cancelled":
            "This saved import was canceled on the server. Start a new import with the original photos."
        default:
            "Baseline could not parse that workout right now. Try again."
        }
    }

    private func completeSave(_ template: WorkoutTemplate) {
        invalidateOperation()
        task?.cancel()
        task = nil
        persistenceTask?.cancel()
        savedTemplate = template
        saveError = nil
        if let job = currentJob {
            cleanupTask = Task { await coordinator.complete(job) }
        }
        currentJob = nil
        clearTransientSourceState()
        session.status = .saved(templateID: template.id)
        touch()
    }

    private func clearTransientSourceState() {
        session.sourceImages = []
        session.sourcePages = []
        session.observations = []
        session.evidence = []
    }

    private func wattsReplacement(for issue: WorkoutImportIssue) -> IntensityTarget? {
        guard issue.code == .unsupportedIntensityTarget,
              session.issues.contains(where: { $0.id == issue.id }),
              let source = issue.unresolvedIntensity?.source,
              normalizedToken(source.type) == "power",
              let lower = source.lower,
              lower.isFinite,
              lower >= 0 else { return nil }
        let upper = source.upper ?? lower
        guard upper.isFinite, upper >= lower else { return nil }

        if let unit = source.unit?.trimmingCharacters(in: .whitespacesAndNewlines), !unit.isEmpty {
            let normalizedUnit = normalizedToken(unit)
            if ["w", "watt", "watts"].contains(normalizedUnit) { return nil }
        }
        return .power(lower: lower, upper: upper, unit: .watts)
    }

    private func resolveUnresolvedIntensity(
        _ issue: WorkoutImportIssue,
        replacement: IntensityTarget?,
        in reviewStore: WorkoutStore
    ) -> Bool {
        guard session.issues.contains(where: { $0.id == issue.id }),
              let exerciseID = issue.exerciseID,
              let unresolved = issue.unresolvedIntensity,
              unresolved.occurrence > 0,
              var workout = reviewStore.current else { return false }

        var didResolve = false
        guard workout.updateExercise(exerciseID, { exercise in
            var matchingOccurrence = 0
            for index in exercise.prescription.intensityTargets.indices {
                guard exercise.prescription.intensityTargets[index] == unresolved.marker else { continue }
                matchingOccurrence += 1
                guard matchingOccurrence == unresolved.occurrence else { continue }
                if let replacement {
                    exercise.prescription.intensityTargets[index] = replacement
                } else {
                    exercise.prescription.intensityTargets.remove(at: index)
                }
                didResolve = true
                break
            }
        }), didResolve else { return false }

        prepareUnresolvedIntensityIssuesForReconciliation(resolving: issue)
        reviewStore.edit(.plan) { $0 = workout }
        synchronizeDraft(from: reviewStore)
        return true
    }

    private func prepareUnresolvedIntensityIssuesForReconciliation(resolving issue: WorkoutImportIssue) {
        guard let resolved = issue.unresolvedIntensity else { return }
        let matchingIndices = session.issues.indices.filter { index in
            let candidate = session.issues[index]
            return candidate.exerciseID == issue.exerciseID
                && candidate.unresolvedIntensity?.marker == resolved.marker
        }.sorted { left, right in
            let leftOccurrence = session.issues[left].unresolvedIntensity?.occurrence ?? .max
            let rightOccurrence = session.issues[right].unresolvedIntensity?.occurrence ?? .max
            return leftOccurrence < rightOccurrence
        }

        var nextRemainingOccurrence = 1
        for index in matchingIndices where session.issues[index].id != issue.id {
            session.issues[index].unresolvedIntensity?.occurrence = nextRemainingOccurrence
            nextRemainingOccurrence += 1
        }
        guard let resolvedIndex = matchingIndices.first(where: { session.issues[$0].id == issue.id }) else { return }
        session.issues[resolvedIndex].unresolvedIntensity?.occurrence = matchingIndices.count
    }

    private func normalizedToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func reconcileIssues(with workout: Workout, previous: Workout) {
        session.issues.removeAll { issue in
            switch issue.code {
            case .unknownExercise:
                guard let exerciseID = issue.exerciseID else { return false }
                guard let exercise = workout.exercise(exerciseID) else { return true }
                return exercise.definitionId != nil
            case .missingMetricValue:
                guard let exerciseID = issue.exerciseID else { return false }
                guard let exercise = workout.exercise(exerciseID) else { return true }
                return !exercise.selectedMetrics.contains(.load)
                    || exercise.prescription.sets.allSatisfy { $0.values[.load] != nil }
            case .emptyWorkout:
                return !workout.allExercises.isEmpty
            case .ambiguousStructure:
                guard let nodeID = issue.nodeID else { return false }
                guard let afterNode = node(nodeID, in: workout) else { return true }
                guard let beforeNode = node(nodeID, in: previous) else { return false }
                return structureChanged(from: beforeNode, to: afterNode)
            case .unsupportedMetric:
                guard let exerciseID = issue.exerciseID else { return false }
                guard let after = workout.exercise(exerciseID) else { return true }
                if let metric = issue.metric {
                    // Catalog defaults can select this metric even though parsing discarded the
                    // unknown-unit value. Resolve only when the athlete explicitly removes the
                    // metric or supplies a replacement value.
                    if !after.selectedMetrics.contains(metric) { return true }
                    if issue.setID != nil { return issueTargetHasValue(issue, in: after, metric: metric) }
                    return after.prescription.sets.allSatisfy { $0.values[metric] != nil }
                }
                return false
            case .unsupportedIntensityTarget:
                guard let exerciseID = issue.exerciseID else { return false }
                guard let after = workout.exercise(exerciseID) else { return true }
                guard let unresolved = issue.unresolvedIntensity else { return false }
                let remainingOccurrences = after.prescription.intensityTargets.count {
                    $0 == unresolved.marker
                }
                return remainingOccurrences < unresolved.occurrence
            case .invalidValue:
                guard let exerciseID = issue.exerciseID else { return false }
                guard let after = workout.exercise(exerciseID) else { return true }
                guard let metric = issue.metric else { return false }
                if !after.selectedMetrics.contains(metric) { return true }
                return issueTargetHasValue(issue, in: after, metric: metric)
            }
        }
    }

    private func issueTargetHasValue(
        _ issue: WorkoutImportIssue,
        in exercise: PlannedExercise,
        metric: MetricType
    ) -> Bool {
        guard let setID = issue.setID,
              let set = exercise.prescription.sets.first(where: { $0.id == setID }) else { return true }
        if let alternativeID = issue.alternativeID {
            guard let alternative = set.alternatives.first(where: { $0.id == alternativeID }) else { return true }
            return alternative.values[metric] != nil
        }
        return set.values[metric] != nil
    }

    private func node(_ id: UUID, in workout: Workout) -> WorkoutNode? {
        for block in workout.blocks {
            if let match = node(id, in: block.nodes) { return match }
        }
        return nil
    }

    private func node(_ id: UUID, in nodes: [WorkoutNode]) -> WorkoutNode? {
        for candidate in nodes {
            if candidate.id == id { return candidate }
            switch candidate {
            case .group(let group):
                if let match = node(id, in: group.children) { return match }
            case .choice(let choice):
                if let match = node(id, in: choice.options) { return match }
            case .exercise, .rest:
                break
            }
        }
        return nil
    }

    private func structureChanged(from before: WorkoutNode, to after: WorkoutNode) -> Bool {
        switch (before, after) {
        case (.group(let lhs), .group(let rhs)):
            return lhs.label != rhs.label
                || lhs.execution != rhs.execution
                || lhs.children.map(structureIdentity) != rhs.children.map(structureIdentity)
        case (.choice(let lhs), .choice(let rhs)):
            return lhs.label != rhs.label
                || lhs.selectionCount != rhs.selectionCount
                || lhs.options.map(structureIdentity) != rhs.options.map(structureIdentity)
        default:
            return true
        }
    }

    private func structureIdentity(_ node: WorkoutNode) -> String {
        switch node {
        case .exercise: "exercise:\(node.id)"
        case .group: "group:\(node.id)"
        case .rest: "rest:\(node.id)"
        case .choice: "choice:\(node.id)"
        }
    }

    private func touch() {
        session.lastUpdated = Date()
        guard var job = currentJob, job.stage == .reviewing else { return }
        reviewMutationRevision &+= 1
        job.draft = session.draft
        job.issues = session.issues
        job.evidence = session.evidence
        job.lastUpdated = session.lastUpdated
        currentJob = job
        reviewDraftIsPersisted = false
        reviewPersistenceError = nil
        scheduleReviewPersistence(job, revision: reviewMutationRevision, delay: true)
    }

    private func scheduleReviewPersistence(
        _ job: WorkoutImportJob,
        revision: UInt,
        delay: Bool
    ) {
        persistenceTask?.cancel()
        reviewDraftIsPersisted = false
        persistenceTask = Task { [weak self, coordinator] in
            do {
                if delay { try await Task.sleep(for: .milliseconds(200)) }
                try Task.checkCancellation()
                try await coordinator.saveReviewState(job)
                guard !Task.isCancelled,
                      self?.reviewMutationRevision == revision,
                      self?.currentJob?.id == job.id else { return }
                self?.reviewDraftIsPersisted = true
                self?.reviewPersistenceError = nil
            } catch is CancellationError {
                return
            } catch {
                guard self?.reviewMutationRevision == revision,
                      self?.currentJob?.id == job.id else { return }
                self?.reviewDraftIsPersisted = false
                self?.reviewPersistenceError = "Baseline could not save your latest edits yet."
            }
        }
    }
}
