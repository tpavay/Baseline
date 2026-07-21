import Foundation

struct WorkoutImportBuildResult: Sendable {
    var draft: WorkoutTemplateDraft
    var issues: [WorkoutImportIssue]
    var evidence: [WorkoutImportEvidence]
}

enum WorkoutImportDraftBuilder {
    static func build(_ document: ParsedWorkoutDocument, catalog: [ExerciseDefinition]) -> WorkoutImportBuildResult {
        var context = BuildContext(catalog: catalog)
        let blocks = document.blocks.map { parsedBlock in
            WorkoutBlock(name: parsedBlock.name, intent: parsedBlock.intent,
                         nodes: parsedBlock.nodes.map { context.buildNode($0) },
                         guidance: guidance(from: parsedBlock.notes))
        }

        if blocks.flatMap(\.exercises).isEmpty {
            context.issues.append(.init(code: .emptyWorkout, severity: .blocking,
                                        message: "No exercises were found. Try again with clearer workout photos."))
        }
        let workout = Workout(title: document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported workout" : document.title,
                              goal: document.goal, guidance: guidance(from: document.notes), blocks: blocks)
        return WorkoutImportBuildResult(draft: WorkoutTemplateDraft(workout: workout, tags: classify(document)),
                                        issues: context.issues, evidence: context.evidence)
    }

    private struct BuildContext {
        let catalog: [ExerciseDefinition]
        var issues: [WorkoutImportIssue] = []
        var evidence: [WorkoutImportEvidence] = []

        mutating func buildNode(_ parsed: ParsedWorkoutNode) -> WorkoutNode {
            switch parsed {
            case .exercise(let parsedExercise):
                return .exercise(buildExercise(parsedExercise))
            case .group(let parsedGroup):
                let id = UUID()
                let repetition: RepetitionRule
                if let seconds = parsedGroup.durationSeconds { repetition = .until(seconds: seconds) }
                else if let count = parsedGroup.repeatCount { repetition = .count(count) }
                else { repetition = .once }
                let cadence = parsedGroup.cadenceSeconds.map {
                    StartCadence(intervalSeconds: $0, scope: CadenceScope(rawValue: parsedGroup.cadenceScope ?? "") ?? .cycle)
                }
                let adjustments = parsedGroup.adjustments.compactMap { adjustment -> MetricAdjustment? in
                    guard let metric = WorkoutImportDraftBuilder.parseMetric(adjustment.metric), adjustment.step.isFinite else { return nil }
                    return MetricAdjustment(metric: metric, step: adjustment.step,
                                            minimum: adjustment.minimum, maximum: adjustment.maximum)
                }
                let execution = GroupExecution(repetition: repetition, cadence: cadence,
                                               scoring: WorkoutImportDraftBuilder.parseScoring(parsedGroup.scoring, metric: parsedGroup.scoreMetric),
                                               adjustments: adjustments)
                let children = parsedGroup.children.map { buildNode($0) }
                var guidance: CoachGuidance?
                if !parsedGroup.notes.isEmpty { guidance = CoachGuidance(formCues: parsedGroup.notes) }
                let group = WorkoutGroup(id: id, label: parsedGroup.label,
                                         phase: parsedGroup.phase.flatMap { WorkoutPhase(rawValue: WorkoutImportDraftBuilder.normalize($0)) },
                                         execution: execution, children: children, guidance: guidance,
                                         doseLayer: parsedGroup.doseLayer.flatMap { DoseLayer(rawValue: WorkoutImportDraftBuilder.normalize($0)) },
                                         isOptional: parsedGroup.isOptional)
                evidence.append(.init(nodeID: id, sourceObservationIDs: parsedGroup.sourceObservationIDs))
                if let ambiguity = parsedGroup.ambiguity, !ambiguity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(code: .ambiguousStructure, severity: .warning,
                                        message: ambiguity, nodeID: id))
                }
                return .group(group)
            case .rest(let parsedRest):
                let id = UUID()
                let rest = PlannedRest(id: id, durationSeconds: parsedRest.durationSeconds,
                                       placement: RestPlacement(rawValue: parsedRest.placement) ?? .inline,
                                       label: parsedRest.label, guidance: parsedRest.guidance)
                evidence.append(.init(nodeID: id, sourceObservationIDs: parsedRest.sourceObservationIDs))
                return .rest(rest)
            case .choice(let parsedChoice):
                let id = UUID()
                let choice = WorkoutChoice(id: id, label: parsedChoice.label,
                                           options: parsedChoice.options.map { buildNode($0) },
                                           selectionCount: max(parsedChoice.selectionCount, 1))
                evidence.append(.init(nodeID: id, sourceObservationIDs: parsedChoice.sourceObservationIDs))
                if let ambiguity = parsedChoice.ambiguity, !ambiguity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(code: .ambiguousStructure, severity: .warning,
                                        message: ambiguity, nodeID: id))
                }
                return .choice(choice)
            }
        }

        mutating func buildExercise(_ parsedExercise: ParsedWorkoutExercise) -> PlannedExercise {
            let exerciseID = UUID()
            let exact = WorkoutImportDraftBuilder.exactMatch(parsedExercise.name, in: catalog)
            // Catalog identity stays canonical. Context such as "warm-up", "main", distance,
            // or interval role belongs to the prescription/group, not in a second exercise name.
            var exercise = PlannedExercise(id: exerciseID, exerciseName: exact?.name ?? parsedExercise.name)
            exercise.definitionId = exact?.id
            exercise.prescription.restSeconds = parsedExercise.restSeconds.flatMap { $0 >= 0 ? $0 : nil }
            exercise.prescription.intent = parsedExercise.intent.flatMap(WorkoutImportDraftBuilder.parseIntent)
            for parsedTarget in parsedExercise.intensityTargets {
                if let target = WorkoutImportDraftBuilder.parseIntensity(parsedTarget) {
                    exercise.prescription.intensityTargets.append(target)
                } else {
                    let marker = WorkoutImportDraftBuilder.unresolvedIntensityMarker(parsedTarget)
                    exercise.prescription.intensityTargets.append(marker)
                    let occurrence = exercise.prescription.intensityTargets.count { $0 == marker }
                    issues.append(.init(
                        code: .unsupportedIntensityTarget,
                        severity: .blocking,
                        message: WorkoutImportDraftBuilder.unsupportedIntensityMessage(
                            parsedTarget,
                            exerciseName: parsedExercise.name
                        ),
                        exerciseID: exerciseID,
                        unresolvedIntensity: .init(
                            source: parsedTarget,
                            marker: marker,
                            occurrence: occurrence
                        )
                    ))
                }
            }
            if !exercise.prescription.intensityTargets.contains(where: WorkoutImportDraftBuilder.isQualitativeLoadTarget),
               let target = WorkoutImportDraftBuilder.qualitativeLoadTarget(in: parsedExercise.notes) {
                exercise.prescription.intensityTargets.append(.descriptive("Load target: \(target)"))
            }

            var selected = Set<MetricType>()
            let parsedSets = parsedExercise.sets.isEmpty ? [ParsedWorkoutSet(metrics: [])] : parsedExercise.sets
            exercise.prescription.sets = parsedSets.enumerated().map { setIndex, parsedSet in
                let setID = UUID()
                let built = buildMetrics(parsedSet.metrics, exerciseName: parsedExercise.name,
                                         exerciseID: exerciseID, setID: setID, selected: &selected,
                                         setNumber: setIndex + 1)
                let alternatives = parsedSet.alternatives.map { alternative in
                    let alternativeID = UUID()
                    let alternate = buildMetrics(alternative.metrics, exerciseName: parsedExercise.name,
                                                 exerciseID: exerciseID, setID: setID, selected: &selected,
                                                 setNumber: setIndex + 1,
                                                 alternativeID: alternativeID,
                                                 alternativeLabel: alternative.label)
                    return PlannedSetAlternative(id: alternativeID, label: alternative.label,
                                                 values: alternate.values, ranges: alternate.ranges)
                }
                return PlannedSet(id: setID, values: built.values,
                                  role: parsedSet.role.flatMap { SetRole(rawValue: WorkoutImportDraftBuilder.normalize($0)) } ?? .working,
                                  effortTarget: WorkoutImportDraftBuilder.parseEffort(parsedSet.effort),
                                  ranges: built.ranges, progressions: built.progressions,
                                  alternatives: alternatives)
            }
            if exercise.prescription.intensityTargets.contains(where: WorkoutImportDraftBuilder.isQualitativeLoadTarget),
               (exact?.supported ?? ExerciseCatalog.generic.supported).contains(.load) {
                selected.insert(.load)
            }
            if selected.isEmpty { selected.formUnion(exact?.defaults ?? []) }
            exercise.selectedMetrics = MetricType.allCases.filter { selected.contains($0) }
            if !parsedExercise.notes.isEmpty { exercise.guidance = CoachGuidance(formCues: parsedExercise.notes) }

            if exact == nil {
                issues.append(.init(code: .unknownExercise, severity: .blocking,
                                    message: "Choose an exercise for “\(parsedExercise.name)”.", exerciseID: exerciseID,
                                    candidates: WorkoutImportDraftBuilder.candidates(for: parsedExercise.name, in: catalog).map(\.id)))
            }
            evidence.append(.init(exerciseID: exerciseID, nodeID: exerciseID,
                                  sourceObservationIDs: parsedExercise.sourceObservationIDs))
            return exercise
        }

        private mutating func buildMetrics(_ parsedMetrics: [ParsedWorkoutMetric], exerciseName: String,
                                           exerciseID: UUID, setID: UUID, selected: inout Set<MetricType>,
                                           setNumber: Int,
                                           alternativeID: UUID? = nil,
                                           alternativeLabel: String? = nil)
        -> (values: MetricValues, ranges: [MetricTargetRange], progressions: [MetricProgression]) {
            var values = MetricValues()
            var ranges: [MetricTargetRange] = []
            var progressions: [MetricProgression] = []
            for metric in parsedMetrics {
                guard let type = WorkoutImportDraftBuilder.parseMetric(metric.type) else {
                    issues.append(.init(code: .unsupportedMetric, severity: .warning,
                                        message: "\(exerciseName): Baseline does not support \(metric.type) yet.", exerciseID: exerciseID))
                    continue
                }
                selected.insert(type)
                let location = metricLocation(setNumber: setNumber, alternativeLabel: alternativeLabel)
                guard metric.value.isFinite, metric.value >= 0 else {
                    issues.append(.init(code: .invalidValue, severity: .blocking,
                                        message: "\(exerciseName), \(location): enter a valid \(metric.type) value.",
                                        exerciseID: exerciseID, setID: setID,
                                        alternativeID: alternativeID, metric: type))
                    continue
                }
                guard let unit = WorkoutImportDraftBuilder.parseUnit(
                    metric.unit,
                    for: type,
                    sourceType: metric.type
                ) else {
                    issues.append(.init(code: .unsupportedMetric, severity: .blocking,
                                        message: "\(exerciseName), \(location): confirm the unit and value for \(type.label.lowercased()).",
                                        exerciseID: exerciseID, setID: setID,
                                        alternativeID: alternativeID, metric: type))
                    continue
                }
                // The source's unit is read, converted, and then deliberately forgotten. Writing it
                // back as a per-instance display override would show kilometres to an athlete who
                // has chosen Imperial, because that override wins over every tier beneath it in
                // `WorkoutStore.displayUnit(_:for:)`. Storage is canonical; display is the athlete's
                // `AppSettings.unitSystem`, and an imported workout gets no say in it.
                let canonical = MetricConvert.toCanonical(metric.value, type, from: unit)
                values[type] = canonical
                if let upper = metric.upperValue, upper.isFinite, upper >= 0 {
                    ranges.append(MetricTargetRange(metric: type, lower: canonical,
                                                    upper: MetricConvert.toCanonical(upper, type, from: unit)))
                }
                if let delta = metric.progressionDelta, delta.isFinite {
                    progressions.append(MetricProgression(metric: type,
                                                          delta: MetricConvert.toCanonical(delta, type, from: unit),
                                                          every: max(metric.progressionEvery ?? 1, 1),
                                                          unit: ProgressionUnit(rawValue: WorkoutImportDraftBuilder.normalize(metric.progressionUnit ?? "round")) ?? .round))
                }
            }
            return (values, ranges, progressions)
        }

        private func metricLocation(setNumber: Int, alternativeLabel: String?) -> String {
            guard let alternativeLabel else { return "set \(setNumber)" }
            let label = alternativeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? "set \(setNumber) alternative" : "set \(setNumber) alternative “\(label)”"
        }
    }

    static func exactMatch(_ name: String, in catalog: [ExerciseDefinition]) -> ExerciseDefinition? {
        let keys = identityKeys(for: name)
        return catalog.first { definition in
            let definitionKeys = [definition.name] + definition.aliases
            return definitionKeys.contains { keys.contains(normalizeIdentity($0)) }
        }
    }

    /// What Baseline offers the athlete for a name it could not place.
    ///
    /// Character similarity alone is the wrong instrument for choosing these. It scores "sled drag"
    /// against "sled push" as a near miss, because the words that differ are short — but they are
    /// different movements, and putting Sled Push in front of someone who wrote Sled Drag is the
    /// captain's own example of the mistake this whole path exists to avoid. It is one tap safer
    /// than resolving it silently, and that is all.
    ///
    /// So a candidate that spells out every word the source used wins outright: those are the
    /// different spellings of the same movement. Raw similarity is kept only as the fallback for a
    /// misread name, where no candidate accounts for the words and something is better than a blank
    /// picker.
    ///
    /// Hence filter, then choose. The threshold decides who is close enough to offer at all; only
    /// among those does spelling out every word win. Choosing first would let a word-complete
    /// candidate that is itself too far away suppress the fallback and then be dropped, which is
    /// how "we were not sure, here are the close ones" becomes "search 900 entries yourself".
    static func candidates(for name: String, in catalog: [ExerciseDefinition], limit: Int = 4) -> [ExerciseDefinition] {
        let key = normalizeIdentity(name)
        guard !key.isEmpty else { return [] }
        let wanted = identityWords(key)
        // One pass over each definition's spellings: `build` runs per streamed delta and calls this
        // for every unresolved name, so walking the catalog twice here is felt on the hot path.
        let eligible = catalog.compactMap { definition -> (ExerciseDefinition, Double, Bool)? in
            var best = 0.0
            var spellsOutEveryWord = false
            for spelling in [definition.name] + definition.aliases {
                let normalized = normalizeIdentity(spelling)
                best = max(best, similarity(key, normalized))
                if !wanted.isEmpty, !spellsOutEveryWord {
                    spellsOutEveryWord = wanted.isSubset(of: identityWords(normalized))
                }
            }
            return best >= 0.42 ? (definition, best, spellsOutEveryWord) : nil
        }
        let sameMovement = eligible.filter(\.2)
        return (sameMovement.isEmpty ? eligible : sameMovement)
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map(\.0)
    }

    /// The words of an already-normalized name that carry identity, with set and unit context
    /// dropped and a trailing "s" folded so "Box Jumps" and "Box Jump" are one movement.
    private static func identityWords(_ normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ")
            .filter { !isIdentityContextToken($0) }
            .map(singular)
            .filter { $0.count > 1 })
    }

    private static func singular(_ word: some StringProtocol) -> String {
        let value = String(word)
        let dropped = value.hasSuffix("s") ? String(value.dropLast()) : value
        return dropped.count > 1 ? dropped : value
    }

    /// Produces a deliberately narrow set of safe identity variants. This lets parser output such
    /// as "Run - warmup" and "100m strides" resolve without turning general fuzzy matching into an
    /// automatic catalog decision. Joined movements (for example, "squats + jump squats") remain
    /// unresolved so the user is never asked to log two movements as one.
    private static func identityKeys(for value: String) -> Set<String> {
        let full = normalizeIdentity(value)
        guard !full.isEmpty else { return [] }
        let strippedTokens = full.split(separator: " ").filter { !isIdentityContextToken($0) }
        let stripped = strippedTokens.joined(separator: " ")
        return stripped.isEmpty || stripped == full ? [full] : [full, stripped]
    }

    private static func normalizeIdentity(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return folded.map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func isIdentityContextToken(_ token: Substring) -> Bool {
        let value = String(token)
        let contextual: Set<String> = [
            "warmup", "warm", "up", "main", "cooldown", "cool", "down",
            "easy", "recovery", "work", "working", "interval", "intervals",
            "zone", "set", "sets", "rep", "reps", "round", "rounds",
            "m", "meter", "meters", "km", "kilometer", "kilometers",
            "mi", "mile", "miles", "s", "sec", "secs", "second", "seconds",
            "min", "mins", "minute", "minutes", "cal", "cals", "calorie", "calories",
        ]
        if contextual.contains(value) || ["z1", "z2", "z3", "z4", "z5"].contains(value) { return true }
        if value.allSatisfy(\.isNumber) { return true }

        let numericPrefix = value.prefix { $0.isNumber || $0 == "." }
        guard !numericPrefix.isEmpty else { return false }
        let suffix = String(value.dropFirst(numericPrefix.count))
        return contextual.contains(suffix)
    }

    private static func parseMetric(_ raw: String) -> MetricType? {
        switch normalize(raw).replacingOccurrences(of: " ", with: "") {
        case "reps", "rep", "count": .reps
        case "load", "weight": .load
        case "duration", "time", "seconds", "minutes": .duration
        case "distance", "meters", "kilometers", "miles": .distance
        case "calories", "cal", "kcal": .calories
        case "rpe": .rpe
        case "heartrate", "hr": .heartRate
        case "heartratezonetime", "hrzonetime", "zonetime": .heartRateZoneTime
        case "cadence", "rpm": .cadence
        case "power", "watts": .power
        case "pace": .pace
        default: nil
        }
    }

    private static func parseUnit(
        _ raw: String?,
        for metric: MetricType,
        sourceType: String? = nil
    ) -> MetricUnit? {
        let encodedUnit = sourceType.flatMap { unitEncodedByMetricType($0, metric: metric) }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let encodedUnit { return encodedUnit }
            switch metric {
            case .reps, .calories, .heartRate, .rpe:
                return metric.canonicalUnit
            case .load, .duration, .distance, .heartRateZoneTime, .cadence, .power, .pace:
                return nil
            }
        }
        let unit: MetricUnit? = switch normalize(raw).replacingOccurrences(of: " ", with: "") {
        case "reps", "rep", "count": .count
        case "kg", "kilogram", "kilograms": .kilograms
        case "lb", "lbs", "pound", "pounds": .pounds
        case "m", "meter", "meters": metric == .duration ? .minutes : .meters
        case "km", "kilometer", "kilometers": .kilometers
        case "mi", "mile", "miles": .miles
        case "s", "sec", "secs", "second", "seconds": .seconds
        case "min", "mins", "minute", "minutes": .minutes
        case "cal", "kcal", "calories": .kcal
        case "bpm": .bpm
        case "rpm": .rpm
        case "w", "watt", "watts": .watts
        case "s/m", "secondspermeter": .secondsPerMeter
        case "rpe": .rpe
        default: nil
        }
        guard let unit, metric.displayUnits.contains(unit) else { return nil }
        guard encodedUnit == nil || encodedUnit == unit else { return nil }
        return unit
    }

    private static func unitEncodedByMetricType(_ raw: String, metric: MetricType) -> MetricUnit? {
        switch (normalize(raw).replacingOccurrences(of: " ", with: ""), metric) {
        case ("seconds", .duration): .seconds
        case ("minutes", .duration): .minutes
        case ("meters", .distance): .meters
        case ("kilometers", .distance): .kilometers
        case ("miles", .distance): .miles
        case ("rpm", .cadence): .rpm
        case ("watts", .power): .watts
        default: nil
        }
    }

    private static func parseIntent(_ raw: String) -> TrainingIntent? {
        TrainingIntent(rawValue: normalize(raw).replacingOccurrences(of: " ", with: ""))
    }

    private static func parseScoring(_ raw: String?, metric: String?) -> ScoringMethod? {
        switch normalize(raw ?? "").replacingOccurrences(of: " ", with: "") {
        case "completion": return .completion
        case "elapsedtime", "fortime": return .elapsedTime(capSeconds: nil)
        case "roundsandreps", "amrap": return .roundsAndReps
        case "total": return metric.flatMap(parseMetric).map { .total(metric: $0) }
        default: return nil
        }
    }

    private static func parseEffort(_ parsed: ParsedEffortTarget?) -> EffortTarget? {
        guard let parsed else { return nil }
        switch normalize(parsed.type).replacingOccurrences(of: " ", with: "") {
        case "rpe": return parsed.value.map { .rpe($0) }
        case "rir": return parsed.value.map { .rir($0) }
        case "failure", "tofailure": return .toFailure
        case "max", "maxeffort", "maximum": return .maxEffort
        default: return nil
        }
    }

    private static func parseIntensity(_ parsed: ParsedIntensityTarget) -> IntensityTarget? {
        switch normalize(parsed.type).replacingOccurrences(of: " ", with: "") {
        case "heartratezone", "hrzone":
            return parsed.lower.map { .heartRateZone(Int($0.rounded())) }
        case "namedzone", "morpheus":
            guard let value = parsed.value else { return nil }
            return .namedZone(system: parsed.system ?? "Morpheus", range: value)
        case "rpe":
            guard let lower = parsed.lower else { return nil }
            return .rpe(lower: lower, upper: parsed.upper ?? lower)
        case "pace":
            return parsed.value.map(IntensityTarget.pace)
        case "power":
            guard let lower = parsed.lower,
                  let unit = parseUnit(parsed.unit, for: .power, sourceType: parsed.type) else { return nil }
            return .power(lower: lower, upper: parsed.upper ?? lower,
                          unit: unit)
        case "thresholdpercentage", "percentthreshold":
            guard let lower = parsed.lower else { return nil }
            return .thresholdPercentage(lower: lower, upper: parsed.upper ?? lower)
        case "description", "descriptive", "effort":
            return parsed.value.map(IntensityTarget.descriptive)
        default:
            return parsed.value.map(IntensityTarget.descriptive)
        }
    }

    private static func unsupportedIntensityMessage(
        _ parsed: ParsedIntensityTarget,
        exerciseName: String
    ) -> String {
        let type = parsed.type.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedType = normalize(type).replacingOccurrences(of: " ", with: "")
        if normalizedType == "power",
           let rawUnit = parsed.unit?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawUnit.isEmpty,
           parseUnit(rawUnit, for: .power) == nil {
            let unit = String(rawUnit.prefix(60))
            let range = intensityRangeSummary(parsed)
            return "\(exerciseName): choose a supported unit for the power target (\(range) \(unit)), or remove this unresolved target."
        }
        let label = type.isEmpty ? "intensity" : "\(String(type.prefix(60))) intensity"
        return "\(exerciseName): correct or remove the unresolved \(label) target."
    }

    private static func unresolvedIntensityMarker(_ parsed: ParsedIntensityTarget) -> IntensityTarget {
        let type = parsed.type.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = type.isEmpty ? "intensity" : normalize(type)
        var details: [String] = []
        if parsed.lower != nil { details.append(intensityRangeSummary(parsed)) }
        if let value = parsed.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            details.append(String(value.prefix(160)))
        }
        if let unit = parsed.unit?.trimmingCharacters(in: .whitespacesAndNewlines), !unit.isEmpty {
            details.append(String(unit.prefix(60)))
        }
        let suffix = details.isEmpty ? "" : ": \(details.joined(separator: " "))"
        return .descriptive("Unresolved \(label) target\(suffix)")
    }

    private static func intensityRangeSummary(_ parsed: ParsedIntensityTarget) -> String {
        guard let lower = parsed.lower else { return "missing value" }
        let lowerText = displayNumber(lower)
        guard let upper = parsed.upper, upper != lower else { return lowerText }
        return "\(lowerText)-\(displayNumber(upper))"
    }

    private static func displayNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private static func isQualitativeLoadTarget(_ target: IntensityTarget) -> Bool {
        qualitativeLoadTargetValue(target) != nil
    }

    private static func qualitativeLoadTargetValue(_ target: IntensityTarget) -> String? {
        guard case .descriptive(let value) = target else { return nil }
        let prefix = "load target:"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let target = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    private static func qualitativeLoadTarget(in notes: [String]) -> String? {
        let text = notes.joined(separator: " ").lowercased()
        if text.contains("race weight") { return "Race weight" }
        if text.contains("bodyweight") || text.contains("body weight") { return "Bodyweight" }
        return nil
    }

    private static func classify(_ document: ParsedWorkoutDocument) -> [WorkoutTag] {
        var searchable = [document.title, document.goal ?? ""]
        searchable.append(contentsOf: document.notes)
        for block in document.blocks {
            searchable += [block.name, block.intent ?? ""]
            searchable.append(contentsOf: block.notes)
            for node in block.nodes { searchable.append(contentsOf: node.searchableText) }
        }
        let text = searchable.joined(separator: " ").lowercased()
        var tags = Set<WorkoutTag>()
        if text.contains("strength") || text.contains("squat") || text.contains("deadlift") { tags.insert(.strength) }
        if text.contains("threshold") { tags.insert(.threshold) }
        if text.contains("interval") || text.contains("vo2") { tags.insert(.capacity) }
        if text.contains("speed") || text.contains("sprint") { tags.insert(.speed) }
        if text.contains("aerobic") || text.contains("easy") || text.contains("zone 2") { tags.insert(.aerobic) }
        if text.contains("recovery") { tags.insert(.recovery) }
        if text.contains("mobility") { tags.insert(.mobility) }
        if text.contains("durability") || text.contains("tendon") { tags.insert(.durability) }
        if text.contains("race") || text.contains("hyrox") { tags.insert(.raceSpecific) }
        return WorkoutTag.allCases.filter { tags.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func guidance(from notes: [String]) -> CoachGuidance? {
        let notes = notes.compactMap { note -> String? in
            let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return notes.isEmpty ? nil : CoachGuidance(formCues: notes)
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
