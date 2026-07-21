import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseCore

/// One event from the fast import path.
enum WorkoutImportStreamEvent: Equatable, Sendable {
    /// A raw JSON fragment of the model's sketch. Feed it to `WorkoutImportSketchStream`.
    case delta(String)
    case completed(model: String?)
    /// The stream ended badly. Anything already delivered is still valid and still usable.
    case failed(code: String)
}

/// The transport for the fast path. A protocol so the coordinator can be driven in tests with no
/// network, which is the only way the routing and partial-result rules are worth asserting.
protocol WorkoutImportStreaming: Sendable {
    /// `jobID` is the client's identity for the whole import. The server keys the athlete's daily
    /// import count and the per-job provider budget on it, so a fast-path attempt and the durable
    /// retry that may follow are one job rather than two.
    func stream(
        jobID: UUID,
        images: [ImportedWorkoutImage],
        text: String?,
        catalogHints: [String]
    ) -> AsyncThrowingStream<WorkoutImportStreamEvent, any Error>
}

enum WorkoutImportStreamError: LocalizedError, Equatable {
    case notSignedIn
    case unreachable
    case rejected(code: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Please sign in to import a workout."
        case .unreachable: "Baseline couldn't reach the workout reader. Try again."
        case .rejected(let code): "Baseline couldn't read that workout (\(code))."
        }
    }
}

/// Reads the `streamWorkoutImport` endpoint as server-sent events.
///
/// This is a plain `URLSession.bytes` request rather than a callable because a callable cannot
/// stream, and everything good about this path depends on the athlete seeing exercises while the
/// model is still writing them. The cost is that auth is explicit: the Firebase ID token and the App
/// Check token are attached as headers and verified server-side by hand.
struct FirebaseWorkoutImportStreamingParser: WorkoutImportStreaming {
    /// Generous: the whole point is that this finishes in seconds, and a stalled stream should
    /// surface as a retryable failure long before the athlete gives up on it.
    static let requestTimeoutSeconds: TimeInterval = 120

    private let endpoint: URL
    private let session: URLSession

    init?(region: String = "us-central1", session: URLSession = .shared) {
        guard let projectID = FirebaseApp.app()?.options.projectID,
              let url = URL(string: "https://\(region)-\(projectID).cloudfunctions.net/streamWorkoutImport") else {
            return nil
        }
        endpoint = url
        self.session = session
    }

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func stream(
        jobID: UUID,
        images: [ImportedWorkoutImage],
        text: String?,
        catalogHints: [String]
    ) -> AsyncThrowingStream<WorkoutImportStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await buildRequest(
                        jobID: jobID, images: images, text: text, catalogHints: catalogHints
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        continuation.yield(.failed(code: Self.failureCode(forStatus: http.statusCode)))
                        continuation.finish()
                        return
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let event = Self.event(from: line) else { continue }
                        continuation.yield(event)
                        if case .completed = event { break }
                        if case .failed = event { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decode one `data:` line. Unknown event types are skipped rather than treated as an error, so
    /// a server that learns to send more does not break a shipped client.
    static func event(from line: String) -> WorkoutImportStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "delta":
            guard let text = object["text"] as? String else { return nil }
            return .delta(text)
        case "done":
            return .completed(model: object["model"] as? String)
        case "error":
            return .failed(code: object["code"] as? String ?? "remote_unavailable")
        default:
            return nil
        }
    }

    static func failureCode(forStatus status: Int) -> String {
        switch status {
        case 401: "unauthenticated"
        case 429: "rate_limited"
        case 400: "malformed_payload"
        case 503: "remote_unavailable"
        default: "remote_unavailable"
        }
    }

    private func buildRequest(
        jobID: UUID,
        images: [ImportedWorkoutImage],
        text: String?,
        catalogHints: [String]
    ) async throws -> URLRequest {
        guard let user = Auth.auth().currentUser else { throw WorkoutImportStreamError.notSignedIn }
        let idToken = try await user.getIDToken()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        // App Check is enforced server-side only when configured, so a missing token here is not
        // fatal on its own; the server decides.
        if let appCheck = try? await AppCheck.appCheck().token(forcingRefresh: false) {
            request.setValue(appCheck.token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        request.httpBody = try JSONEncoder().encode(WorkoutImportStreamRequest(
            clientJobID: jobID.uuidString,
            images: images.map { .init(mediaType: "image/jpeg", data: $0.data.base64EncodedString()) },
            text: text,
            catalogHints: Array(catalogHints.prefix(500))
        ))
        return request
    }
}

struct WorkoutImportStreamRequest: Encodable, Sendable {
    struct Image: Encodable, Sendable {
        var mediaType: String
        var data: String
    }

    var clientJobID: String
    var images: [Image]
    var text: String?
    var catalogHints: [String]
}
