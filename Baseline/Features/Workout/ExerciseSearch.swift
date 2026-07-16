import Foundation

/// Retrieval over the exercise catalog - the pure half of the assistant's `search_exercises` /
/// `get_exercise` tools. Kept out of the tool glue so the matching and ranking rules are unit-testable
/// against a snapshot without a model, a network, or an app.
///
/// The catalog is ~900 entries, far too large to sit in the system prompt, so the model retrieves from
/// it instead: a bounded, ranked page of compact rows plus the true total. Everything here is a pure
/// function of (query, snapshot) - no clock, no randomness - so a given query always ranks the same.
enum ExerciseSearch {

    /// How many matches one search hands back. The model reads every row, so this trades recall for a
    /// result it can actually reason over; the accompanying total tells it what it didn't see.
    static let resultLimit = 25

    // MARK: - Query

    /// A parsed, type-safe query. Every field is optional and all present fields are AND-ed. An entirely
    /// empty query is legitimate - it means "show me what you have" and yields a browse sample.
    struct Query: Equatable, Sendable {
        var text: String?
        var muscle: Muscle?
        var equipment: Equipment?
        var modality: Modality?
        var pattern: MovementPattern?
        var tag: ExerciseTag?
        var level: ExerciseLevel?

        var isEmpty: Bool {
            text == nil && muscle == nil && equipment == nil && modality == nil
                && pattern == nil && tag == nil && level == nil
        }
    }

    /// A filter value the model sent that isn't in the taxonomy. Reported back rather than dropped:
    /// silently ignoring `muscle: "banana"` would answer a question nobody asked with the whole catalog.
    struct UnknownFilter: Error, Equatable, Sendable {
        let field: String
        let value: String
        let valid: [String]
    }

    struct Results: Equatable, Sendable {
        let matches: [ExerciseDefinition]
        let total: Int
        /// True when the query carried no terms, so `matches` is a representative sample of the catalog
        /// rather than a filtered answer.
        let isBrowseSample: Bool

        var truncated: Bool { total > matches.count }
    }

    // MARK: - Parsing

    /// Parse the tool's raw strings into a typed query. Tolerant of how a model actually writes these:
    /// raw values (`frontDelts`), display names (`Front delts`), snake/kebab (`front_delts`), and common
    /// gym slang (`quads`) all land on the same case.
    static func parse(
        text: String? = nil, muscle: String? = nil, equipment: String? = nil, modality: String? = nil,
        pattern: String? = nil, tag: String? = nil, level: String? = nil
    ) -> Result<Query, UnknownFilter> {
        var query = Query()

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch resolve(muscle, field: "muscle", aliases: muscleAliases) {
        case .success(let v): query.muscle = v
        case .failure(let e): return .failure(e)
        }
        switch resolve(equipment, field: "equipment", aliases: equipmentAliases) {
        case .success(let v): query.equipment = v
        case .failure(let e): return .failure(e)
        }
        switch resolve(modality, field: "modality", aliases: [:] as [String: Modality]) {
        case .success(let v): query.modality = v
        case .failure(let e): return .failure(e)
        }
        switch resolve(pattern, field: "pattern", aliases: [:] as [String: MovementPattern]) {
        case .success(let v): query.pattern = v
        case .failure(let e): return .failure(e)
        }
        switch resolve(tag, field: "tag", aliases: [:] as [String: ExerciseTag]) {
        case .success(let v): query.tag = v
        case .failure(let e): return .failure(e)
        }
        switch resolve(level, field: "level", aliases: levelAliases) {
        case .success(let v): query.level = v
        case .failure(let e): return .failure(e)
        }
        return .success(query)
    }

    private static func resolve<T: TaxonomyFilterValue>(
        _ raw: String?, field: String, aliases: [String: T]
    ) -> Result<T?, UnknownFilter> {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .success(nil) }
        let key = squash(raw)
        if let alias = aliases[key] { return .success(alias) }
        if let hit = T.allCases.first(where: { squash($0.rawValue) == key || squash($0.displayName) == key }) {
            return .success(hit)
        }
        return .failure(UnknownFilter(field: field, value: raw, valid: T.allCases.map(\.rawValue)))
    }

    /// Slang the taxonomy's own names don't cover. Deliberately short - `squash` already absorbs case,
    /// spacing, and punctuation, so only genuinely different words belong here.
    private static let muscleAliases: [String: Muscle] = [
        "quads": .quadriceps, "quad": .quadriceps, "abs": .abdominals, "core": .abdominals,
        "pecs": .chest, "pec": .chest, "hams": .hamstrings, "bis": .biceps, "tris": .triceps,
        "glute": .glutes, "calf": .calves, "lat": .lats, "trap": .traps,
    ]
    private static let equipmentAliases: [String: Equipment] = [
        "db": .dumbbell, "dumbbells": .dumbbell, "bb": .barbell, "kb": .kettlebell,
        "bands": .band, "bodyweightonly": .bodyweight, "none": .bodyweight,
        "medball": .medicineBall, "bike": .bike, "erg": .rower,
    ]
    private static let levelAliases: [String: ExerciseLevel] = [
        "novice": .beginner, "easy": .beginner, "advanced": .expert, "hard": .expert,
    ]

    // MARK: - Running

    static func run(_ query: Query, in snapshot: ExerciseCatalogSnapshot) -> Results {
        let filtered = snapshot.definitions.filter { matchesFilters($0, query) }

        guard let text = query.text else {
            guard !query.isEmpty else {
                return Results(matches: browseSample(from: filtered), total: filtered.count, isBrowseSample: true)
            }
            // Filter-only ("show me quad exercises"): keep catalog order - curated built-ins first -
            // but float the movements that train the asked-for muscle *primarily*, since the page is
            // capped and an exercise that merely assists is a weaker answer.
            var ordered = filtered
            if let m = query.muscle {
                ordered = filtered.enumerated().sorted { lhs, rhs in
                    let lp = lhs.element.primaryMuscles.contains(m), rp = rhs.element.primaryMuscles.contains(m)
                    return lp == rp ? lhs.offset < rhs.offset : lp
                }.map(\.element)
            }
            return Results(matches: Array(ordered.prefix(resultLimit)), total: filtered.count, isBrowseSample: false)
        }

        let ranked = filtered
            .compactMap { def -> (def: ExerciseDefinition, rank: Rank)? in
                rank(def, text, query).map { (def, $0) }
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                // Shorter names are the plainer movement: "Bench Press" before "Barbell Guillotine
                // Bench Press". Name breaks the final tie so ordering is total and stable.
                if lhs.def.name.count != rhs.def.name.count { return lhs.def.name.count < rhs.def.name.count }
                return lhs.def.name < rhs.def.name
            }
        return Results(matches: ranked.prefix(resultLimit).map(\.def), total: ranked.count, isBrowseSample: false)
    }

    /// A single exercise by id, then by name/alias. Nil when the catalog genuinely doesn't have it -
    /// unlike `ExerciseCatalog.resolve`, which must always yield something to log against.
    static func lookUp(name: String?, id: String?, in snapshot: ExerciseCatalogSnapshot) -> ExerciseDefinition? {
        if let id, !id.isEmpty, let hit = snapshot.definition(id: id) { return hit }
        if let name, !name.isEmpty, let hit = snapshot.find(name) { return hit }
        // An id that missed may still name a movement ("deadlift" passed as id), and vice versa.
        if let id, !id.isEmpty, let hit = snapshot.find(id) { return hit }
        if let name, !name.isEmpty, let hit = snapshot.definition(id: name) { return hit }
        return nil
    }

    private static func matchesFilters(_ def: ExerciseDefinition, _ q: Query) -> Bool {
        if let m = q.muscle, !def.primaryMuscles.contains(m), !def.secondaryMuscles.contains(m) { return false }
        if let e = q.equipment, !def.equipment.contains(e) { return false }
        if let mo = q.modality, def.modality != mo { return false }
        if let p = q.pattern, !def.patterns.contains(p) { return false }
        if let t = q.tag, !def.tags.contains(t) { return false }
        if let l = q.level, def.level != l { return false }
        return true
    }

    /// Match strength, best first. `Int` rather than an enum so the ranks stay orderable and a
    /// muscle-relevance nudge can slot between tiers.
    private typealias Rank = Int

    private static func rank(_ def: ExerciseDefinition, _ text: String, _ q: Query) -> Rank? {
        let needle = squash(text)
        guard !needle.isEmpty else { return nil }
        let name = squash(def.name)
        let aliases = def.aliases.map(squash)

        var base: Rank
        if name == needle { base = 0 }
        else if aliases.contains(needle) { base = 10 }
        else if name.hasPrefix(needle) { base = 20 }
        else if containsWord(text, in: def.name) { base = 30 }
        else if name.contains(needle) { base = 40 }
        else if aliases.contains(where: { $0.contains(needle) }) { base = 50 }
        else { return nil }

        // With a muscle filter, an exercise that trains it primarily beats one that only assists.
        if let m = q.muscle, !def.primaryMuscles.contains(m) { base += 5 }
        return base
    }

    /// True when `needle` appears in `haystack` on a word boundary - so "row" hits "Barbell Row" but not
    /// "Eyebrow". Compared on a form where punctuation reads as a separator ("Push-Up" → "push up").
    private static func containsWord(_ needle: String, in haystack: String) -> Bool {
        let words = separated(haystack)
        let target = separated(needle)
        guard !target.isEmpty else { return false }
        return words.contains(" \(target) ")
    }

    /// Lowercased, punctuation-to-space, single-spaced, and padded - so a boundary test is a substring test.
    private static func separated(_ s: String) -> String {
        let mapped = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        let collapsed = String(mapped).split(separator: " ").joined(separator: " ")
        return collapsed.isEmpty ? "" : " \(collapsed) "
    }

    /// Case, spacing, and punctuation removed: "Push-Up", "push up", and "pushup" all collapse together.
    private static func squash(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A representative slice for "what exercises do you have?" - round-robin across modality so the
    /// sample spans the library instead of returning the 25 cardio machines the list happens to start
    /// with. Catalog order puts the curated built-ins first, so each bucket leads with the canonical ones.
    private static func browseSample(from definitions: [ExerciseDefinition]) -> [ExerciseDefinition] {
        var buckets: [[ExerciseDefinition]] = Modality.allCases.map { modality in
            definitions.filter { $0.modality == modality }
        }
        buckets.append(definitions.filter { $0.modality == nil })
        buckets.removeAll(where: \.isEmpty)
        guard !buckets.isEmpty else { return [] }

        var out: [ExerciseDefinition] = []
        var depth = 0
        while out.count < resultLimit {
            var placedAny = false
            for bucket in buckets where depth < bucket.count {
                out.append(bucket[depth])
                placedAny = true
                if out.count == resultLimit { return out }
            }
            guard placedAny else { break }   // every bucket exhausted
            depth += 1
        }
        return out
    }
}

/// A taxonomy axis usable as a search filter: a string-backed, enumerable enum with a display name.
/// Lets one generic parser accept a raw value, a display name, or slang for every axis.
protocol TaxonomyFilterValue: RawRepresentable, CaseIterable, Sendable where RawValue == String {
    var displayName: String { get }
}

extension Muscle: TaxonomyFilterValue {}
extension Equipment: TaxonomyFilterValue {}
extension Modality: TaxonomyFilterValue {}
extension MovementPattern: TaxonomyFilterValue {}
extension ExerciseTag: TaxonomyFilterValue {}
extension ExerciseLevel: TaxonomyFilterValue {}
