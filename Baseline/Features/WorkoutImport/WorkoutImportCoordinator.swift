import Foundation
import OSLog

enum WorkoutImportCoordinatorError: Error {
    case sourceResolutionRequired
    case sourceDocumentTooLarge
    case replacementCountMismatch
}

struct WorkoutImportCoordinatorConfiguration: Sendable {
    var maximumConcurrentOCR = 2
    var pollingDelay: @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(1.5))
    }
}

actor WorkoutImportCoordinator {
    typealias ProgressHandler = @Sendable (WorkoutImportJob) async -> Void

    private let repository: any WorkoutImportJobStoring
    private let normalizer: any WorkoutImageNormalizing
    private let recognizer: any WorkoutTextRecognizing
    private let parser: any WorkoutImportJobParsing
    /// The fast path. Nil disables it entirely and every import goes straight to the durable job,
    /// which is what the offline and test paths want.
    private let streamer: (any WorkoutImportStreaming)?
    private let configuration: WorkoutImportCoordinatorConfiguration
    private var cancelledJobIDs: Set<UUID> = []
    private static let logger = Logger(subsystem: "com.tylerpavay.Baseline", category: "WorkoutImport")

    init(
        repository: any WorkoutImportJobStoring = FileWorkoutImportJobRepository(),
        normalizer: any WorkoutImageNormalizing = WorkoutImageNormalizer(),
        recognizer: any WorkoutTextRecognizing = VisionWorkoutTextRecognizer(),
        parser: any WorkoutImportJobParsing = FirebaseWorkoutImportJobParser(),
        streamer: (any WorkoutImportStreaming)? = FirebaseWorkoutImportStreamingParser(),
        configuration: WorkoutImportCoordinatorConfiguration = .init()
    ) {
        self.repository = repository
        self.normalizer = normalizer
        self.recognizer = recognizer
        self.parser = parser
        self.streamer = streamer
        self.configuration = configuration
    }

    func start(
        jobID: UUID = UUID(),
        imageCount: Int,
        scheduleDate: Date? = nil,
        sourceItemIdentifiers: [String?] = [],
        catalog: [ExerciseDefinition],
        loadImage: @escaping @Sendable (Int) async throws -> Data,
        progress: @escaping ProgressHandler
    ) async -> WorkoutImportJob {
        let now = Date()
        var job = WorkoutImportJob(
            id: jobID,
            expectedPageCount: imageCount,
            scheduleDate: scheduleDate,
            sourceItemIdentifiers: sourceItemIdentifiers.isEmpty ? nil : sourceItemIdentifiers,
            startedAt: now,
            lastUpdated: now
        )
        do {
            guard imageCount > 0 else { throw WorkoutImagePipelineError.noImages }
            guard imageCount <= WorkoutImageImportLimits.maximumImageCount else {
                throw WorkoutImagePipelineError.tooManyImages(maximum: WorkoutImageImportLimits.maximumImageCount)
            }
            try ensureActive(job.id)
            try await repository.create(job)
            try ensureActive(job.id)
            Self.logger.info(
                "Accepted import \(job.id.uuidString, privacy: .public) with \(imageCount) selected photos"
            )
            await progress(job)
            job = try await prepareAndRecognizeSources(
                job,
                imageCount: imageCount,
                catalog: catalog,
                loadImage: loadImage,
                progress: progress
            )
            var sectionPreparationError: (any Error)?
            do {
                job = try await prepareSections(job, progress: progress)
            } catch {
                // Vision OCR is useful context for the durable retry, but the multimodal stream can
                // still read a legible photo when on-device recognition found no text. Give the
                // actual pixels their one chance before deciding the input is unreadable.
                sectionPreparationError = error
            }
            let attempt = await assembleOnFastPath(job, catalog: catalog, progress: progress)
            if let assembled = attempt.assembled { return assembled }
            if let sectionPreparationError { throw sectionPreparationError }
            // The fast path's own elapsed time is the number the latency work exists to track, so it
            // survives the fall-through rather than being discarded exactly when it matters most.
            job.diagnostics.parserMilliseconds += attempt.elapsedMilliseconds
            return await handOffAndWait(job, catalog: catalog, progress: progress)
        } catch is CancellationError {
            if cancelledJobIDs.contains(job.id) {
                await repository.remove(job.id)
                return job
            }
            return (try? await repository.load(job.id)) ?? job
        } catch {
            let retained = (try? await repository.load(job.id)) ?? job
            return await fail(retained, stage: "local", reason: localFailureCode(error), retryable: false, progress: progress)
        }
    }

    /// Lightweight, side-effect-free listing of unfinished imports, most recently updated first. Used to
    /// decide whether opening import for a given day should silently resume that day's draft or offer to
    /// resume another day's draft. Never triggers handoff, polling, or fallback.
    func pendingImports(now: Date = Date()) async -> [WorkoutImportPendingSummary] {
        await repository.removeExpired(now: now)
        let jobs = (try? await repository.activeJobs(now: now)) ?? []
        return jobs.map { job in
            WorkoutImportPendingSummary(
                jobID: job.id,
                scheduleDate: job.scheduleDate,
                stage: job.stage,
                isReviewable: job.stage == .reviewing
                    && job.draft?.workout.allExercises.isEmpty == false
            )
        }
    }

    /// Resume a specific persisted import (day-scoped resume). Returns nil when the job is gone, expired,
    /// or on an incompatible schema — the caller then falls through to a fresh import.
    func restore(jobID: UUID, catalog: [ExerciseDefinition], progress: @escaping ProgressHandler) async -> WorkoutImportJob? {
        await retryPendingCancellations()
        await repository.removeExpired(now: Date())
        guard let job = try? await repository.load(jobID), job.expiresAt > Date() else { return nil }
        return await resume(job, catalog: catalog, progress: progress)
    }

    func restoreLatest(catalog: [ExerciseDefinition], progress: @escaping ProgressHandler) async -> WorkoutImportJob? {
        do {
            await retryPendingCancellations()
            await repository.removeExpired(now: Date())
            guard let job = try await repository.mostRecentActiveJob(now: Date()) else { return nil }
            return await resume(job, catalog: catalog, progress: progress)
        } catch WorkoutImportJobRepositoryError.unsupportedSchema(let version, let jobID, _, _) {
            Self.logger.error("Cannot restore workout import manifest schema \(version)")
            var incompatible = WorkoutImportJob(id: jobID, stage: .failed)
            incompatible.failure = .init(
                stage: "local_restore",
                reasonCode: "manifest_schema_incompatible",
                isRetryable: false
            )
            await progress(incompatible)
            return incompatible
        } catch {
            return nil
        }
    }

    private func resume(
        _ initialJob: WorkoutImportJob,
        catalog: [ExerciseDefinition],
        progress: @escaping ProgressHandler
    ) async -> WorkoutImportJob {
        var job = initialJob
        let hasInvalidReviewDraft = job.stage == .reviewing
            && job.draft?.workout.allExercises.isEmpty != false
        if !hasInvalidReviewDraft { await progress(job) }
        switch job.stage {
        case .waitingForHandoff, .processingSections:
                job = await handOffAndWait(job, catalog: catalog, progress: progress)
            case .assembling:
                // The fast path streams to this process and nothing on a server owns it, so a job
                // killed mid-stream cannot be resumed. The sections are already prepared, so the
                // durable job picks it up — which is exactly its role as the retry.
                job = await handOffAndWait(job, catalog: catalog, progress: progress)
            case .reviewing:
                if hasInvalidReviewDraft {
                    job = await fail(
                        job,
                        stage: "restore",
                        reason: "unusable_saved_draft",
                        retryable: isRetryableFailure("unusable_saved_draft", for: job),
                        progress: progress
                    )
                }
            case .failed:
                // A restored failure stays a failure. Synthesizing a draft out of recognized text
                // here is what produced confidently wrong workouts; the athlete retries instead.
                break
            case .loadingImages, .recognizingText, .preparingSections:
                if job.pages.count == job.expectedPageCount,
                   job.pages.allSatisfy({ $0.stage == .recognized || $0.stage == .noText }) {
                    do {
                        job = try await prepareSections(job, progress: progress)
                        job = await handOffAndWait(job, catalog: catalog, progress: progress)
                    } catch {
                        let retained = (try? await repository.load(job.id)) ?? job
                        job = await fail(
                            retained,
                            stage: "local_restore",
                            reason: localFailureCode(error),
                            retryable: false,
                            progress: progress
                        )
                    }
                } else if job.pages.count == job.expectedPageCount,
                          job.pages.allSatisfy({ [.sourceStored, .prepared, .recognized, .noText].contains($0.stage) }) {
                    do {
                        job = try await normalizeStoredPages(job, progress: progress)
                        job = try await recognizePreparedPages(job, catalog: catalog, progress: progress)
                        if job.pages.contains(where: { $0.stage == .failed }) {
                            throw WorkoutImportCoordinatorError.sourceResolutionRequired
                        }
                        job = try await prepareSections(job, progress: progress)
                        job = await handOffAndWait(job, catalog: catalog, progress: progress)
                    } catch {
                        let retained = (try? await repository.load(job.id)) ?? job
                        job = await fail(
                            retained,
                            stage: "local_restore",
                            reason: localFailureCode(error),
                            retryable: false,
                            progress: progress
                        )
                    }
                } else {
                    job = await fail(
                        job,
                        stage: "local_restore",
                        reason: "source_intake_incomplete",
                        retryable: false,
                        progress: progress
                    )
                }
        }
        return job
    }

    func reconcileMissingSources(
        _ initialJob: WorkoutImportJob,
        replacementCount: Int,
        catalog: [ExerciseDefinition],
        loadReplacement: @escaping @Sendable (Int) async throws -> Data,
        progress: @escaping ProgressHandler
    ) async -> WorkoutImportJob {
        var job = initialJob
        do {
            let pagesByIndex = Dictionary(uniqueKeysWithValues: job.pages.map { ($0.index, $0) })
            guard let firstProblemIndex = (0..<job.expectedPageCount).first(where: { index in
                guard let page = pagesByIndex[index] else { return true }
                return page.stage == .failed
            }) else {
                throw WorkoutImportCoordinatorError.replacementCountMismatch
            }
            let replacementIndexes = Array(firstProblemIndex..<job.expectedPageCount)
            guard replacementCount == replacementIndexes.count, replacementCount > 0 else {
                throw WorkoutImportCoordinatorError.replacementCountMismatch
            }
            let replacementIndexSet = Set(replacementIndexes)
            job.pages.removeAll { replacementIndexSet.contains($0.index) }
            job.sections = []
            job.parsedDocument = nil
            job.draft = nil
            job.issues = []
            job.evidence = []
            job.serverProgress = nil
            job.stage = .loadingImages
            job.failure = nil
            job.lastUpdated = Date()
            try await repository.save(job)
            await progress(job)
            for (replacementIndex, pageIndex) in replacementIndexes.enumerated() {
                try Task.checkCancellation()
                try ensureActive(job.id)
                let source = try await loadReplacement(replacementIndex)
                try Task.checkCancellation()
                try ensureActive(job.id)
                job = try await storeSource(source, pageIndex: pageIndex, in: job, progress: progress)
            }
            job = try await normalizeStoredPages(job, progress: progress)
            job = try await recognizePreparedPages(job, catalog: catalog, progress: progress)
            if job.pages.contains(where: { $0.stage == .failed }) {
                throw WorkoutImportCoordinatorError.sourceResolutionRequired
            }
            job = try await prepareSections(job, progress: progress)
            return await handOffAndWait(job, catalog: catalog, progress: progress)
        } catch is CancellationError {
            return job
        } catch {
            let retained = (try? await repository.load(job.id)) ?? job
            return await fail(
                retained,
                stage: "source_reconciliation",
                reason: localFailureCode(error),
                retryable: false,
                progress: progress
            )
        }
    }

    func retry(_ job: WorkoutImportJob, catalog: [ExerciseDefinition], progress: @escaping ProgressHandler) async -> WorkoutImportJob {
        var mutable = job
        let started = ContinuousClock.now
        mutable.failure = nil
        mutable.requestID = UUID()
        if let serverJobID = mutable.serverProgress?.serverJobID {
            do {
                let remote = try await parser.retry(serverJobID: serverJobID, requestID: mutable.requestID)
                try Task.checkCancellation()
                try ensureActive(mutable.id)
                mutable = try await apply(remote, to: mutable, catalog: catalog, progress: progress)
                if remote.state == .queued || remote.state == .processing {
                    mutable = await poll(mutable, catalog: catalog, progress: progress)
                }
                return await recordParserTime(mutable, since: started, progress: progress)
            } catch is CancellationError {
                return job
            } catch {
                let reason = remoteFailureCode(error)
                let failed = await fail(
                    mutable,
                    stage: "remote_retry",
                    reason: reason,
                    retryable: reason != "schema_incompatible",
                    progress: progress
                )
                return await recordParserTime(failed, since: started, progress: progress)
            }
        }
        return await handOffAndWait(mutable, catalog: catalog, progress: progress)
    }

    func cancel(_ job: WorkoutImportJob) async {
        await cancel(jobID: job.id, serverJobID: job.serverProgress?.serverJobID)
    }

    func cancel(jobID: UUID, serverJobID: String? = nil) async {
        cancelledJobIDs.insert(jobID)
        WorkoutImageTransferFiles.removeAll()
        Self.logger.info("Cancelling import \(jobID.uuidString, privacy: .public)")
        let tombstone = WorkoutImportCancellationTombstone(
            jobID: jobID,
            serverJobID: serverJobID ?? jobID.uuidString,
            requestID: UUID(),
            createdAt: Date()
        )
        var savedCancellation = false
        do {
            try await repository.saveCancellation(tombstone)
            savedCancellation = true
        } catch {
            Self.logger.error(
                "Could not persist remote cancellation for import \(jobID.uuidString, privacy: .public); deleting local sources anyway"
            )
        }
        await repository.remove(jobID)
        do {
            try await parser.cancel(serverJobID: tombstone.serverJobID, requestID: tombstone.requestID)
            if savedCancellation {
                await repository.removeCancellation(tombstone.id)
            }
        } catch {
            // The protected tombstone is retried on launch or foreground restoration.
        }
    }

    /// Checks a still-running server job after recognized text was exposed for immediate review.
    /// A pending or unreachable server never displaces the user's editable fallback draft.
    func refreshStructuredResult(
        _ initialJob: WorkoutImportJob,
        catalog: [ExerciseDefinition],
        progress: @escaping ProgressHandler
    ) async -> WorkoutImportJob {
        guard initialJob.stage == .reviewing,
              let serverProgress = initialJob.serverProgress,
              (serverProgress.status == WorkoutImportRemoteJobState.queued.rawValue
                || serverProgress.status == WorkoutImportRemoteJobState.processing.rawValue) else {
            return initialJob
        }
        do {
            let remote = try await parser.status(serverJobID: serverProgress.serverJobID)
            try Task.checkCancellation()
            // Once review begins, the local draft belongs to the user. A later provider result may
            // update job metadata, but it must never replace that draft or its edits.
            var job = initialJob
            job.serverProgress = .init(
                serverJobID: remote.serverJobID,
                status: remote.state.rawValue,
                completedSections: remote.completedSections,
                totalSections: remote.totalSections,
                failureCode: remote.failureCode
            )
            job.lastUpdated = Date()
            try Task.checkCancellation()
            try await repository.save(job)
            await progress(job)
            return job
        } catch is CancellationError {
            return initialJob
        } catch {
            Self.logger.info(
                "Detailed import is not available yet for \(initialJob.id.uuidString, privacy: .public); keeping recognized-text review"
            )
            return initialJob
        }
    }

    func imageData(jobID: UUID, relativeFilename: String) async throws -> Data {
        try await repository.imageData(jobID: jobID, relativeFilename: relativeFilename)
    }

    func saveReviewState(_ job: WorkoutImportJob) async throws {
        try await repository.save(job)
    }

    func complete(_ job: WorkoutImportJob) async {
        if let serverProgress = job.serverProgress,
           (serverProgress.status == WorkoutImportRemoteJobState.queued.rawValue
            || serverProgress.status == WorkoutImportRemoteJobState.processing.rawValue) {
            await cancel(jobID: job.id, serverJobID: serverProgress.serverJobID)
            return
        }
        cancelledJobIDs.insert(job.id)
        WorkoutImageTransferFiles.removeAll()
        await repository.remove(job.id)
    }

    func cleanup() async {
        await retryPendingCancellations()
        await repository.removeExpired(now: Date())
        WorkoutImageTransferFiles.removeAll()
        WorkoutImportTemporaryFiles.removeExpired()
    }

    private func retryPendingCancellations() async {
        guard let pending = try? await repository.pendingCancellations() else { return }
        for tombstone in pending {
            await repository.remove(tombstone.jobID)
            if tombstone.createdAt.addingTimeInterval(WorkoutImportJob.retentionInterval) <= Date() {
                await repository.removeCancellation(tombstone.id)
                continue
            }
            do {
                try await parser.cancel(
                    serverJobID: tombstone.serverJobID,
                    requestID: tombstone.requestID
                )
                await repository.removeCancellation(tombstone.id)
            } catch {
                continue
            }
        }
    }

    private func prepareAndRecognizeSources(
        _ initialJob: WorkoutImportJob,
        imageCount: Int,
        catalog: [ExerciseDefinition],
        loadImage: @escaping @Sendable (Int) async throws -> Data,
        progress: @escaping ProgressHandler
    ) async throws -> WorkoutImportJob {
        var job = initialJob
        let jobID = job.id

        // Persist every selected original before normalization or OCR. PhotosPicker handles are not
        // durable across process death, while these protected files are.
        for index in 0..<imageCount {
            try Task.checkCancellation()
            try ensureActive(jobID)
            let source = try await loadImage(index)
            try Task.checkCancellation()
            try ensureActive(jobID)
            job = try await storeSource(source, pageIndex: index, in: job, progress: progress)
        }

        job = try await normalizeStoredPages(job, progress: progress)
        job = try await recognizePreparedPages(job, catalog: catalog, progress: progress)
        if job.pages.contains(where: { $0.stage == .failed }) {
            throw WorkoutImportCoordinatorError.sourceResolutionRequired
        }
        return job
    }

    private func storeSource(
        _ source: Data,
        pageIndex: Int,
        in initialJob: WorkoutImportJob,
        progress: ProgressHandler
    ) async throws -> WorkoutImportJob {
        try WorkoutImageSourceValidator.validate(byteCount: source.count)
        let sourceFilename = try await repository.writeSource(
            source,
            jobID: initialJob.id,
            pageIndex: pageIndex
        )
        let stored = WorkoutImportSourcePage(
            index: pageIndex,
            sourceRelativeFilename: sourceFilename,
            relativeFilename: "",
            digest: WorkoutImportStableIdentity.page(data: source),
            pixelWidth: 0,
            pixelHeight: 0,
            stage: .sourceStored
        )
        return try await checkpoint(stored, in: initialJob, progress: progress)
    }

    private func normalizeStoredPages(
        _ initialJob: WorkoutImportJob,
        progress: @escaping ProgressHandler
    ) async throws -> WorkoutImportJob {
        var job = initialJob
        let pending = job.pages.filter { $0.stage == .sourceStored }.sorted { $0.index < $1.index }
        let maximumConcurrent = max(1, min(configuration.maximumConcurrentOCR, 2))
        let jobID = job.id
        try await withThrowingTaskGroup(
            of: (WorkoutImportSourcePage, Int, Int).self
        ) { group in
            var inFlight = 0
            for page in pending {
                try Task.checkCancellation()
                try ensureActive(jobID)
                if inFlight >= maximumConcurrent, let result = try await group.next() {
                    try Task.checkCancellation()
                    try ensureActive(jobID)
                    inFlight -= 1
                    job = try await checkpoint(
                        result.0,
                        imageByteCount: result.1,
                        preparationMilliseconds: result.2,
                        in: job,
                        progress: progress
                    )
                }
                let source = try await repository.imageData(
                    jobID: jobID,
                    relativeFilename: page.sourceRelativeFilename
                )
                group.addTask { [normalizer, repository] in
                    let started = ContinuousClock.now
                    do {
                        try Task.checkCancellation()
                        let image = try await normalizer.normalize(source)
                        try Task.checkCancellation()
                        let filename = try await repository.writeImage(
                            image,
                            jobID: jobID,
                            pageIndex: page.index
                        )
                        var prepared = page
                        prepared.relativeFilename = filename
                        prepared.digest = WorkoutImportStableIdentity.page(data: image.data)
                        prepared.pixelWidth = image.pixelWidth
                        prepared.pixelHeight = image.pixelHeight
                        prepared.stage = .prepared
                        prepared.failureCode = nil
                        return (
                            prepared,
                            image.data.count,
                            Self.millisecondsSince(started)
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        var failed = page
                        failed.stage = .failed
                        failed.failureCode = "image_unreadable"
                        return (failed, 0, Self.millisecondsSince(started))
                    }
                }
                inFlight += 1
            }
            while inFlight > 0 {
                if let result = try await group.next() {
                    try Task.checkCancellation()
                    try ensureActive(jobID)
                    job = try await checkpoint(
                        result.0,
                        imageByteCount: result.1,
                        preparationMilliseconds: result.2,
                        in: job,
                        progress: progress
                    )
                }
                inFlight -= 1
            }
        }
        return job
    }

    private func recognizePreparedPages(
        _ initialJob: WorkoutImportJob,
        catalog: [ExerciseDefinition],
        progress: @escaping ProgressHandler
    ) async throws -> WorkoutImportJob {
        var job = initialJob
        let words = Array(Set(catalog.flatMap { [$0.name] + $0.aliases })).sorted().prefix(500)
        let customWords = Array(words)
        let pending = job.pages.filter { $0.stage == .prepared }.sorted { $0.index < $1.index }
        let started = ContinuousClock.now
        try await withThrowingTaskGroup(of: WorkoutImportSourcePage.self) { group in
            var inFlight = 0
            for page in pending {
                do {
                    let data = try await repository.imageData(
                        jobID: job.id,
                        relativeFilename: page.relativeFilename
                    )
                    let image = ImportedWorkoutImage(
                        data: data,
                        pixelWidth: page.pixelWidth,
                        pixelHeight: page.pixelHeight
                    )
                    group.addTask { [recognizer] in
                        do {
                            let observations = try await recognizer.recognize(
                                image: image,
                                sourceImageIndex: page.index,
                                customWords: customWords
                            )
                            var result = page
                            result.stage = .recognized
                            result.observations = observations
                            return result
                        } catch WorkoutImagePipelineError.noText {
                            var result = page
                            result.stage = .noText
                            result.failureCode = "no_text"
                            return result
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            var result = page
                            result.stage = .failed
                            result.failureCode = "text_recognition_failed"
                            return result
                        }
                    }
                    inFlight += 1
                } catch {
                    var failed = page
                    failed.stage = .failed
                    failed.failureCode = "stored_image_unreadable"
                    job = try await checkpoint(failed, in: job, progress: progress)
                }
                if inFlight >= max(1, min(configuration.maximumConcurrentOCR, 2)),
                   let result = try await group.next() {
                    try Task.checkCancellation()
                    try ensureActive(job.id)
                    inFlight -= 1
                    job = try await checkpoint(result, in: job, progress: progress)
                }
            }
            while inFlight > 0 {
                if let result = try await group.next() {
                    try Task.checkCancellation()
                    try ensureActive(job.id)
                    job = try await checkpoint(result, in: job, progress: progress)
                }
                inFlight -= 1
            }
        }
        job.diagnostics.ocrMilliseconds += milliseconds(since: started)
        if job.pages.contains(where: { $0.stage == .failed }) {
            throw WorkoutImportCoordinatorError.sourceResolutionRequired
        }
        return job
    }

    private func checkpoint(
        _ page: WorkoutImportSourcePage,
        imageByteCount: Int = 0,
        preparationMilliseconds: Int = 0,
        in initialJob: WorkoutImportJob,
        progress: ProgressHandler
    ) async throws -> WorkoutImportJob {
        try Task.checkCancellation()
        try ensureActive(initialJob.id)
        var job = initialJob
        let previousStage = job.pages.first(where: { $0.index == page.index })?.stage
        let isNewPage = previousStage == nil
        job.pages.removeAll { $0.index == page.index }
        job.pages.append(page)
        job.pages.sort { $0.index < $1.index }
        job.stage = [.sourceStored, .prepared].contains(page.stage) ? .loadingImages : .recognizingText
        job.lastUpdated = Date()
        job.diagnostics.imageCount = job.pages.count
        if isNewPage || (previousStage == .sourceStored && page.stage == .prepared) {
            job.diagnostics.normalizedImageBytes += imageByteCount
            job.diagnostics.imagePreparationMilliseconds += preparationMilliseconds
        }
        job.diagnostics.observationCount = job.pages.reduce(0) { $0 + $1.observations.count }
        job.diagnostics.characterCount = job.pages.flatMap(\.observations).reduce(0) { $0 + $1.text.count }
        try await repository.save(job)
        try Task.checkCancellation()
        try ensureActive(job.id)
        Self.logger.debug(
            "Import \(job.id.uuidString, privacy: .public) checkpointed page \(page.index) as \(page.stage.rawValue, privacy: .public)"
        )
        await progress(job)
        return job
    }

    private func prepareSections(
        _ initialJob: WorkoutImportJob,
        progress: @escaping ProgressHandler
    ) async throws -> WorkoutImportJob {
        try Task.checkCancellation()
        try ensureActive(initialJob.id)
        var job = initialJob
        let started = ContinuousClock.now
        let readable = job.pages.filter { $0.stage == .recognized && !$0.observations.isEmpty }
        guard !readable.isEmpty else { throw WorkoutImagePipelineError.noText }
        let document = try WorkoutImportSourceDocumentBuilder.build(pages: job.pages)
        guard !document.sections.isEmpty else { throw WorkoutImagePipelineError.noText }
        let observationCount = document.sections.reduce(0) { $0 + $1.observations.count }
        let characterCount = document.sections.reduce(0) { $0 + $1.characterCount }
        guard document.sections.count <= WorkoutImportSourceDocumentBuilder.maximumSectionCount,
              observationCount <= 2_000,
              characterCount <= 40_000 else {
            throw WorkoutImportCoordinatorError.sourceDocumentTooLarge
        }
        job.sections = document.sections
        job.jobHash = WorkoutImportStableIdentity.digest(
            job.pages.sorted { $0.index < $1.index }.map(\.digest) + document.sections.map(\.id)
        )
        job.stage = .waitingForHandoff
        job.lastUpdated = Date()
        job.diagnostics.sectionCount = document.sections.count
        job.diagnostics.sectionPreparationMilliseconds = milliseconds(since: started)
        job.diagnostics.parserPayloadBytes = 0
        try Task.checkCancellation()
        try ensureActive(job.id)
        try await repository.save(job)
        try Task.checkCancellation()
        try ensureActive(job.id)
        Self.logger.info(
            "Import \(job.id.uuidString, privacy: .public) prepared \(job.sections.count) sections and \(job.diagnostics.observationCount) observations"
        )
        await progress(job)
        return job
    }


    /// What one fast-path attempt produced: a reviewable job when it worked, and either way the time
    /// it spent, because that time is real whether or not the durable job ends up taking over.
    private struct FastPathAttempt {
        var assembled: WorkoutImportJob?
        var elapsedMilliseconds = 0
    }

    /// Try the fast path, returning a reviewable job when it produced one and nil when the durable
    /// job should take over.
    ///
    /// Every bounded import goes through the permissive sketch path first. The transport already
    /// accepts the same ten-photo limit as intake, and one multimodal call can preserve structure
    /// across adjacent screenshots without making each section pass the old semantic-transaction
    /// relationship rules independently. Anything this path cannot finish still falls through to
    /// the durable job, which remains the resumable retry for transport and provider failures.
    private func assembleOnFastPath(
        _ initialJob: WorkoutImportJob,
        catalog: [ExerciseDefinition],
        progress: @escaping ProgressHandler
    ) async -> FastPathAttempt {
        guard let streamer, !initialJob.pages.isEmpty else { return FastPathAttempt() }
        guard (try? ensureActive(initialJob.id)) != nil, !Task.isCancelled else { return FastPathAttempt() }

        var job = initialJob
        let images = await fastPathImages(for: job)
        let text = job.sections
            .sorted { $0.order < $1.order }
            .flatMap(\.observations)
            .map(\.text)
            .joined(separator: "\n")
        guard !images.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FastPathAttempt()
        }

        job.stage = .assembling
        job.lastUpdated = Date()
        try? await repository.save(job)
        await progress(job)

        let started = ContinuousClock.now
        let jobID = job.id
        let streamingBase = job
        let outcome = await WorkoutImportFastPath(streamer: streamer).run(
            images: images,
            text: text.isEmpty ? nil : text,
            catalog: catalog
        ) { [weak self] build, document in
            guard let self, await self.isActive(jobID) else { return }
            var streaming = streamingBase
            streaming.stage = .assembling
            streaming.parsedDocument = document
            streaming.draft = build.draft
            streaming.issues = build.issues
            streaming.evidence = build.evidence
            streaming.lastUpdated = Date()
            await progress(streaming)
        }

        let elapsed = milliseconds(since: started)
        guard (try? ensureActive(jobID)) != nil, !Task.isCancelled else {
            return FastPathAttempt(elapsedMilliseconds: elapsed)
        }
        job.diagnostics.parserMilliseconds += elapsed

        guard outcome.isWorthShowing, let build = outcome.build, let document = outcome.document else {
            // Falling through here costs the athlete a second of their daily imports, because both
            // endpoints charge one. That is a knowingly deferred decision, not an oversight: the
            // per-import cost of this architecture is about to change enough that any limit
            // calibrated against today's numbers would be calibrated against numbers that are
            // about to stop being true.
            Self.logger.info(
                "Import \(jobID.uuidString, privacy: .public) fast path yielded no usable structure (\(outcome.failureCode ?? "empty", privacy: .public)); handing off to the durable job"
            )
            return FastPathAttempt(elapsedMilliseconds: elapsed)
        }

        job.stage = .reviewing
        job.parsedDocument = document
        job.draft = build.draft
        job.issues = build.issues
        job.evidence = build.evidence
        job.diagnostics.parserModel = outcome.model
        job.failure = nil
        if let failureCode = outcome.failureCode {
            // The skeleton is right but the stream ended early, so the athlete is told the workout
            // may be short rather than being left to notice a missing exercise themselves.
            job.issues.append(WorkoutImportIssue(
                code: .ambiguousStructure,
                severity: .warning,
                message: "Reading stopped early, so the end of this workout may be missing. Check it against your photo."
            ))
            Self.logger.warning(
                "Import \(jobID.uuidString, privacy: .public) fast path ended with \(failureCode, privacy: .public) but kept a usable skeleton"
            )
        }
        job.lastUpdated = Date()
        do {
            try await repository.save(job)
        } catch {
            return FastPathAttempt(elapsedMilliseconds: elapsed)
        }
        await progress(job)
        return FastPathAttempt(assembled: job, elapsedMilliseconds: elapsed)
    }

    private func isActive(_ id: UUID) -> Bool { !cancelledJobIDs.contains(id) }

    /// The normalized pages, if they are still on disk. A missing file is not an error here — the
    /// recognized text alone is a valid source, and the fast path simply reads with less context.
    private func fastPathImages(for job: WorkoutImportJob) async -> [ImportedWorkoutImage] {
        var images: [ImportedWorkoutImage] = []
        for page in job.pages.sorted(by: { $0.index < $1.index }) where !page.relativeFilename.isEmpty {
            guard let data = try? await repository.imageData(
                jobID: job.id,
                relativeFilename: page.relativeFilename
            ) else { continue }
            images.append(ImportedWorkoutImage(
                data: data,
                pixelWidth: page.pixelWidth,
                pixelHeight: page.pixelHeight
            ))
        }
        return images
    }

    private func handOffAndWait(
        _ initialJob: WorkoutImportJob,
        catalog: [ExerciseDefinition],
        progress: @escaping ProgressHandler
    ) async -> WorkoutImportJob {
        var job = initialJob
        let started = ContinuousClock.now
        do {
            try ensureActive(job.id)
            let remote: WorkoutImportRemoteStatus
            if let serverJobID = job.serverProgress?.serverJobID {
                remote = try await parser.status(serverJobID: serverJobID)
            } else {
                let catalogHints = Self.providerCatalogHints(catalog)
                let request = WorkoutImportRemoteStartRequest(
                    clientJobID: job.id.uuidString,
                    requestID: job.requestID.uuidString,
                    jobHash: job.jobHash,
                    sections: job.sections,
                    catalogHints: catalogHints,
                    observability: .current(
                        catalogVersion: WorkoutImportStableIdentity.digest(catalogHints)
                    )
                )
                job.diagnostics.parserPayloadBytes = try request.encodedPayload().count
                Self.logger.info(
                    "Import \(job.id.uuidString, privacy: .public) encoded \(job.diagnostics.parserPayloadBytes) handoff bytes across \(job.sections.count) sections"
                )
                job.lastUpdated = Date()
                try await repository.save(job)
                await progress(job)
                remote = try await parser.start(request)
            }
            try Task.checkCancellation()
            try ensureActive(job.id)
            job = try await apply(remote, to: job, catalog: catalog, progress: progress)
            if remote.state != .completed && remote.state != .failed && remote.state != .cancelled {
                job = await poll(job, catalog: catalog, progress: progress)
            }
            return await recordParserTime(job, since: started, progress: progress)
        } catch is CancellationError {
            return job
        } catch {
            let reason = remoteFailureCode(error)
            let failed = await fail(
                job,
                stage: "server",
                reason: reason,
                retryable: isRetryableFailure(reason, for: job),
                progress: progress
            )
            return await recordParserTime(failed, since: started, progress: progress)
        }
    }

    private func recordParserTime(
        _ initialJob: WorkoutImportJob,
        since started: ContinuousClock.Instant,
        progress: ProgressHandler
    ) async -> WorkoutImportJob {
        var job = initialJob
        guard (try? ensureActive(job.id)) != nil, Task.isCancelled == false else { return job }
        job.diagnostics.parserMilliseconds += milliseconds(since: started)
        job.lastUpdated = Date()
        try? await repository.save(job)
        guard (try? ensureActive(job.id)) != nil, Task.isCancelled == false else { return initialJob }
        await progress(job)
        return job
    }

    private func poll(
        _ initialJob: WorkoutImportJob,
        catalog: [ExerciseDefinition],
        progress: @escaping ProgressHandler
    ) async -> WorkoutImportJob {
        var job = initialJob
        guard let serverJobID = job.serverProgress?.serverJobID else { return job }
        do {
            while true {
                try ensureActive(job.id)
                try await configuration.pollingDelay()
                try Task.checkCancellation()
                try ensureActive(job.id)
                let remote = try await parser.status(serverJobID: serverJobID)
                try Task.checkCancellation()
                try ensureActive(job.id)
                job = try await apply(remote, to: job, catalog: catalog, progress: progress)
                if remote.state == .completed || remote.state == .failed || remote.state == .cancelled { return job }
            }
        } catch is CancellationError {
            return job
        } catch {
            let reason = remoteFailureCode(error)
            return await fail(
                job,
                stage: "server",
                reason: reason,
                retryable: isRetryableFailure(reason, for: job),
                progress: progress
            )
        }
    }

    private func apply(
        _ remote: WorkoutImportRemoteStatus,
        to initialJob: WorkoutImportJob,
        catalog: [ExerciseDefinition],
        progress: @escaping ProgressHandler
    ) async throws -> WorkoutImportJob {
        try Task.checkCancellation()
        try ensureActive(initialJob.id)
        var job = initialJob
        job.serverProgress = .init(
            serverJobID: remote.serverJobID,
            status: remote.state.rawValue,
            completedSections: remote.completedSections,
            totalSections: remote.totalSections,
            failureCode: remote.failureCode
        )
        job.lastUpdated = Date()
        Self.logger.info(
            "Import \(job.id.uuidString, privacy: .public) received server state \(remote.state.rawValue, privacy: .public), \(remote.completedSections) of \(remote.totalSections) sections complete"
        )
        switch remote.state {
        case .queued, .processing:
            job.stage = .processingSections
        case .completed:
            guard let document = remote.document else { throw WorkoutParserError.invalidResponse }
            let normalized = WorkoutImportArtifactSanitizer.removingImportArtifacts(from:
                WorkoutImportSemanticNormalizer.normalize(
                document,
                observations: job.pages.flatMap(\.observations)
                )
            )
            let built = WorkoutImportDraftBuilder.build(normalized, catalog: catalog)
            guard !built.draft.workout.allExercises.isEmpty else {
                return await fail(
                    job,
                    stage: "server",
                    reason: "unusable_structured_result",
                    retryable: isRetryableFailure("unusable_structured_result", for: job),
                    progress: progress
                )
            }
            job.parsedDocument = normalized
            job.draft = built.draft
            job.issues = built.issues
            if job.pages.contains(where: { $0.stage == .noText }) {
                job.issues.append(WorkoutImportIssue(
                    code: .ambiguousStructure,
                    severity: .warning,
                    message: "One photo had no readable workout text. Review the imported workout against your photos."
                ))
            }
            job.evidence = built.evidence
            job.diagnostics.parserModel = remote.model
            job.stage = .reviewing
            job.failure = nil
        case .failed:
            let reason = remote.failureCode ?? "section_failed"
            return await fail(
                job,
                stage: "server",
                reason: reason,
                retryable: isRetryableFailure(reason, for: job),
                progress: progress
            )
        case .cancelled:
            job.stage = .failed
            job.failure = .init(
                stage: "server",
                reasonCode: "server_cancelled",
                isRetryable: false
            )
        }
        try await repository.save(job)
        try Task.checkCancellation()
        try ensureActive(job.id)
        await progress(job)
        return job
    }

    /// Whether re-running this saved import could plausibly succeed. Size, schema, and cancellation
    /// failures are terminal for the job whatever it holds; and with no stored sections there is
    /// nothing left to re-submit, so offering a retry would only fail the same way again.
    private func isRetryableFailure(_ reason: String, for job: WorkoutImportJob) -> Bool {
        guard !job.sections.isEmpty else { return false }
        return ![
            "schema_incompatible", "manifest_schema_incompatible", "result_too_large",
            "workout_too_large", "semantic_unit_too_large", "server_cancelled",
        ].contains(reason)
    }

    private func fail(
        _ initialJob: WorkoutImportJob,
        stage: String,
        reason: String,
        retryable: Bool,
        progress: ProgressHandler
    ) async -> WorkoutImportJob {
        var job = initialJob
        job.stage = .failed
        job.failure = .init(stage: stage, reasonCode: reason, isRetryable: retryable)
        job.lastUpdated = Date()
        Self.logger.error(
            "Import \(job.id.uuidString, privacy: .public) failed at \(stage, privacy: .public) with \(reason, privacy: .public); retryable: \(retryable)"
        )
        try? await repository.save(job)
        await progress(job)
        return job
    }

    private func ensureActive(_ id: UUID) throws {
        if cancelledJobIDs.contains(id) { throw CancellationError() }
    }

    private func localFailureCode(_ error: Error) -> String {
        switch error {
        case WorkoutImagePipelineError.noImages: "no_images"
        case WorkoutImagePipelineError.tooManyImages: "too_many_images"
        case WorkoutImagePipelineError.noText: "no_text"
        case WorkoutImagePipelineError.tooLarge: "image_too_large"
        case WorkoutImagePipelineError.unreadable: "image_unreadable"
        case WorkoutImportCoordinatorError.sourceResolutionRequired: "source_resolution_required"
        case WorkoutImportCoordinatorError.sourceDocumentTooLarge: "workout_too_large"
        case WorkoutImportCoordinatorError.replacementCountMismatch: "source_reselection_count_mismatch"
        case WorkoutImportSourceDocumentError.semanticUnitTooLarge: "semantic_unit_too_large"
        default: "local_failure"
        }
    }

    private func remoteFailureCode(_ error: Error) -> String {
        switch error as? WorkoutParserError {
        case .timedOut: "remote_timeout"
        case .schemaIncompatible: "schema_incompatible"
        default: "remote_unavailable"
        }
    }

    nonisolated static func providerCatalogHints(_ catalog: [ExerciseDefinition]) -> [String] {
        catalog.prefix(500).map { definition in
            var hint = definition.name
            for alias in definition.aliases where alias.caseInsensitiveCompare(definition.name) != .orderedSame {
                let separator = hint.contains(" | aliases: ") ? "; " : " | aliases: "
                let candidate = hint + separator + alias
                if candidate.count <= 120 {
                    hint = candidate
                }
            }
            return hint
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Self.millisecondsSince(start)
    }

    private nonisolated static func millisecondsSince(_ start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
