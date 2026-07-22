import FirebaseFunctions
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Drives the real Ask Baseline chat surface through a complete agent workout edit and the
/// receipt-backed undo the athlete sees afterwards. The only stand-in is the model itself: a local
/// scripted "conversation" backend (reached through the Functions emulator origin) answers each
/// round the way the provider would - read the workout, edit it with the revision token it just
/// read, then reply. Everything else is the shipping path: the wire tool-call mapper, the on-device
/// tools, the versioned mutation envelope, the persisted receipt, and the chat's "Undo last edit"
/// affordance, which the test taps like an athlete would and then verifies the plan snapshot
/// actually restored.
///
/// Hosted in a window attached to the app's scene (sign-in gates a plain launch, and an unattached
/// window renders blank). Each stage writes a PNG so the surface can be looked at, not only
/// asserted about; the paths are printed for collection.
@MainActor
struct WorkoutUndoChatRenderTests {

    @Test func agentEditShowsReceiptBackedUndoAndTappingItRestoresTheWorkout() async throws {
        let server = try ScriptedConversationServer()
        defer { server.stop() }
        Functions.functions().useEmulator(withHost: "127.0.0.1", port: Int(server.port))

        let screen = try await UndoChatScreen()
        defer { screen.tearDown() }
        let originalRevision = screen.scheduled.workoutRevisionID

        screen.type(ScriptedConversationServer.athleteMessage)
        try screen.tapSend()
        try await screen.settle(until: { screen.element("Undo last edit") != nil },
                                message: "The undo affordance never appeared after the agent edit.")

        // The scripted model's edit landed as a versioned agent mutation with a durable receipt.
        let edited = try #require(screen.plan.scheduledWorkout(screen.scheduled.id))
        #expect(edited.workout.allExercises.first?.prescription.sets.first?.reps == 8)
        #expect(edited.workoutRevisionID != originalRevision)
        let versions = screen.plan.versions()
        #expect(versions.count == 2)
        let receipt = try #require(versions.last?.workoutMutationReceipt)
        #expect(receipt.actor == .agent)
        #expect(receipt.undoAvailable)
        #expect(receipt.afterRevisionToken == edited.workoutRevisionID)
        screen.saveReceipt(receipt, as: "mutation-receipt")
        screen.capture("01-agent-edit-offers-undo")

        try screen.tap("Undo last edit")
        try await screen.settle(until: { screen.transcriptShows("Undid that workout edit.") },
                                message: "The undo confirmation never appeared in the chat.")

        // One tap restored the immediately preceding snapshot and retired the affordance.
        let restored = try #require(screen.plan.scheduledWorkout(screen.scheduled.id))
        #expect(restored.workout.allExercises.first?.prescription.sets.first?.reps == 5)
        #expect(restored.workoutRevisionID == originalRevision)
        #expect(screen.plan.versions().count == 3)
        #expect(screen.plan.versions().last?.operation.kind == .undo)
        #expect(screen.element("Undo last edit") == nil, "A spent receipt must not keep offering undo.")
        screen.capture("02-undo-restored-original-workout")
    }
}

// MARK: - Screen harness

/// The assembled Ask Baseline screen over a real bound workout: a persisted plan with one scheduled
/// Squat workout, a WorkoutStore bound to it exactly the way the Today surface binds, and the sheet
/// hosted in a scene-attached window so its controls publish through accessibility.
@MainActor
private final class UndoChatScreen {
    let plan: PlanStore
    let scheduled: ScheduledWorkout
    private let window: UIWindow
    private let defaults: UserDefaults
    private let suiteName = "WorkoutUndoChatRenderTests"
    private let container: ModelContainer

    init() async throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models + SleepSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))

        let program = plan.addProgram(Program(name: "Strength Block", createdAt: .now))
        var squat = PlannedExercise(exerciseName: "Squat", definitionId: "back_squat")
        squat.prescription.sets = [PlannedSet(reps: 5, load: 100)]
        let workout = Workout(
            title: "Lower Strength",
            blocks: [WorkoutBlock(name: "Main", exercises: [squat], isDefault: true)]
        )
        scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id,
            date: .now,
            origin: .userCreated,
            workoutID: workout.id,
            workoutRevisionID: UUID(),
            workout: workout
        ))
        let workouts = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        workouts.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)

        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = AskBaselineSheet(mode: .general)
            .environment(TrainingContextStore(defaults: defaults))
            .environment(HealthService(defaults: defaults))
            .environment(OnboardingStore(defaults: defaults))
            .environment(workouts)
            .environment(plan)
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()

        try await settle(until: { [weak self] in self?.element("Send message") != nil },
                         message: "Ask Baseline never finished opening.")
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Reading and driving the screen

    func element(_ label: String) -> NSObject? {
        UndoChatScreen.elements(in: window).first { $0.accessibilityLabel == label }
    }

    func transcriptShows(_ text: String) -> Bool {
        UndoChatScreen.elements(in: window).contains {
            $0.accessibilityLabel == text && !($0 is UITextInput)
        }
    }

    func tap(_ label: String) throws {
        let target = try #require(element(label), "No element labelled \"\(label)\" on screen.")
        #expect(target.accessibilityActivate())
        flush()
    }

    func tapSend() throws { try tap("Send message") }

    func type(_ text: String) {
        guard let field = UndoChatScreen.allViews(in: window).lazy
            .compactMap({ $0 as? (UIView & UITextInput) }).first else { return }
        field.becomeFirstResponder()
        if let range = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument) {
            field.replace(range, withText: text)
        }
        flush()
    }

    // MARK: Evidence

    func capture(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return }
        let url = UndoChatScreen.evidenceDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    func saveReceipt(_ receipt: WorkoutMutationReceipt, as name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(receipt) else { return }
        let url = UndoChatScreen.evidenceDirectory.appendingPathComponent("\(name).json")
        try? data.write(to: url)
        print("RECEIPT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("undo-chat-evidence")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: Plumbing (same run-loop pumping the other hosted render suites use)

    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    private func flush() { spin(0.4) }

    func settle(until condition: () -> Bool, timeout: TimeInterval = 30, message: String) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            spin(0.1)
            await Task.yield()
            if condition() { flush(); return }
        }
        Issue.record("\(message)")
    }

    private static func allViews(in root: UIView) -> [UIView] {
        root.subviews.reduce(into: [root]) { $0 += allViews(in: $1) }
    }

    private static func elements(in root: UIView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()

        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                if view.isAccessibilityElement { out.append(view) }
                (view.accessibilityElements as? [NSObject])?.forEach(walk)
                view.subviews.forEach(walk)
            } else {
                out.append(object)
                let count = object.accessibilityElementCount()
                guard count != NSNotFound, count > 0 else { return }
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { walk(child) }
                }
            }
        }
        walk(root)
        return out
    }
}

// MARK: - Scripted backend

/// A loopback HTTP server speaking the callable-functions protocol, standing in for the model
/// provider only. It answers the `conversation` callable with the same three rounds a competent
/// model produces for "set squat to 8 reps": read the workout, edit it using the revision token
/// that read returned, then confirm. Requests from any other test (a different first message) get
/// a 500, which is indistinguishable from the unreachable backend those tests already tolerate.
private final class ScriptedConversationServer: @unchecked Sendable {
    static let athleteMessage = "Set squat to 8 reps"

    private let acceptQueue = DispatchQueue(label: "scripted-conversation-server.accept")
    private let clientQueue = DispatchQueue(label: "scripted-conversation-server.clients", attributes: .concurrent)
    private let socketFD: Int32
    let port: UInt16

    init() throws {
        // A plain loopback BSD socket: NWListener rejects binds from this hosted-test process, and
        // three tiny scripted exchanges do not need more than accept/recv/send.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                                  // let the kernel pick a free port
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var nameLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &nameLength) }
        }
        guard bound == 0, named == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw ServerError.socketFailed(code)
        }
        socketFD = fd
        port = UInt16(bigEndian: address.sin_port)

        acceptQueue.async { [weak self] in
            while let self {
                let client = accept(self.socketFD, nil, nil)
                guard client >= 0 else { return }             // stop() closed the socket
                self.clientQueue.async { self.serve(client) }
            }
        }
    }

    func stop() { close(socketFD) }

    private enum ServerError: Error { case socketFailed(Int32) }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if let response = responseIfComplete(buffer) {
                response.withUnsafeBytes { _ = send(client, $0.baseAddress, $0.count, 0) }
                return
            }
            let read = recv(client, &chunk, chunk.count, 0)
            guard read > 0 else { return }
            buffer.append(contentsOf: chunk[0..<read])
        }
    }

    /// Returns the full HTTP response once the request (headers + Content-Length body) is complete.
    private func responseIfComplete(_ raw: Data) -> Data? {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[..<headerEnd.lowerBound], as: UTF8.self)
        let contentLength = head
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = raw[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }

        let isConversation = head.split(separator: "\r\n").first?.contains("/conversation") == true
        guard isConversation else { return Self.http(200, json: ["result": [String: String]()]) }
        guard let payload = scriptedPayload(for: Data(body.prefix(contentLength))) else {
            return Self.http(500, json: ["error": ["status": "INTERNAL", "message": "unscripted request"]])
        }
        return Self.http(200, json: ["result": payload, "data": payload])
    }

    /// The model's next turn, derived only from the transcript the app sent - exactly the
    /// information the real provider would have.
    private func scriptedPayload(for body: Data) -> [String: Any]? {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = request["data"] as? [String: Any],
              let messagesJSON = data["messages"] as? String,
              messagesJSON.contains(Self.athleteMessage),
              let messages = (try? JSONSerialization.jsonObject(with: Data(messagesJSON.utf8))) as? [[String: Any]]
        else { return nil }

        let assistantRounds = messages.count { ($0["role"] as? String) == "assistant" }
        switch assistantRounds {
        case 0:
            return ["content": [["type": "tool_use", "id": "tool_read", "name": "get_current_workout", "input": [String: Any]()]]]
        case 1:
            // Read the revision token off the MUTATION TARGET line get_current_workout returned,
            // then edit against exactly that revision - the contract every mutation tool enforces.
            guard let token = Self.revisionToken(in: messagesJSON),
                  let setID = Self.firstSetID(in: messagesJSON) else { return nil }
            return ["content": [[
                "type": "tool_use", "id": "tool_edit", "name": "update_set",
                "input": [
                    "set_id": setID,
                    "patch": ["values": ["reps": 8]],
                    "expected_revision_token": token,
                ],
            ]]]
        default:
            return ["content": [["type": "text", "text": "Done - Squat set 1 is now 8 reps. Tap Undo last edit if you want the original back."]]]
        }
    }

    private static func revisionToken(in transcript: String) -> String? {
        guard let range = transcript.range(of: "revision_token=[0-9A-Fa-f-]{36}", options: .regularExpression) else { return nil }
        return String(transcript[range].dropFirst("revision_token=".count))
    }

    private static func firstSetID(in transcript: String) -> String? {
        guard let range = transcript.range(of: #"Set 1 \[id: [0-9A-Fa-f-]{36}\]"#, options: .regularExpression),
              let idRange = transcript[range].range(of: #"[0-9A-Fa-f-]{36}"#, options: .regularExpression) else {
            return nil
        }
        return String(transcript[idRange])
    }

    private static func http(_ status: Int, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Internal Server Error")\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
