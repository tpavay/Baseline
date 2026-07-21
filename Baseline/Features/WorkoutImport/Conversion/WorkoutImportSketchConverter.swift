import Foundation

/// Turns a model's text comprehension (`WorkoutImportSketch`) into the structured, provider-neutral
/// `ParsedWorkoutDocument` the existing draft builder already knows how to make native.
///
/// This is the layer the old design did not have. It asked the model for a rigid representation and
/// rejected the whole parse when one structural rule was missed; normalization lived in a
/// prompt-plus-validator loop that could not be tested and did not converge. Here it is ordinary
/// deterministic code: matching names to the catalog, canonicalizing units, expanding a set count,
/// choosing the metric set per exercise. All of it is a pure function of (sketch, catalog).
///
/// What it will not do is invent. A number it cannot read stays as the coach's words, and a name it
/// cannot place stays unresolved so the athlete is asked. Judged on structure rather than field
/// completeness: right exercises, right order, right grouping is worth showing even with numbers
/// missing, because those are seconds of typing — a wrong skeleton wastes everything under it.
enum WorkoutImportSketchConverter {

    struct Result: Sendable {
        var document: ParsedWorkoutDocument
        /// Source names Baseline would not resolve, in document order. The draft builder raises its
        /// own blocking issue for each; this is here so a caller can report them without re-walking.
        var unresolvedNames: [String]
    }

    static func convert(_ sketch: WorkoutImportSketch, catalog: [ExerciseDefinition]) -> Result {
        var unresolved: [String] = []
        // One index per conversion. Matching is per exercise and conversion re-runs on every
        // streamed delta, so building this inside the matcher would rebuild it thousands of times.
        let snapshot = ExerciseCatalogSnapshot(catalog)
        let blocks = sketch.blocks.compactMap { block -> ParsedWorkoutBlock? in
            let nodes = groupedNodes(block.items, snapshot: snapshot, unresolved: &unresolved)
            guard !nodes.isEmpty else { return nil }
            return ParsedWorkoutBlock(
                name: cleaned(block.name) ?? "Workout",
                nodes: nodes,
                notes: block.notes.compactMap(cleaned)
            )
        }
        return Result(
            document: ParsedWorkoutDocument(
                title: cleaned(sketch.title) ?? "Workout",
                notes: sketch.notes.compactMap(cleaned),
                blocks: blocks
            ),
            unresolvedNames: unresolved
        )
    }

    // MARK: - Grouping

    /// Grouping is one level: an ordinal shared by consecutive items ("1" for a 1A/1B pair), with
    /// standalone movements carrying none. The letter is positional, so order inside the group
    /// supplies it and nothing needs to store it. A run of one is left standalone — a lone "1A" is
    /// a group with nothing to superset against, and rendering a one-child group is just noise.
    ///
    /// The decision is made on the children that survived, not on the raw run: an item whose name is
    /// blank produces no child, so a "1A"/"1B" pair with one unreadable half is still one exercise
    /// standing alone rather than a superset container with one row in it.
    private static func groupedNodes(
        _ items: [WorkoutImportSketch.Item],
        snapshot: ExerciseCatalogSnapshot,
        unresolved: inout [String]
    ) -> [ParsedWorkoutNode] {
        var nodes: [ParsedWorkoutNode] = []
        var index = 0
        while index < items.count {
            let key = cleaned(items[index].group)
            guard let key else {
                appendExercise(items[index], snapshot: snapshot, into: &nodes, unresolved: &unresolved)
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < items.count, cleaned(items[runEnd].group) == key { runEnd += 1 }
            var children: [ParsedWorkoutNode] = []
            for item in items[index..<runEnd] {
                appendExercise(item, snapshot: snapshot, into: &children, unresolved: &unresolved)
            }
            if children.count > 1 {
                nodes.append(.group(ParsedWorkoutGroup(label: key, children: children)))
            } else {
                nodes.append(contentsOf: children)
            }
            index = runEnd
        }
        return nodes
    }

    private static func appendExercise(
        _ item: WorkoutImportSketch.Item,
        snapshot: ExerciseCatalogSnapshot,
        into nodes: inout [ParsedWorkoutNode],
        unresolved: inout [String]
    ) {
        guard let exercise = exercise(from: item, snapshot: snapshot, unresolved: &unresolved) else { return }
        nodes.append(.exercise(exercise))
    }

    // MARK: - One exercise

    private static func exercise(
        from item: WorkoutImportSketch.Item,
        snapshot: ExerciseCatalogSnapshot,
        unresolved: inout [String]
    ) -> ParsedWorkoutExercise? {
        guard let sourceName = cleaned(item.name) else { return nil }
        let match = ImportExerciseMatcher.match(sourceName, in: snapshot)
        if match.confidence == .uncertain { unresolved.append(sourceName) }

        // An unresolved name is passed through verbatim so the draft builder fails to place it and
        // raises its blocking `unknownExercise` issue with candidates, which is the whole point.
        let name = match.definition?.name ?? sourceName
        let supported = Set(match.definition?.supported ?? ExerciseCatalog.generic.supported)

        var values = quantities(from: item, supported: supported)
        if values.isEmpty, supported.contains(.reps), let bare = ImportQuantityParser.bareCount(in: item.prescription) {
            values = [ImportQuantity(metric: .reps, canonicalValue: bare)]
        }

        // The set count repeats the same prescription; it does not multiply it. "15 x 400m" is
        // fifteen sets of 400 metres, not one set of 6 km.
        let setCount = ImportSetCountParser.setCount(in: item.sets) ?? 1
        let metrics = values.map {
            ParsedWorkoutMetric(
                type: $0.metric.rawValue,
                value: $0.canonicalValue,
                unit: $0.metric.canonicalUnit.rawValue
            )
        }
        let sets = (0..<setCount).map { _ in ParsedWorkoutSet(metrics: metrics) }

        return ParsedWorkoutExercise(
            name: name,
            sets: sets,
            restSeconds: restSeconds(from: item.rest),
            notes: coachNotes(for: item, converted: values, supported: supported)
        )
    }

    /// Every quantity the item states, from the fields that can carry one, keeping only metrics this
    /// movement actually logs. A distance on a bench press is a misread, not a prescription.
    private static func quantities(
        from item: WorkoutImportSketch.Item,
        supported: Set<MetricType>
    ) -> [ImportQuantity] {
        var found: [ImportQuantity] = []
        for text in [item.prescription, item.load] {
            for quantity in ImportQuantityParser.quantities(in: text)
            where supported.contains(quantity.metric) && !found.contains(where: { $0.metric == quantity.metric }) {
                found.append(quantity)
            }
        }
        return found
    }

    private static func restSeconds(from text: String?) -> Int? {
        guard let seconds = ImportQuantityParser.quantities(in: text)
            .first(where: { $0.metric == .duration })?.canonicalValue,
            seconds >= 0, seconds <= 3_600 else { return nil }
        return Int(seconds.rounded())
    }

    /// Everything the athlete still needs to read, verbatim and in a stable order.
    ///
    /// A field is kept as a note when it was not turned into a typed value — because it is a range,
    /// a pace, an RPE, a qualitative load, or a metric this movement does not log. Fields that *did*
    /// convert are dropped, since repeating "400m" beside a 400 m set is duplication the athlete
    /// then has to reconcile by hand.
    private static func coachNotes(
        for item: WorkoutImportSketch.Item,
        converted: [ImportQuantity],
        supported: Set<MetricType>
    ) -> [String] {
        var notes: [String] = []
        func keep(_ text: String?, whenUnconverted: Bool = true) {
            guard let value = cleaned(text), whenUnconverted, !notes.contains(value) else { return }
            notes.append(value)
        }
        // The set count is only dropped when it became real sets; a "6-8" that stayed prose matters.
        keep(item.sets, whenUnconverted: ImportSetCountParser.setCount(in: item.sets) == nil)
        keep(item.prescription, whenUnconverted: !describesOnly(item.prescription, converted, supported))
        keep(item.load, whenUnconverted: !describesOnly(item.load, converted, supported))
        keep(item.rest, whenUnconverted: restSeconds(from: item.rest) == nil)
        // Intensity is always coach text. That is the rule, not a limitation of this parser.
        keep(item.intensity)
        keep(item.note)
        return notes
    }

    /// True when everything `text` states was captured as a typed value, so keeping it as a note
    /// would only duplicate the sets.
    private static func describesOnly(
        _ text: String?,
        _ converted: [ImportQuantity],
        _ supported: Set<MetricType>
    ) -> Bool {
        let stated = ImportQuantityParser.quantities(in: text)
        guard !stated.isEmpty else { return false }
        guard stated.allSatisfy({ supported.contains($0.metric) }) else { return false }
        guard stated.allSatisfy({ quantity in
            converted.contains { $0.metric == quantity.metric && $0.canonicalValue == quantity.canonicalValue }
        }) else { return false }
        // Words beyond the quantity itself are the coach talking: "400m easy" keeps "easy".
        return ImportQuantityParser.residualText(in: text).isEmpty
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
