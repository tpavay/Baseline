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
    private let configuration: WorkoutImportCoordinatorConfiguration
    private var cancelledJobIDs: Set<UUID> = []
    private static let logger = Logger(subsystem: "com.tylerpavay.Baseline", category: "WorkoutImport")

    init(
        repository: any WorkoutImportJobStoring = FileWorkoutImportJobRepository(),
        normalizer: any WorkoutImageNormalizing = WorkoutImageNormalizer(),
        recognizer: any WorkoutTextRecognizing = VisionWorkoutTextRecognizer(),
        parser: any WorkoutImportJobParsing = FirebaseWorkoutImportJobParser(),
        configuration: WorkoutImportCoordinatorConfiguration = .init()
    ) {
        self.repository = repository
        self.normalizer = normalizer
        self.recognizer = recognizer
        self.parser = parser
        self.configuration = configuration
    }

    func start(
        jobID: UUID = UUID(),
        imageCount: Int,
        sourceItemIdentifiers: [String?] = [],
        catalog: [ExerciseDefinition],
        loadImage: @escaping @Sendable (Int) async throws -> Data,
        progress: @escaping ProgressHandler
    ) async -> WorkoutImportJob {
        let now = Date()
        var job = WorkoutImportJob(
            id: jobID,
            expectedPageCount: imageCount,
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
            job = try await prepareAndRecognize(
                job,
                imageCount: imageCount,
                catalog: catalog,
                loadImage: loadImage,
                progress: progress
            )
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

    func restoreLatest(catalog: [ExerciseDefinition], progress: @escaping ProgressHandler) async -> WorkoutImportJob? {
        do {
            await retryPendingCancellations()
            await repository.removeExpired(now: Date())
            guard var job = try await repository.mostRecentActiveJob(now: Date()) else { return nil }
            let hasInvalidReviewDraft = job.stage == .reviewing
                && job.draft?.workout.allExercises.isEmpty != false
            if !hasInvalidReviewDraft { await progress(job) }
            switch job.stage {
            case .waitingForHandoff, .processingSections:
                job = await handOffAndWait(job, catalog: catalog, progress: progress)
            case .reviewing:
                if hasInvalidReviewDraft {
                    job = await completeWithFallback(
                        job,
                        reason: "unusable_saved_draft",
                        catalog: catalog,
                        progress: progress
                    )
                }
            case .failed:
                if !job.sections.isEmpty,
                   Self.canUseRecognizedTextFallback(for: job.failure?.reasonCode) {
                    job = await completeWithFallback(
                        job,
                        reason: job.failure?.reasonCode ?? "section_failed",
                        catalog: catalog,
                        progress: progress
                    )
                }
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

    private func prepareAndRecognize(
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
        return try await prepareSections(job, progress: progress)
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
                let request = WorkoutImportRemoteStartRequest(
                    clientJobID: job.id.uuidString,
                    requestID: job.requestID.uuidString,
                    jobHash: job.jobHash,
                    sections: job.sections,
                    catalogHints: Self.providerCatalogHints(catalog)
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
            let fallback = await completeWithFallback(
                job,
                reason: reason,
                catalog: catalog,
                progress: progress
            )
            return await recordParserTime(fallback, since: started, progress: progress)
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
            return await completeWithFallback(
                job,
                reason: reason,
                catalog: catalog,
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
            let normalized = WorkoutImportFallbackBuilder.removingImportArtifacts(from:
                WorkoutImportSemanticNormalizer.normalize(
                document,
                observations: job.pages.flatMap(\.observations)
                )
            )
            let built = WorkoutImportDraftBuilder.build(normalized, catalog: catalog)
            guard !built.draft.workout.allExercises.isEmpty else {
                return await completeWithFallback(
                    job,
                    reason: "unusable_structured_result",
                    catalog: catalog,
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
            return await completeWithFallback(
                job,
                reason: remote.failureCode ?? "section_failed",
                catalog: catalog,
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

    private func completeWithFallback(
        _ initialJob: WorkoutImportJob,
        reason: String,
        catalog: [ExerciseDefinition],
        progress: ProgressHandler
    ) async -> WorkoutImportJob {
        var job = initialJob
        guard !job.sections.isEmpty else {
            return await fail(
                job,
                stage: "fallback",
                reason: reason,
                retryable: false,
                progress: progress
            )
        }
        let document = WorkoutImportFallbackBuilder.build(sections: job.sections, catalog: catalog)
        let built = WorkoutImportDraftBuilder.build(document, catalog: catalog)
        guard !built.draft.workout.allExercises.isEmpty else {
            return await fail(
                job,
                stage: "fallback",
                reason: reason,
                retryable: isRetryableFallbackFailure(reason),
                progress: progress
            )
        }
        job.parsedDocument = document
        job.draft = built.draft
        job.issues = built.issues
        job.issues.append(WorkoutImportIssue(
            code: .ambiguousStructure,
            severity: .warning,
            message: "Review the exercise order and details."
        ))
        if job.pages.contains(where: { $0.stage == .noText }) {
            job.issues.append(WorkoutImportIssue(
                code: .ambiguousStructure,
                severity: .warning,
                message: "One photo had no readable workout text. Review the imported workout against your photos."
            ))
        }
        job.evidence = built.evidence
        job.stage = .reviewing
        job.failure = nil
        job.lastUpdated = Date()
        Self.logger.warning(
            "Import \(job.id.uuidString, privacy: .public) recovered a catalog-backed draft after \(reason, privacy: .public)"
        )
        do {
            try await repository.save(job)
        } catch {
            return await fail(
                job,
                stage: "fallback",
                reason: "draft_persistence_failed",
                retryable: true,
                progress: progress
            )
        }
        await progress(job)
        return job
    }

    private func isRetryableFallbackFailure(_ reason: String) -> Bool {
        ![
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

    nonisolated private static func canUseRecognizedTextFallback(for reason: String?) -> Bool {
        guard let reason else { return false }
        return [
            "remote_timeout",
            "remote_unavailable",
            "section_invalid",
            "cross_section_assembly",
            "result_too_large",
            "worker_budget_exhausted",
            "schema_incompatible",
            "section_failed",
        ].contains(reason)
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
