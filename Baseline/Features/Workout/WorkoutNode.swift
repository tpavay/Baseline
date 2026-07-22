import Foundation

indirect enum WorkoutNode: Identifiable, Codable, Equatable, Sendable {
    case exercise(PlannedExercise)
    case group(WorkoutGroup)
    case rest(PlannedRest)
    case choice(WorkoutChoice)

    var id: UUID {
        switch self {
        case .exercise(let exercise): exercise.id
        case .group(let group): group.id
        case .rest(let rest): rest.id
        case .choice(let choice): choice.id
        }
    }

    var exercises: [PlannedExercise] {
        switch self {
        case .exercise(let exercise): [exercise]
        case .group(let group): group.children.flatMap(\.exercises)
        case .rest: []
        case .choice(let choice): choice.options.flatMap(\.exercises)
        }
    }

    var groups: [WorkoutGroup] {
        switch self {
        case .exercise, .rest: []
        case .group(let group): [group] + group.children.flatMap(\.groups)
        case .choice(let choice): choice.options.flatMap(\.groups)
        }
    }

    var choices: [WorkoutChoice] {
        switch self {
        case .exercise, .rest: []
        case .group(let group): group.children.flatMap(\.choices)
        case .choice(let choice): [choice] + choice.options.flatMap(\.choices)
        }
    }

    /// Choice-option IDs that are themselves the exercise being removed.
    /// Container options remain valid when one descendant moves or is removed, while nested choices
    /// are searched recursively for an exercise option that disappears.
    func choiceOptionIDs(containingExercise exerciseID: UUID) -> [UUID] {
        switch self {
        case .exercise, .rest:
            return []
        case .group(let group):
            return group.children.flatMap { $0.choiceOptionIDs(containingExercise: exerciseID) }
        case .choice(let choice):
            return choice.options.flatMap { option in
                let direct: [UUID]
                if case .exercise(let exercise) = option, exercise.id == exerciseID {
                    direct = [option.id]
                } else {
                    direct = []
                }
                return direct + option.choiceOptionIDs(containingExercise: exerciseID)
            }
        }
    }

    func resolvedExercises(choiceSelections: [UUID: Set<UUID>]) -> [PlannedExercise] {
        switch self {
        case .exercise(let exercise): return [exercise]
        case .group(let group): return group.children.flatMap { $0.resolvedExercises(choiceSelections: choiceSelections) }
        case .rest: return []
        case .choice(let choice):
            let selected = choiceSelections[choice.id] ?? Set(choice.options.prefix(choice.selectionCount).map(\.id))
            return choice.options.filter { selected.contains($0.id) }
                .flatMap { $0.resolvedExercises(choiceSelections: choiceSelections) }
        }
    }

    mutating func updateExercise(_ id: UUID, _ transform: (inout PlannedExercise) -> Void) -> Bool {
        switch self {
        case .exercise(var exercise):
            guard exercise.id == id else { return false }
            transform(&exercise)
            self = .exercise(exercise)
            return true
        case .group(var group):
            guard group.children.updateExercise(id, transform) else { return false }
            self = .group(group)
            return true
        case .choice(var choice):
            guard choice.options.updateExercise(id, transform) else { return false }
            self = .choice(choice)
            return true
        case .rest:
            return false
        }
    }

    mutating func updateGroup(_ id: UUID, _ transform: (inout WorkoutGroup) -> Void) -> Bool {
        switch self {
        case .group(var group):
            if group.id == id {
                transform(&group)
                self = .group(group)
                return true
            }
            guard group.children.updateGroup(id, transform) else { return false }
            self = .group(group)
            return true
        case .choice(var choice):
            guard choice.options.updateGroup(id, transform) else { return false }
            self = .choice(choice)
            return true
        case .exercise, .rest:
            return false
        }
    }

    mutating func convertChoiceToRequiredGroup(_ id: UUID) -> Bool {
        switch self {
        case .choice(let choice) where choice.id == id:
            self = .group(WorkoutGroup(
                id: choice.id,
                label: choice.label,
                execution: GroupExecution(repetition: .once),
                children: choice.options
            ))
            return true
        case .group(var group):
            guard group.children.convertChoiceToRequiredGroup(id) else { return false }
            self = .group(group)
            return true
        case .choice(var choice):
            guard choice.options.convertChoiceToRequiredGroup(id) else { return false }
            self = .choice(choice)
            return true
        case .exercise, .rest:
            return false
        }
    }

    mutating func regenerateIDs() {
        switch self {
        case .exercise(var exercise):
            exercise.id = UUID()
            exercise.prescription.sets = exercise.prescription.sets.map { set in
                var copy = set
                copy.id = UUID()
                copy.alternatives = copy.alternatives.map { alternative in
                    var alternative = alternative
                    alternative.id = UUID()
                    return alternative
                }
                return copy
            }
            self = .exercise(exercise)
        case .group(var group):
            group.id = UUID()
            for index in group.children.indices { group.children[index].regenerateIDs() }
            self = .group(group)
        case .rest(var rest):
            rest.id = UUID()
            self = .rest(rest)
        case .choice(var choice):
            choice.id = UUID()
            for index in choice.options.indices { choice.options[index].regenerateIDs() }
            self = .choice(choice)
        }
    }
}

extension Array where Element == WorkoutNode {
    var exercises: [PlannedExercise] { flatMap(\.exercises) }
    var groups: [WorkoutGroup] { flatMap(\.groups) }
    var choices: [WorkoutChoice] { flatMap(\.choices) }
    func choiceOptionIDs(containingExercise exerciseID: UUID) -> [UUID] {
        flatMap { $0.choiceOptionIDs(containingExercise: exerciseID) }
    }

    mutating func updateExercise(_ id: UUID, _ transform: (inout PlannedExercise) -> Void) -> Bool {
        for index in indices {
            if self[index].updateExercise(id, transform) { return true }
        }
        return false
    }

    mutating func updateGroup(_ id: UUID, _ transform: (inout WorkoutGroup) -> Void) -> Bool {
        for index in indices {
            if self[index].updateGroup(id, transform) { return true }
        }
        return false
    }

    mutating func convertChoiceToRequiredGroup(_ id: UUID) -> Bool {
        for index in indices {
            if self[index].convertChoiceToRequiredGroup(id) { return true }
        }
        return false
    }

    mutating func extractExercise(_ id: UUID) -> PlannedExercise? {
        for index in indices {
            switch self[index] {
            case .exercise(let exercise) where exercise.id == id:
                remove(at: index)
                return exercise
            case .group(var group):
                if let exercise = group.children.extractExercise(id) {
                    self[index] = .group(group)
                    return exercise
                }
            case .choice(var choice):
                if let exercise = choice.options.extractExercise(id) {
                    self[index] = .choice(choice)
                    return exercise
                }
            case .exercise, .rest:
                break
            }
        }
        return nil
    }

    mutating func removeExercise(_ id: UUID) -> Bool { extractExercise(id) != nil }

    mutating func duplicateExercise(_ id: UUID) -> UUID? {
        for index in indices {
            switch self[index] {
            case .exercise(let exercise) where exercise.id == id:
                var copy = WorkoutNode.exercise(exercise)
                copy.regenerateIDs()
                insert(copy, at: index + 1)
                return copy.id
            case .group(var group):
                if let copyID = group.children.duplicateExercise(id) {
                    self[index] = .group(group)
                    return copyID
                }
            case .choice(var choice):
                if let copyID = choice.options.duplicateExercise(id) {
                    self[index] = .choice(choice)
                    return copyID
                }
            case .exercise, .rest:
                break
            }
        }
        return nil
    }

    mutating func reorderExercise(_ id: UUID, to target: Int) -> Bool {
        if let source = firstIndex(where: {
            if case .exercise(let exercise) = $0 { return exercise.id == id }
            return false
        }) {
            guard target >= 0, target < count else { return false }
            let node = remove(at: source)
            insert(node, at: target)
            return true
        }
        for index in indices {
            switch self[index] {
            case .group(var group):
                if group.children.reorderExercise(id, to: target) {
                    self[index] = .group(group)
                    return true
                }
            case .choice(var choice):
                if choice.options.reorderExercise(id, to: target) {
                    self[index] = .choice(choice)
                    return true
                }
            case .exercise, .rest:
                break
            }
        }
        return false
    }
}

struct WorkoutBlock: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var intent: String?
    var guidance: CoachGuidance?
    var nodes: [WorkoutNode]
    var isDefault = false

    init(id: UUID = UUID(), name: String, intent: String? = nil, exercises: [PlannedExercise] = [],
         nodes: [WorkoutNode]? = nil, guidance: CoachGuidance? = nil, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.intent = intent
        self.guidance = guidance
        self.nodes = nodes ?? exercises.map(WorkoutNode.exercise)
        self.isDefault = isDefault
    }

    var exercises: [PlannedExercise] { nodes.exercises }
    var groups: [WorkoutGroup] { nodes.groups }
    var choices: [WorkoutChoice] { nodes.choices }

    private enum CodingKeys: String, CodingKey { case id, name, intent, guidance, nodes, exercises, isDefault }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        intent = try container.decodeIfPresent(String.self, forKey: .intent)
        guidance = try container.decodeIfPresent(CoachGuidance.self, forKey: .guidance)
        if let decodedNodes = try container.decodeIfPresent([WorkoutNode].self, forKey: .nodes) {
            nodes = decodedNodes
        } else {
            nodes = try container.decodeIfPresent([PlannedExercise].self, forKey: .exercises, default: [])
                .map(WorkoutNode.exercise)
        }
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(intent, forKey: .intent)
        try container.encodeIfPresent(guidance, forKey: .guidance)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(isDefault, forKey: .isDefault)
    }
}

private extension KeyedDecodingContainer {
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? defaultValue
    }
}
