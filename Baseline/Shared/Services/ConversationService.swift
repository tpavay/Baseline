import Foundation
@preconcurrency import FirebaseFunctions

/// The app side of the **Conversation Runtime**. Sends the transcript to the `conversation` Cloud
/// Function, then runs the on-device tool loop — map each `tool_use` → validated `AgentTools.Call`
/// → dispatch → `tool_result` → resend — until the model returns a final reply. The deterministic
/// engine owns truth; this only shuttles language and executes validated tools. See
/// docs/architecture.md (Context Engine) + docs/conversation-design.md.
@MainActor
@Observable
final class ConversationService {

    struct Message: Identifiable, Sendable {
        enum Role: Sendable { case you, baseline }
        let id = UUID()
        let role: Role
        let text: String
    }

    /// One behind-the-scenes tool the model actually invoked — surfaced in the state inspector so
    /// the athlete can see what the conversation logged, not just what it said.
    struct ToolEvent: Identifiable, Sendable {
        let id = UUID()
        let label: String
    }

    private(set) var log: [Message] = []
    private(set) var isThinking = false

    // Observability: the structured state + plan the conversation is building, exposed for the
    // "What Baseline knows" inspector.
    private(set) var latestDecision: DecisionEngine.Result?
    private(set) var latestPlan: PlanningEngine.Plan?
    private(set) var toolActivity: [ToolEvent] = []

    private let tools: AgentTools
    private let functions: Functions
    private var transcript: [[String: Any]] = []      // Anthropic wire-format messages
    private let maxToolRounds = 6                       // safety bound on tool ping-pong

    init(tools: AgentTools, functions: Functions = Functions.functions()) {
        self.tools = tools
        self.functions = functions
    }

    func send(_ text: String) async {
        let userText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty, !isThinking else { return }
        log.append(Message(role: .you, text: userText))
        // Checkpoint *before* this turn: if it fails, we roll the transcript back here so it never
        // ends on a dangling user/tool turn — otherwise the next send stacks two user turns and the
        // API rejects every subsequent message until the chat is reopened.
        let checkpoint = transcript.count
        transcript.append(["role": "user", "content": userText])
        isThinking = true
        defer { isThinking = false }
        let completed = await runLoop()
        if !completed { transcript.removeLast(transcript.count - checkpoint) }
    }

    /// Returns true only on a clean finish (a final assistant reply). False on a network failure or
    /// tool-round exhaustion — the caller rolls the failed turn out of the transcript.
    @discardableResult
    private func runLoop() async -> Bool {
        for _ in 0..<maxToolRounds {
            guard let content = await callFunction() else {
                log.append(Message(role: .baseline, text: "I couldn't reach the coach just now — try again in a moment."))
                return false
            }
            transcript.append(["role": "assistant", "content": content])

            var text = ""
            var toolUses: [(id: String, name: String, input: [String: Any])] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let s = block["text"] as? String { text += s }
                case "tool_use":
                    if let id = block["id"] as? String, let name = block["name"] as? String {
                        toolUses.append((id, name, block["input"] as? [String: Any] ?? [:]))
                    }
                default:
                    break
                }
            }
            if !text.isEmpty { log.append(Message(role: .baseline, text: text)) }
            if toolUses.isEmpty { return true }            // final reply, no tools → clean finish

            // Execute each requested tool on-device and feed results back for the model's follow-up.
            var results: [[String: Any]] = []
            for tu in toolUses {
                let resultText: String
                if let call = ToolCallMapper.map(name: tu.name, input: tu.input) {
                    let response = await tools.execute(call)   // retrieval tools query HealthKit / the store
                    resultText = response.text
                    record(call, response)
                } else {
                    resultText = "That tool call wasn't valid."
                }
                results.append(["type": "tool_result", "tool_use_id": tu.id, "content": resultText])
            }
            transcript.append(["role": "user", "content": results])
        }
        log.append(Message(role: .baseline, text: "Let's take that one step at a time — ask me again?"))
        return false   // tool rounds exhausted → transcript ends on a tool_result; roll it back
    }

    /// Keep the inspector's live view in sync: refresh the plan snapshot, and log mutations (not
    /// the automatic reads) to the activity feed.
    private func record(_ call: AgentTools.Call, _ response: AgentTools.Response) {
        if let d = response.decision { latestDecision = d }
        if let p = response.plan { latestPlan = p }
        switch call {
        case .getToday, .explain, .getCurrentWorkout: break   // pure reads — not "what changed"
        default: toolActivity.append(ToolEvent(label: call.activityLabel))
        }
    }

    private func callFunction() async -> [[String: Any]]? {
        let today = tools.dispatch(.getToday)
        latestDecision = today.decision
        latestPlan = today.plan
        let contextSummary = tools.contextSummary()   // full durable state = the model's memory
        // The transcript is heterogeneous JSON (non-Sendable), so ship it as a string; the request
        // dict is then [String: String] (Sendable) and safe to send across the callable boundary.
        guard let data = try? JSONSerialization.data(withJSONObject: transcript),
              let messagesJSON = String(data: data, encoding: .utf8) else { return nil }
        let request: [String: String] = ["messages": messagesJSON, "contextSummary": contextSummary]
        do {
            let result = try await functions.httpsCallable("conversation").call(request)
            let payload = result.data as? [String: Any]
            return payload?["content"] as? [[String: Any]]
        } catch {
            return nil
        }
    }
}
