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
        let openers = ConversationSuggestion.all(for: .workoutImport)
        let refused = ["week", "plan", "sleep", "readiness", "template", "start", "finish", "health"]
        for s in openers {
            let text = (s.label + " " + s.prompt).lowercased()
            for word in refused {
                #expect(!text.contains(word), "Import chip \"\(s.label)\" invites \"\(word)\", which permits() denies.")
            }
        }
    }

    /// The two scopes reach different tools, so they must not open with the same menu.
    @Test func scopesOfferDistinctOpeners() {
        let general = Set(ConversationSuggestion.all(for: .general).map(\.prompt))
        let workoutImport = Set(ConversationSuggestion.all(for: .workoutImport).map(\.prompt))
        #expect(general.isDisjoint(with: workoutImport))
    }
}
