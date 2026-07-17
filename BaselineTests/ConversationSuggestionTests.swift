import Foundation
import Testing
@testable import Baseline

/// The chips are the first thing a new athlete reads, and tapping one is a promise the tool layer
/// has to keep. These guard the promise, not the wording.
struct ConversationSuggestionTests {

    @Test func everyModeOffersAScannableRowOfOpeners() {
        for mode in [AskBaselineContext.general, .workoutImport] {
            let suggestions = ConversationSuggestion.all(for: mode)
            // Enough to show the conversation's range, few enough to scan without paging a scroll view.
            #expect((4...6).contains(suggestions.count))
            #expect(Set(suggestions.map(\.id)).count == suggestions.count)
            for s in suggestions {
                #expect(!s.prompt.isEmpty)
                // A chip that wraps or truncates stops being scannable, so labels stay 2-5 words.
                #expect((2...5).contains(s.label.split(separator: " ").count))
            }
        }
    }

    /// A chip must fill the composer, never fire it, so its prompt has to survive `send`'s trim and
    /// its non-empty guard as the athlete-authored sentence it looks like.
    @Test func promptsAreSendableAsWritten() {
        for mode in [AskBaselineContext.general, .workoutImport] {
            for s in ConversationSuggestion.all(for: mode) {
                #expect(s.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == s.prompt)
            }
        }
    }

    /// The import scope denies by default (`ConversationService.permits`), so an opener there must
    /// name draft-editing work only. A chip that invites a plan or health change would answer
    /// "what can I say here?" with a refusal, the one outcome chips exist to prevent.
    @Test func importOpenersStayInsideTheDraftEditingAllowlist() {
        // A proxy for `permits()`: the vocabulary of the tools it shuts out, one group per denied
        // category. It reads whole words, so "Add a plank" is not mistaken for "plan".
        let refused = [
            // upsertConstraint / resolveConstraint
            "hurt", "hurts", "hurting", "pain", "painful", "sore", "soreness", "injury", "injured", "ache", "aches",
            // setTimeAvailable
            "minute", "minutes", "hour", "hours", "rushed",
            // setTraveling
            "travel", "traveling", "travelling", "hotel",
            // setIllness
            "sick", "ill", "illness", "unwell", "fever",
            // setCheckIn / explain
            "energy", "mood", "stress", "readiness", "recovery", "recovered",
            // setSleep / getSleep
            "sleep", "slept", "sleeping",
            // getWeekPlan / moveWorkout / swapWorkouts / skipWorkout / duplicateWorkout / deleteWorkout
            "plan", "plans", "week", "weeks", "schedule", "scheduled", "reschedule", "tomorrow", "skip", "skipped",
            // saveAsTemplate / createFromTemplate / updateTemplate / updateExercisePreference
            "template", "templates", "save", "saved", "preference", "preferences", "default", "defaults",
            // startWorkout / completeWorkout
            "start", "started", "begin", "finish", "finished", "complete", "completed", "done",
            // openAppleHealthSetup / getHRVReadings / getRestingHeartRate
            "health", "healthkit", "apple", "hrv",
        ]
        for s in ConversationSuggestion.all(for: .workoutImport) {
            let words = Set(
                (s.label + " " + s.prompt).lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
            )
            for word in refused {
                #expect(!words.contains(word), "Import chip \"\(s.label)\" invites \"\(word)\", which permits() denies.")
            }
        }
    }

    /// A chip overwrites the composer, so the row may only be on screen while there is nothing there
    /// worth keeping. Untouched chip text is fair game (that is how a second chip replaces a first);
    /// anything the athlete shaped themselves is not.
    @Test func onlyBlankOrUntouchedChipTextIsSafeToOverwrite() {
        let opener = ConversationSuggestion.all(for: .general)[0]
        #expect(ConversationSuggestion.isUnedited(draft: "", for: .general))
        #expect(ConversationSuggestion.isUnedited(draft: " \n  ", for: .general))
        #expect(ConversationSuggestion.isUnedited(draft: opener.prompt, for: .general))
        #expect(!ConversationSuggestion.isUnedited(draft: opener.prompt + " and my hip", for: .general))
        #expect(!ConversationSuggestion.isUnedited(draft: "Why is today so easy?", for: .general))
        // A prompt belonging to the other scope is not this scope's chip text.
        let imported = ConversationSuggestion.all(for: .workoutImport)[0]
        #expect(!ConversationSuggestion.isUnedited(draft: imported.prompt, for: .general))
    }

    /// The two scopes reach different tools, so they must not open with the same menu.
    @Test func scopesOfferDistinctOpeners() {
        let general = Set(ConversationSuggestion.all(for: .general).map(\.prompt))
        let workoutImport = Set(ConversationSuggestion.all(for: .workoutImport).map(\.prompt))
        #expect(general.isDisjoint(with: workoutImport))
    }
}
