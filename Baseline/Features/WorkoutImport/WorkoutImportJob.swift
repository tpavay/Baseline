import Foundation

enum WorkoutImportJobStage: String, Codable, Equatable, Sendable {
    case loadingImages
    case recognizingText
    case preparingSections
    case waitingForHandoff
    case processingSections
    case reviewing
    case failed
}

enum WorkoutImportPageStage: String, Codable, Equatable, Sendable {
    case pending
    case sourceStored
    case prepared
    case recognized
    case noText
    case failed
}

enum WorkoutImportSectionStage: String, Codable, Equatable, Sendable {
    case pending
    case processing
    case completed
    case failed
}

struct WorkoutImportFailure: Codable, Equatable, Sendable {
    var stage: String
    var reasonCode: String
    var isRetryable: Bool
}

struct WorkoutImportSourcePage: Identifiable, Codable, Equatable, Sendable {
    var id: String { "\(index):\(digest)" }
    var index: Int
    var sourceRelativeFilename: String = ""
    var relativeFilename: String
    var digest: String
    var pixelWidth: Int
    var pixelHeight: Int
    var stage: WorkoutImportPageStage
    var observations: [WorkoutTextObservation] = []
    var failureCode: String?
}

struct WorkoutImportProvenance: Codable, Equatable, Sendable {
    var primaryID: String
    var sourceObservationIDs: [String]
}

struct WorkoutImportSourceLine: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var text: String
    var sourceObservationIDs: [String]
    var sourceImageIndex: Int
    var boundingBox: WorkoutTextObservation.Rect
    var confidence: Float
}

struct WorkoutImportSourceSection: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var order: Int
    var observations: [WorkoutTextObservation]
    var provenanceObservationIDs: [String] = []
    var provenance: [WorkoutImportProvenance] = []
    var contextBefore: [String]
    var characterCount: Int
    var startScopeID: String = ""
    var endScopeID: String = ""
    /// Stable source-planned semantic paths. The model never creates or echoes these identifiers.
    /// Assembly uses path equality and depth to decide whether a boundary container must merge.
    var startFragmentPath: [String] = []
    var endFragmentPath: [String] = []
    var continuationFromSectionID: String?
    var stage: WorkoutImportSectionStage = .pending
}

struct WorkoutImportServerProgress: Codable, Equatable, Sendable {
    var serverJobID: String
    var status: String
    var completedSections: Int
    var totalSections: Int
    var failureCode: String?
}

struct WorkoutImportJob: Identifiable, Codable, Equatable, Sendable {
    static let schemaVersion = 3
    static let retentionInterval: TimeInterval = 24 * 60 * 60

    var schemaVersion: Int = Self.schemaVersion
    var id: UUID
    var requestID: UUID
    var jobHash: String
    var stage: WorkoutImportJobStage
    var expectedPageCount: Int
    /// Photos identifiers are best-effort reconciliation hints only. Import recovery never assumes
    /// PhotosPicker handles survive process loss.
    var sourceItemIdentifiers: [String?]?
    var pages: [WorkoutImportSourcePage]
    var sections: [WorkoutImportSourceSection]
    var serverProgress: WorkoutImportServerProgress?
    var parsedDocument: ParsedWorkoutDocument?
    var draft: WorkoutTemplateDraft?
    var issues: [WorkoutImportIssue]
    var evidence: [WorkoutImportEvidence]
    var diagnostics: WorkoutImportDiagnostics
    var failure: WorkoutImportFailure?
    var startedAt: Date
    var lastUpdated: Date
    var expiresAt: Date

    init(
        id: UUID = UUID(),
        requestID: UUID = UUID(),
        jobHash: String = "",
        stage: WorkoutImportJobStage = .loadingImages,
        expectedPageCount: Int = 0,
        sourceItemIdentifiers: [String?]? = nil,
        pages: [WorkoutImportSourcePage] = [],
        sections: [WorkoutImportSourceSection] = [],
        serverProgress: WorkoutImportServerProgress? = nil,
        parsedDocument: ParsedWorkoutDocument? = nil,
        draft: WorkoutTemplateDraft? = nil,
        issues: [WorkoutImportIssue] = [],
        evidence: [WorkoutImportEvidence] = [],
        diagnostics: WorkoutImportDiagnostics = .init(),
        failure: WorkoutImportFailure? = nil,
        startedAt: Date = Date(),
        lastUpdated: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.jobHash = jobHash
        self.stage = stage
        self.expectedPageCount = expectedPageCount
        self.sourceItemIdentifiers = sourceItemIdentifiers
        self.pages = pages
        self.sections = sections
        self.serverProgress = serverProgress
        self.parsedDocument = parsedDocument
        self.draft = draft
        self.issues = issues
        self.evidence = evidence
        self.diagnostics = diagnostics
        self.failure = failure
        self.startedAt = startedAt
        self.lastUpdated = lastUpdated
        self.expiresAt = expiresAt ?? startedAt.addingTimeInterval(Self.retentionInterval)
    }
}
