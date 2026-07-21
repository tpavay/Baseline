import Foundation

/// How sure Baseline is that a source name is a particular catalog movement.
enum ImportExerciseMatchConfidence: String, Equatable, Sendable {
    /// The name, or the name minus context words, *is* a catalog name or alias.
    case exact
    /// One catalog movement accounts for every meaningful word in the name, and no other does.
    case likely
    /// Baseline will not choose. The athlete does.
    case uncertain
}

struct ImportExerciseMatch: Equatable, Sendable {
    var sourceName: String
    /// Nil for `.uncertain` — deliberately. A resolved-but-wrong identity is silently unloggable
    /// history; an unresolved one is a question the athlete can answer in two taps.
    var definition: ExerciseDefinition?
    var confidence: ImportExerciseMatchConfidence
}

/// Source exercise name → catalog identity, with a confidence, using the catalog's own
/// casual-language aliases.
///
/// The rule the captain set: **surface near-misses rather than resolve them.** "Sled Drag" quietly
/// becoming "Sled Push" is worse than an honest unknown, because the athlete has no signal that
/// anything was decided and every set they log lands on the wrong movement's history. So widening
/// past an exact hit is bounded and has to be decisive: exactly one catalog movement must account
/// for every meaningful word in the source name. "Barbell Box Squat" does not become "Box Squat",
/// because "barbell" is unaccounted for and the difference might matter.
enum ImportExerciseMatcher {

    /// `snapshot` is the search index over `catalog`. It is passed in rather than built here because
    /// the streaming path re-converts the whole sketch after every delta, and rebuilding the index
    /// per exercise per delta is thousands of full-catalog builds for one import.
    static func match(
        _ name: String,
        in catalog: [ExerciseDefinition],
        snapshot: ExerciseCatalogSnapshot
    ) -> ImportExerciseMatch {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ImportExerciseMatch(sourceName: name, definition: nil, confidence: .uncertain)
        }

        // The existing exact matcher already folds case, punctuation, and context words such as
        // "warm-up", "400m", or "working set", so "Easy run" and "Run" reach the same definition.
        if let exact = WorkoutImportDraftBuilder.exactMatch(trimmed, in: catalog) {
            return ImportExerciseMatch(sourceName: trimmed, definition: exact, confidence: .exact)
        }

        let ranked = ExerciseSearch.run(.init(text: trimmed), in: snapshot).matches
        let wanted = meaningfulWords(trimmed)
        let sameMovement = wanted.isEmpty ? [] : ranked.filter { describes(wanted, exactly: $0) }

        if sameMovement.count == 1, let only = sameMovement.first {
            return ImportExerciseMatch(sourceName: trimmed, definition: only, confidence: .likely)
        }
        // What Baseline would not commit to is not carried here. The draft builder already raises a
        // blocking `unknownExercise` issue with its own candidates for exactly these names, so
        // computing a second list per delta only to discard it is duplicated work.
        return ImportExerciseMatch(sourceName: trimmed, definition: nil, confidence: .uncertain)
    }

    /// True when the definition's name or one of its aliases uses **exactly** the words the source
    /// used — no more and no fewer, order and punctuation aside.
    ///
    /// Both directions of inequality are a reason to stop and ask. Fewer words in the candidate
    /// drops a qualifier that may matter: "Barbell Box Squat" is not "Box Squat". More words in the
    /// candidate adds one the source never said: "Sled Drag" is not "Sled Drag - Harness", and it is
    /// certainly not "Sled Push". So this widening only reaches spellings of the same movement —
    /// word order, plurals, punctuation — and everything else becomes a question for the athlete.
    ///
    /// Each alias is checked whole rather than pooling them, since a definition whose aliases
    /// between them mention "barbell" and "box" has not shown that it means "barbell box".
    private static func describes(_ wanted: Set<String>, exactly definition: ExerciseDefinition) -> Bool {
        ([definition.name] + definition.aliases).contains { meaningfulWords($0) == wanted }
    }

    /// The words that carry identity: lowercased, punctuation split out, with pure numbers, units,
    /// and set/section context ("warm up", "working", "400m") removed, since those describe the
    /// prescription rather than the movement.
    ///
    /// A trailing "s" is dropped so "Wall Ball" and "Wall Balls" reach the same movement. That is
    /// the same deliberate rule `ExerciseSearch.containsWord` already applies, and for the same
    /// reason: the catalog names one movement both ways and a source should not have to guess which.
    /// It is a trailing-"s" rule and not stemming — "Flies" still misses "Fly".
    private static func meaningfulWords(_ value: String) -> Set<String> {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let words = folded
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return Set(words.compactMap { word -> String? in
            guard !word.allSatisfy(\.isNumber), !contextWords.contains(word), word.count > 1 else { return nil }
            let singular = word.hasSuffix("s") ? String(word.dropLast()) : word
            return singular.count > 1 ? singular : word
        })
    }

    private static let contextWords: Set<String> = [
        "warmup", "warm", "up", "main", "cooldown", "cool", "down", "easy", "recovery",
        "work", "working", "interval", "intervals", "zone", "set", "sets", "rep", "reps",
        "round", "rounds", "effort", "efforts", "the", "and", "for", "with", "of", "at", "on",
        "meter", "meters", "metre", "metres", "km", "kilometer", "kilometers", "mile", "miles",
        "sec", "secs", "second", "seconds", "min", "mins", "minute", "minutes",
        "cal", "cals", "calorie", "calories", "kg", "lb", "lbs",
    ]
}
