import CryptoKit
import Foundation

// MARK: - Import document

/// The provider-neutral structured document returned by any workout parser. It intentionally contains
/// no Baseline model identifiers; the deterministic builder is the only bridge into native workout data.
struct ParsedWorkoutDocument: Codable, Equatable, Sendable {
    var title: String
    var goal: String?
    var notes: [String] = []
    var blocks: [ParsedWorkoutBlock]

    private enum CodingKeys: String, CodingKey { case title, goal, notes, blocks }

    init(title: String, goal: String? = nil, notes: [String] = [], blocks: [ParsedWorkoutBlock]) {
        self.title = title
        self.goal = goal
        self.notes = notes
        self.blocks = blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        goal = try container.decodeIfPresent(String.self, forKey: .goal)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        blocks = try container.decode([ParsedWorkoutBlock].self, forKey: .blocks)
    }
}

struct ParsedWorkoutBlock: Codable, Equatable, Sendable {
    var name: String
    var intent: String?
    var notes: [String] = []
    var nodes: [ParsedWorkoutNode]
    var sourceObservationIDs: [String] = []

    init(name: String, intent: String? = nil, exercises: [ParsedWorkoutExercise],
         notes: [String] = [], sourceObservationIDs: [String] = []) {
        self.name = name
        self.intent = intent
        self.notes = notes
        nodes = exercises.map(ParsedWorkoutNode.exercise)
        self.sourceObservationIDs = sourceObservationIDs
    }

    init(name: String, intent: String? = nil, nodes: [ParsedWorkoutNode],
         notes: [String] = [], sourceObservationIDs: [String] = []) {
        self.name = name
        self.intent = intent
        self.notes = notes
        self.nodes = nodes
        self.sourceObservationIDs = sourceObservationIDs
    }

    var exercises: [ParsedWorkoutExercise] { nodes.flatMap(\.exercises) }

    private enum CodingKeys: String, CodingKey { case name, intent, notes, nodes, exercises, sourceObservationIDs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        intent = try container.decodeIfPresent(String.self, forKey: .intent)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        sourceObservationIDs = try container.decodeIfPresent([String].self, forKey: .sourceObservationIDs) ?? []
        if let parsedNodes = try container.decodeIfPresent([ParsedWorkoutNode].self, forKey: .nodes) {
            nodes = parsedNodes
        } else {
            nodes = try container.decodeIfPresent([ParsedWorkoutExercise].self, forKey: .exercises)?.map(ParsedWorkoutNode.exercise) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(intent, forKey: .intent)
        try container.encode(notes, forKey: .notes)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(sourceObservationIDs, forKey: .sourceObservationIDs)
    }
}

indirect enum ParsedWorkoutNode: Codable, Equatable, Sendable {
    case exercise(ParsedWorkoutExercise)
    case group(ParsedWorkoutGroup)
    case rest(ParsedWorkoutRest)
    case choice(ParsedWorkoutChoice)

    private enum CodingKeys: String, CodingKey { case type, exercise, group, rest, choice }
    private enum NodeType: String, Codable { case exercise, group, rest, choice }

    var exercises: [ParsedWorkoutExercise] {
        switch self {
        case .exercise(let exercise): [exercise]
        case .group(let group): group.children.flatMap(\.exercises)
        case .choice(let choice): choice.options.flatMap(\.exercises)
        case .rest: []
        }
    }

    var searchableText: [String] {
        switch self {
        case .exercise(let exercise): [exercise.name, exercise.intent ?? ""]
        case .group(let group): [group.label] + group.notes + group.children.flatMap(\.searchableText)
        case .rest(let rest): [rest.label, rest.guidance ?? ""]
        case .choice(let choice): [choice.label] + choice.options.flatMap(\.searchableText)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .exercise: self = .exercise(try container.decode(ParsedWorkoutExercise.self, forKey: .exercise))
        case .group: self = .group(try container.decode(ParsedWorkoutGroup.self, forKey: .group))
        case .rest: self = .rest(try container.decode(ParsedWorkoutRest.self, forKey: .rest))
        case .choice: self = .choice(try container.decode(ParsedWorkoutChoice.self, forKey: .choice))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exercise(let exercise):
            try container.encode(NodeType.exercise, forKey: .type)
            try container.encode(exercise, forKey: .exercise)
        case .group(let group):
            try container.encode(NodeType.group, forKey: .type)
            try container.encode(group, forKey: .group)
        case .rest(let rest):
            try container.encode(NodeType.rest, forKey: .type)
            try container.encode(rest, forKey: .rest)
        case .choice(let choice):
            try container.encode(NodeType.choice, forKey: .type)
            try container.encode(choice, forKey: .choice)
        }
    }
}

struct ParsedWorkoutGroup: Codable, Equatable, Sendable {
    var label: String
    var phase: String?
    var repeatCount: Int?
    var durationSeconds: Int?
    var cadenceSeconds: Int?
    var cadenceScope: String?
    var scoring: String?
    var scoreMetric: String?
    var adjustments: [ParsedMetricAdjustment] = []
    var children: [ParsedWorkoutNode]
    var notes: [String] = []
    var doseLayer: String?
    var isOptional = false
    var ambiguity: String?
    var sourceObservationIDs: [String] = []
}

struct ParsedWorkoutRest: Codable, Equatable, Sendable {
    var label: String = "Rest"
    var durationSeconds: Int?
    var placement: String = "inline"
    var guidance: String?
    var sourceObservationIDs: [String] = []
}

struct ParsedWorkoutChoice: Codable, Equatable, Sendable {
    var label: String
    var selectionCount = 1
    var options: [ParsedWorkoutNode]
    var ambiguity: String?
    var sourceObservationIDs: [String] = []
}

struct ParsedMetricAdjustment: Codable, Equatable, Sendable {
    var metric: String
    var step: Double
    var minimum: Double?
    var maximum: Double?
}

struct ParsedWorkoutExercise: Codable, Equatable, Sendable {
    var name: String
    var sets: [ParsedWorkoutSet]
    var restSeconds: Int?
    var intent: String?
    var notes: [String] = []
    var intensityTargets: [ParsedIntensityTarget] = []
    var sourceObservationIDs: [String] = []

    init(name: String, sets: [ParsedWorkoutSet], restSeconds: Int? = nil, intent: String? = nil,
         notes: [String] = [], intensityTargets: [ParsedIntensityTarget] = [],
         sourceObservationIDs: [String] = []) {
        self.name = name
        self.sets = sets
        self.restSeconds = restSeconds
        self.intent = intent
        self.notes = notes
        self.intensityTargets = intensityTargets
        self.sourceObservationIDs = sourceObservationIDs
    }

    private enum CodingKeys: String, CodingKey {
        case name, sets, restSeconds, intent, notes, intensityTargets, sourceObservationIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        sets = try container.decodeIfPresent([ParsedWorkoutSet].self, forKey: .sets) ?? []
        restSeconds = try container.decodeIfPresent(Int.self, forKey: .restSeconds)
        intent = try container.decodeIfPresent(String.self, forKey: .intent)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        intensityTargets = try container.decodeIfPresent([ParsedIntensityTarget].self, forKey: .intensityTargets) ?? []
        sourceObservationIDs = try container.decodeIfPresent([String].self, forKey: .sourceObservationIDs) ?? []
    }
}

struct ParsedWorkoutSet: Codable, Equatable, Sendable {
    var metrics: [ParsedWorkoutMetric]
    var role: String?
    var effort: ParsedEffortTarget?
    var alternatives: [ParsedSetAlternative] = []

    init(metrics: [ParsedWorkoutMetric], role: String? = nil, effort: ParsedEffortTarget? = nil,
         alternatives: [ParsedSetAlternative] = []) {
        self.metrics = metrics
        self.role = role
        self.effort = effort
        self.alternatives = alternatives
    }

    private enum CodingKeys: String, CodingKey { case metrics, role, effort, alternatives }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metrics = try container.decodeIfPresent([ParsedWorkoutMetric].self, forKey: .metrics) ?? []
        role = try container.decodeIfPresent(String.self, forKey: .role)
        effort = try container.decodeIfPresent(ParsedEffortTarget.self, forKey: .effort)
        alternatives = try container.decodeIfPresent([ParsedSetAlternative].self, forKey: .alternatives) ?? []
    }
}

struct ParsedWorkoutMetric: Codable, Equatable, Sendable {
    var type: String
    var value: Double
    var unit: String?
    var upperValue: Double?
    var progressionDelta: Double?
    var progressionEvery: Int?
    var progressionUnit: String?
}

struct ParsedSetAlternative: Codable, Equatable, Sendable {
    var label: String
    var metrics: [ParsedWorkoutMetric]
}

struct ParsedEffortTarget: Codable, Equatable, Sendable {
    var type: String
    var value: Double?
}

struct ParsedIntensityTarget: Codable, Equatable, Sendable {
    var type: String
    var lower: Double?
    var upper: Double?
    var value: String?
    var system: String?
    var unit: String?
}

// MARK: - Source and OCR

struct ImportedWorkoutImage: Equatable, Sendable {
    var data: Data
    var pixelWidth: Int
    var pixelHeight: Int
}

struct WorkoutTextObservation: Identifiable, Codable, Equatable, Sendable {
    struct Rect: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var id: String
    var text: String
    var confidence: Float
    var boundingBox: Rect
    var sourceImageIndex: Int = 0

    init(id: String, text: String, confidence: Float, boundingBox: Rect, sourceImageIndex: Int = 0) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.sourceImageIndex = sourceImageIndex
    }

    private enum CodingKeys: String, CodingKey { case id, text, confidence, boundingBox, sourceImageIndex }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decode(Float.self, forKey: .confidence)
        boundingBox = try container.decode(Rect.self, forKey: .boundingBox)
        sourceImageIndex = try container.decodeIfPresent(Int.self, forKey: .sourceImageIndex) ?? 0
    }
}

// MARK: - Review document

enum ImportIssueSeverity: String, Codable, Sendable {
    case warning
    case blocking
}

enum ImportIssueCode: String, Codable, Sendable {
    case unknownExercise
    case missingMetricValue
    case unsupportedMetric
    case unsupportedIntensityTarget
    case invalidValue
    case emptyWorkout
    case ambiguousStructure
}

struct WorkoutImportUnresolvedIntensity: Codable, Equatable, Sendable {
    /// The provider output is retained so review never discards the target's original meaning.
    var source: ParsedIntensityTarget
    /// A visible placeholder in the draft. Replacing or removing this exact occurrence resolves the issue.
    var marker: IntensityTarget
    /// One-based occurrence disambiguates repeated identical unresolved targets without opaque user-facing IDs.
    var occurrence: Int
}

struct WorkoutImportIssue: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var code: ImportIssueCode
    var severity: ImportIssueSeverity
    var message: String
    var exerciseID: UUID? = nil
    var setID: UUID? = nil
    /// Stable identity within `PlannedSet.alternatives`; nil addresses the primary set values.
    var alternativeID: UUID? = nil
    var nodeID: UUID? = nil
    var metric: MetricType? = nil
    var candidates: [String] = []
    var unresolvedIntensity: WorkoutImportUnresolvedIntensity? = nil
}

struct WorkoutImportEvidence: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var exerciseID: UUID? = nil
    var nodeID: UUID? = nil
    var sourceObservationIDs: [String]
}

struct WorkoutTemplateDraft: Codable, Equatable, Sendable {
    var workout: Workout
    var tags: [WorkoutTag] = []
}

struct WorkoutImportDiagnostics: Codable, Equatable, Sendable {
    var imageCount = 0
    var observationCount = 0
    var characterCount = 0
    var ocrMilliseconds = 0
    var parserMilliseconds = 0
    var parserModel: String?
    var imagePreparationMilliseconds = 0
    var sectionPreparationMilliseconds = 0
    var normalizedImageBytes = 0
    var parserPayloadBytes = 0
    var sectionCount = 0
}

enum WorkoutImportStatus: Equatable, Sendable {
    case selecting
    case loadingImages(completed: Int, total: Int)
    case recognizing(completed: Int, total: Int)
    case preparingSections
    case waitingForHandoff
    case retryingSections(completed: Int, total: Int)
    case processingSections(completed: Int, total: Int)
    case reviewing
    case saving
    case saved(templateID: UUID)
    case failed(message: String)
}

/// The import is a document with a lifecycle. The view model observes this value; it does not own the
/// domain state piecemeal. Keeping the aggregate independent makes resume/persistence possible later.
struct ImportSession: Identifiable, Sendable {
    var id = UUID()
    var sourceImages: [ImportedWorkoutImage] = []
    var sourcePages: [WorkoutImportSourcePage] = []
    var observations: [WorkoutTextObservation] = []
    var draft: WorkoutTemplateDraft?
    var issues: [WorkoutImportIssue] = []
    var evidence: [WorkoutImportEvidence] = []
    var diagnostics = WorkoutImportDiagnostics()
    var status: WorkoutImportStatus = .selecting
    var startedAt = Date()
    var lastUpdated = Date()

    var sourceImage: ImportedWorkoutImage? { sourceImages.first }

    var blockingIssues: [WorkoutImportIssue] { issues.filter { $0.severity == .blocking } }
    var canSave: Bool {
        guard let workout = draft?.workout else { return false }
        return blockingIssues.isEmpty && !workout.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workout.allExercises.isEmpty
    }
}

// MARK: - Materialization and duplicate detection

enum WorkoutImportMaterializer {
    /// Review-local identities are never allowed to leak into persisted authored content.
    static func materialize(_ draft: WorkoutTemplateDraft) -> Workout {
        var workout = draft.workout
        workout.id = UUID()
        workout.scheduledDate = nil
        workout.blocks = workout.blocks.map { block in
            var block = block
            block.id = UUID()
            for index in block.nodes.indices { block.nodes[index].regenerateIDs() }
            return block
        }
        return workout
    }
}

enum WorkoutFingerprint {
    static func value(for workout: Workout) -> String {
        var parts = [normalized(workout.title), normalized(workout.goal ?? "")]
        append(workout.guidance, to: &parts)
        for block in workout.blocks {
            parts += ["block", normalized(block.name), normalized(block.intent ?? "")]
            append(block.guidance, to: &parts)
            for node in block.nodes { append(node, to: &parts) }
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func stable(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }

    private static func append(_ node: WorkoutNode, to parts: inout [String]) {
        switch node {
        case .exercise(let exercise):
            parts += ["exercise", normalized(exercise.exerciseName), normalized(exercise.displayLabel ?? ""), exercise.definitionId ?? ""]
            parts += exercise.selectedMetrics.map(\.rawValue)
            for set in exercise.prescription.sets {
                parts += ["set", set.role.rawValue]
                for metric in MetricType.allCases {
                    if let value = set.values[metric] { parts.append("\(metric.rawValue)=\(stable(value))") }
                }
                for range in set.ranges {
                    parts += ["range", range.metric.rawValue, stable(range.lower), stable(range.upper)]
                }
                for progression in set.progressions {
                    parts += ["progression", progression.metric.rawValue, stable(progression.delta),
                              "\(progression.every)", progression.unit.rawValue]
                }
                for alternative in set.alternatives {
                    parts += ["alternative", normalized(alternative.label)]
                    for metric in MetricType.allCases {
                        if let value = alternative.values[metric] {
                            parts.append("\(metric.rawValue)=\(stable(value))")
                        }
                    }
                    for range in alternative.ranges {
                        parts += ["alternative-range", range.metric.rawValue,
                                  stable(range.lower), stable(range.upper)]
                    }
                }
            }
            parts += ["rest=\(exercise.prescription.restSeconds ?? -1)", exercise.prescription.intent?.rawValue ?? ""]
            append(exercise.guidance, to: &parts)
        case .group(let group):
            parts += ["group", normalized(group.label), repetition(group.execution.repetition),
                      "cadence=\(group.execution.cadence?.intervalSeconds ?? -1)",
                      group.execution.cadence?.scope.rawValue ?? "", group.doseLayer?.rawValue ?? "",
                      group.isOptional ? "optional" : "required"]
            for adjustment in group.execution.adjustments {
                parts += ["adjustment", adjustment.metric.rawValue, stable(adjustment.step)]
            }
            append(group.guidance, to: &parts)
            for child in group.children { append(child, to: &parts) }
        case .rest(let rest):
            parts += ["rest", normalized(rest.label), "\(rest.durationSeconds ?? -1)", rest.placement.rawValue]
        case .choice(let choice):
            parts += ["choice", normalized(choice.label), "\(choice.selectionCount)"]
            for option in choice.options { append(option, to: &parts) }
        }
    }

    private static func append(_ guidance: CoachGuidance?, to parts: inout [String]) {
        guard let guidance else { return }
        parts += ["guidance", normalized(guidance.goal ?? ""), normalized(guidance.tempo ?? "")]
        parts += guidance.formCues.map(normalized)
        parts += guidance.commonMistakes.map(normalized)
        parts.append(normalized(guidance.progressionNotes ?? ""))
    }

    private static func repetition(_ rule: RepetitionRule) -> String {
        switch rule {
        case .once: "once"
        case .count(let count): "count=\(count)"
        case .until(let seconds): "until=\(seconds)"
        }
    }
}
