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

    private(set) var log: [Message] = []
    private(set) var isThinking = false

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
        transcript.append(["role": "user", "content": userText])
        isThinking = true
        defer { isThinking = false }
        await runLoop()
    }

    private func runLoop() async {
        for _ in 0..<maxToolRounds {
            guard let content = await callFunction() else {
                log.append(Message(role: .baseline, text: "I couldn't reach the coach just now — try again in a moment."))
                return
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
            if toolUses.isEmpty { return }                 // final reply, no tools → done

            // Execute each requested tool on-device and feed results back for the model's follow-up.
            var results: [[String: Any]] = []
            for tu in toolUses {
                let resultText = ToolCallMapper.map(name: tu.name, input: tu.input)
                    .map { tools.dispatch($0).text } ?? "That tool call wasn't valid."
                results.append(["type": "tool_result", "tool_use_id": tu.id, "content": resultText])
            }
            transcript.append(["role": "user", "content": results])
        }
        log.append(Message(role: .baseline, text: "Let's take that one step at a time — ask me again?"))
    }

    private func callFunction() async -> [[String: Any]]? {
        let contextSummary = tools.dispatch(.getToday).text
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
