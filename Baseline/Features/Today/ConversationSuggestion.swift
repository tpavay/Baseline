import Foundation

/// The openers offered as tappable chips while a conversation is still empty. They answer "what can
/// I even say to this thing?". Each one maps to work `AgentTools` genuinely supports in that scope,
/// so a chip never invites a request the tool layer would only refuse.
struct ConversationSuggestion: Identifiable, Sendable {
    /// What the chip reads: short and action-oriented, so a row of them scans in one pass.
    let label: String
    /// What lands in the composer, phrased as the athlete would say it. The chip starts the
    /// sentence; it never sends it.
    let prompt: String

    var id: String { label }

    static func all(for mode: AskBaselineContext) -> [ConversationSuggestion] {
        switch mode {
        case .general: general
        case .workoutImport: workoutImport
        }
    }

    /// Whether refilling the composer with `draft` in it would destroy nothing the athlete wrote:
    /// it is blank, or it still reads exactly as a chip left it. Once they have adapted the sentence
    /// it is theirs, and a stray tap must not take it back. Read from the text itself rather than
    /// tracked alongside it, so there is no flag to fall out of step with what is in the box.
    static func isUnedited(draft: String, for mode: AskBaselineContext) -> Bool {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty || all(for: mode).contains { $0.prompt == typed }
    }

    /// Spans the general scope's real reach: today's plan (get_today / explain), building a workout
    /// (create_workout), the week (get_week_plan), and the context tools that change a plan (time
    /// available, constraints, sleep).
    private static let general: [ConversationSuggestion] = [
        .init(label: "What should I train?", prompt: "What should I train today?"),
        .init(label: "Build a workout", prompt: "Build me a workout for today"),
        .init(label: "Only 30 minutes", prompt: "I only have 30 minutes today"),
        .init(label: "Something hurts", prompt: "My knee hurts today"),
        .init(label: "Log how I slept", prompt: "I slept 6 hours last night"),
        .init(label: "Show my week", prompt: "What does my week look like?"),
    ]

    /// Draft fixes only. Every prompt here stays inside `ConversationService.permits`'s import
    /// allowlist, so no chip can strand the athlete on "that isn't available while fixing an
    /// imported workout".
    private static let workoutImport: [ConversationSuggestion] = [
        .init(label: "Show the workout", prompt: "Show me the workout as it stands"),
        .init(label: "Add an exercise", prompt: "Add 3 sets of 10 push-ups to the warm-up"),
        .init(label: "Replace an exercise", prompt: "Replace bench press with dumbbell push press"),
        .init(label: "Fix a set", prompt: "Make set 2 of the squat 5 reps at 100 kg"),
        .init(label: "Track load too", prompt: "Add a load field to the sled pull"),
    ]
}
