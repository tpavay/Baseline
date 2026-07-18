import Foundation
@preconcurrency import FirebaseFunctions

struct WorkoutParserResponse: Sendable {
    var document: ParsedWorkoutDocument
    var model: String?
}

protocol WorkoutParsing: Sendable {
    func parse(observations: [WorkoutTextObservation], catalogHints: [String]) async throws -> WorkoutParserResponse
}

enum WorkoutParserError: LocalizedError, Equatable {
    case invalidResponse
    case timedOut
    case remoteFailure
    case schemaIncompatible

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Baseline couldn't understand the parser response. Try again."
        case .timedOut: "Parsing took too long. Try again in a moment."
        case .remoteFailure: "Baseline couldn't parse that workout right now. Try again."
        case .schemaIncompatible: "This saved import is not compatible with this version of Baseline. Start over with the original photos."
        }
    }
}

protocol WorkoutImportRemoteCalling: AnyObject, Sendable {
    var timeoutInterval: TimeInterval { get set }
    func call(payload: String) async throws -> Any
}

private final class FirebaseWorkoutImportRemoteCallable: WorkoutImportRemoteCalling, @unchecked Sendable {
    private let callable: HTTPSCallable

    var timeoutInterval: TimeInterval {
        get { callable.timeoutInterval }
        set { callable.timeoutInterval = newValue }
    }

    init(functions: Functions) {
        callable = functions.httpsCallable("parseWorkoutImport")
    }

    func call(payload: String) async throws -> Any {
        try await callable.call(["payload": payload]).data
    }
}

actor FirebaseWorkoutParser: WorkoutParsing {
    nonisolated static let callableTimeoutSeconds: TimeInterval = 195

    private let makeCallable: @Sendable () -> any WorkoutImportRemoteCalling

    init(functions: Functions = Functions.functions()) {
        makeCallable = { FirebaseWorkoutImportRemoteCallable(functions: functions) }
    }

    init(makeCallable: @escaping @Sendable () -> any WorkoutImportRemoteCalling) {
        self.makeCallable = makeCallable
    }

    func parse(observations: [WorkoutTextObservation], catalogHints: [String]) async throws -> WorkoutParserResponse {
        struct Payload: Encodable {
            var observations: [WorkoutTextObservation]
            var catalogHints: [String]
        }
        let encoded = try JSONEncoder().encode(Payload(observations: observations, catalogHints: Array(catalogHints.prefix(500))))
        guard let payload = String(data: encoded, encoding: .utf8) else { throw WorkoutParserError.invalidResponse }
        let result: Any
        do {
            let callable = makeCallable()
            callable.timeoutInterval = Self.callableTimeoutSeconds
            result = try await callable.call(payload: payload)
        } catch {
            throw Self.mapRemoteError(error)
        }
        guard let object = result as? [String: Any], let documentObject = object["document"],
              JSONSerialization.isValidJSONObject(documentObject) else { throw WorkoutParserError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: documentObject)
        return WorkoutParserResponse(document: try JSONDecoder().decode(ParsedWorkoutDocument.self, from: data),
                                     model: object["model"] as? String)
    }

    nonisolated static func mapRemoteError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        let remote = error as NSError
        if remote.domain == FunctionsErrorDomain {
            if remote.code == FunctionsErrorCode.deadlineExceeded.rawValue {
                return WorkoutParserError.timedOut
            }
            if remote.code == FunctionsErrorCode.failedPrecondition.rawValue {
                return WorkoutParserError.schemaIncompatible
            }
        }
        return WorkoutParserError.remoteFailure
    }
}

struct WorkoutImportRemoteStartRequest: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var clientJobID: String
    var requestID: String
    var jobHash: String
    var sections: [WorkoutImportSourceSection]
    var catalogHints: [String]
    var observability: WorkoutImportClientObservability? = nil

    func encodedPayload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct WorkoutImportClientObservability: Codable, Equatable, Sendable {
    var appVersion: String
    var appBuild: String
    var iosVersion: String
    var deviceClass: String
    var catalogVersion: String

    static func current(catalogVersion: String) -> Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return .init(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            iosVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            deviceClass: "ios",
            catalogVersion: catalogVersion
        )
    }
}

enum WorkoutImportRemoteJobState: String, Codable, Equatable, Sendable {
    case queued
    case processing
    case completed
    case failed
    case cancelled
}

struct WorkoutImportRemoteStatus: Equatable, Sendable {
    var serverJobID: String
    var state: WorkoutImportRemoteJobState
    var completedSections: Int
    var totalSections: Int
    var document: ParsedWorkoutDocument?
    var model: String?
    var failureCode: String?
}

protocol WorkoutImportJobParsing: Sendable {
    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus
    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus
    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus
    func cancel(serverJobID: String, requestID: UUID) async throws
}

actor FirebaseWorkoutImportJobParser: WorkoutImportJobParsing {
    nonisolated static let callableTimeoutSeconds: TimeInterval = 45

    private let functions: Functions

    init(functions: Functions = Functions.functions()) {
        self.functions = functions
    }

    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        try await call(name: "startWorkoutImportJob", encoded: request.encodedPayload())
    }

    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus {
        try await call(name: "getWorkoutImportJobStatus", payload: ["serverJobID": serverJobID])
    }

    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus {
        try await call(
            name: "retryWorkoutImportJob",
            payload: ["serverJobID": serverJobID, "requestID": requestID.uuidString]
        )
    }

    func cancel(serverJobID: String, requestID: UUID) async throws {
        let _: WorkoutImportRemoteStatus = try await call(
            name: "cancelWorkoutImportJob",
            payload: ["serverJobID": serverJobID, "requestID": requestID.uuidString]
        )
    }

    private func call<Payload: Encodable>(
        name: String,
        payload: Payload
    ) async throws -> WorkoutImportRemoteStatus {
        try await call(name: name, encoded: JSONEncoder().encode(payload))
    }

    private func call(name: String, encoded: Data) async throws -> WorkoutImportRemoteStatus {
        guard let payloadString = String(data: encoded, encoding: .utf8) else {
            throw WorkoutParserError.invalidResponse
        }
        let callable = functions.httpsCallable(name)
        callable.timeoutInterval = Self.callableTimeoutSeconds
        let raw: Any
        do {
            raw = try await callable.call(["payload": payloadString]).data
        } catch {
            throw FirebaseWorkoutParser.mapRemoteError(error)
        }
        guard let object = raw as? [String: Any],
              let serverJobID = object["serverJobID"] as? String,
              let stateRaw = object["status"] as? String,
              let state = WorkoutImportRemoteJobState(rawValue: stateRaw),
              let completedSections = object["completedSections"] as? Int,
              let totalSections = object["totalSections"] as? Int else {
            throw WorkoutParserError.invalidResponse
        }
        var document: ParsedWorkoutDocument?
        if let documentObject = object["document"], JSONSerialization.isValidJSONObject(documentObject) {
            let data = try JSONSerialization.data(withJSONObject: documentObject)
            document = try JSONDecoder().decode(ParsedWorkoutDocument.self, from: data)
        }
        return WorkoutImportRemoteStatus(
            serverJobID: serverJobID,
            state: state,
            completedSections: completedSections,
            totalSections: totalSections,
            document: document,
            model: object["model"] as? String,
            failureCode: object["failureCode"] as? String
        )
    }
}

/// Rollout and test adapter that keeps the established parser result boundary while the durable
/// section endpoints are feature-gated. Production defaults to `FirebaseWorkoutImportJobParser`.
actor LegacyWorkoutImportJobParser: WorkoutImportJobParsing {
    private let parser: any WorkoutParsing
    private var results: [String: WorkoutImportRemoteStatus] = [:]

    init(parser: any WorkoutParsing) {
        self.parser = parser
    }

    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        let observations = request.sections.sorted { $0.order < $1.order }.flatMap(\.observations)
        let parsed = try await parser.parse(observations: observations, catalogHints: request.catalogHints)
        let status = WorkoutImportRemoteStatus(
            serverJobID: request.clientJobID,
            state: .completed,
            completedSections: request.sections.count,
            totalSections: request.sections.count,
            document: parsed.document,
            model: parsed.model,
            failureCode: nil
        )
        results[request.clientJobID] = status
        return status
    }

    func status(serverJobID: String) throws -> WorkoutImportRemoteStatus {
        guard let status = results[serverJobID] else { throw WorkoutParserError.invalidResponse }
        return status
    }

    func retry(serverJobID: String, requestID: UUID) throws -> WorkoutImportRemoteStatus {
        guard let status = results[serverJobID] else { throw WorkoutParserError.invalidResponse }
        return status
    }

    func cancel(serverJobID: String, requestID: UUID) {
        results.removeValue(forKey: serverJobID)
    }
}
