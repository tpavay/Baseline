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

// MARK: - The ONE recursive traversal (every structural locate/mutate goes through these two walks)

/// One node list in the workout tree, identified by the container that owns it: a block's top-level
/// nodes, a group's children, or a choice's options. This is the parent half of every "node UUID +
/// parent-container UUID" mutation target.
enum WorkoutNodeContainer: Equatable, Sendable {
    case block(UUID)
    case group(UUID)
    case choice(UUID)

    var id: UUID {
        switch self {
        case .block(let id), .group(let id), .choice(let id): id
        }
    }
}

/// Why a structural node mutation was refused. Typed so tool handlers can explain the exact
/// invariant that held instead of a generic failure.
enum WorkoutNodeStructureError: Error, Equatable, Sendable {
    case nodeNotFound
    case containerNotFound
    /// The destination is the moved node itself or inside its own subtree.
    case cycle
    /// A rest cannot be a direct choice option — an option must be selectable workload.
    case invalidChild
    case indexOutOfBounds(max: Int)
    /// Removing or moving out the sole option would leave the choice empty; remove the choice itself.
    case lastChoiceOption
}

extension WorkoutNode {
    /// Depth-first read-only visit of every child node list in this subtree, each identified by its
    /// owning container. `body` returns non-nil to stop the walk and surface that value.
    func withChildNodeLists<T>(_ body: ([WorkoutNode], WorkoutNodeContainer) -> T?) -> T? {
        switch self {
        case .exercise, .rest:
            return nil
        case .group(let group):
            if let result = body(group.children, .group(group.id)) { return result }
            for child in group.children {
                if let result = child.withChildNodeLists(body) { return result }
            }
            return nil
        case .choice(let choice):
            if let result = body(choice.options, .choice(choice.id)) { return result }
            for option in choice.options {
                if let result = option.withChildNodeLists(body) { return result }
            }
            return nil
        }
    }

    /// Depth-first mutating visit of every child node list in this subtree. `body` must mutate the
    /// list only when it handles the operation (returns non-nil); it may return non-nil without
    /// mutating to stop with a failure.
    mutating func mutateChildNodeLists<T>(_ body: (inout [WorkoutNode], WorkoutNodeContainer) -> T?) -> T? {
        switch self {
        case .exercise, .rest:
            return nil
        case .group(var group):
            if let result = body(&group.children, .group(group.id)) {
                self = .group(group)
                return result
            }
            for index in group.children.indices {
                if let result = group.children[index].mutateChildNodeLists(body) {
                    self = .group(group)
                    return result
                }
            }
            return nil
        case .choice(var choice):
            if let result = body(&choice.options, .choice(choice.id)) {
                self = .choice(choice)
                return result
            }
            for index in choice.options.indices {
                if let result = choice.options[index].mutateChildNodeLists(body) {
                    self = .choice(choice)
                    return result
                }
            }
            return nil
        }
    }

    /// Whether `id` names this node or any node in its subtree — the cycle check for moves.
    func containsNode(_ id: UUID) -> Bool {
        if self.id == id { return true }
        return withChildNodeLists { nodes, _ in
            nodes.contains { $0.id == id } ? true : nil
        } ?? false
    }
}

extension Workout {
    /// Read-only walk of every node list in the workout, in document order (each block's top-level
    /// list, then each container's list before its children's). `body` returns non-nil to stop.
    func withNodeLists<T>(_ body: ([WorkoutNode], WorkoutNodeContainer) -> T?) -> T? {
        for block in blocks {
            if let result = body(block.nodes, .block(block.id)) { return result }
            for node in block.nodes {
                if let result = node.withChildNodeLists(body) { return result }
            }
        }
        return nil
    }

    /// Mutating walk of every node list in the workout. Same contract as
    /// `WorkoutNode.mutateChildNodeLists`: `body` mutates only when it returns non-nil.
    mutating func mutateNodeLists<T>(_ body: (inout [WorkoutNode], WorkoutNodeContainer) -> T?) -> T? {
        for index in blocks.indices {
            if let result = body(&blocks[index].nodes, .block(blocks[index].id)) { return result }
            for nodeIndex in blocks[index].nodes.indices {
                if let result = blocks[index].nodes[nodeIndex].mutateChildNodeLists(body) { return result }
            }
        }
        return nil
    }
}

// MARK: - Derived node operations (thin wrappers; no separate recursion anywhere)

extension Workout {
    func findNode(_ id: UUID) -> WorkoutNode? {
        withNodeLists { nodes, _ in nodes.first { $0.id == id } }
    }

    /// The parent container and position of any node, or nil when no node has that ID.
    func locateNode(_ id: UUID) -> (container: WorkoutNodeContainer, index: Int)? {
        withNodeLists { nodes, container in
            nodes.firstIndex { $0.id == id }.map { (container, $0) }
        }
    }

    /// Resolve a container ID to the block, group, or choice that owns a node list.
    func nodeContainer(_ id: UUID) -> WorkoutNodeContainer? {
        if blocks.contains(where: { $0.id == id }) { return .block(id) }
        switch findNode(id) {
        case .group: return .group(id)
        case .choice: return .choice(id)
        default: return nil
        }
    }

    func nodes(in container: WorkoutNodeContainer) -> [WorkoutNode]? {
        switch container {
        case .block(let id):
            return blocks.first { $0.id == id }?.nodes
        case .group(let id):
            guard case .group(let group)? = findNode(id) else { return nil }
            return group.children
        case .choice(let id):
            guard case .choice(let choice)? = findNode(id) else { return nil }
            return choice.options
        }
    }

    /// Edit one node in place wherever it lives. `transform` returns false (without mutating) when
    /// the node exists but has the wrong type, so a typed wrapper can refuse cleanly.
    @discardableResult
    mutating func updateNode(_ id: UUID, _ transform: (inout WorkoutNode) -> Bool) -> Bool {
        mutateNodeLists { nodes, _ in
            guard let index = nodes.firstIndex(where: { $0.id == id }) else { return nil }
            return transform(&nodes[index])
        } ?? false
    }

    /// Detach any node from its current parent and return it. The caller owns re-insertion; the
    /// public move/remove operations below pair this with validation so no path can orphan a node.
    mutating func extractNode(_ id: UUID) -> WorkoutNode? {
        mutateNodeLists { nodes, _ in
            guard let index = nodes.firstIndex(where: { $0.id == id }) else { return nil }
            return nodes.remove(at: index)
        }
    }

    /// Insert a node into a container's list at a validated position (append when nil).
    @discardableResult
    mutating func insertNode(_ node: WorkoutNode, into containerID: UUID, at index: Int?) -> Bool {
        guard nodeContainer(containerID) != nil else { return false }
        return mutateNodeLists { nodes, container in
            guard container.id == containerID else { return nil }
            let target = index ?? nodes.endIndex
            guard target >= nodes.startIndex, target <= nodes.endIndex else { return false }
            nodes.insert(node, at: target)
            return true
        } ?? false
    }

    /// Move any node (exercise, group, rest, or choice subtree) into any container at a zero-based
    /// final position — the general reorder-and-reparent operation. Everything is validated against
    /// the current value before the node is detached, so a rejected move changes nothing:
    /// - the destination must exist and must not be inside the moved subtree (no cycles);
    /// - a rest cannot become a direct choice option;
    /// - the position is bounds-checked against the destination's final order;
    /// - the sole option of a choice cannot be moved out (the choice would become empty).
    /// Returns nil on success or the exact invariant that refused the move.
    mutating func moveNode(_ id: UUID, into containerID: UUID, at index: Int) -> WorkoutNodeStructureError? {
        guard let node = findNode(id), let source = locateNode(id) else { return .nodeNotFound }
        guard let destination = nodeContainer(containerID) else { return .containerNotFound }
        if id == containerID || node.containsNode(containerID) { return .cycle }
        if case .choice = destination, case .rest = node { return .invalidChild }
        if case .choice = source.container, source.container.id != containerID,
           (nodes(in: source.container)?.count ?? 0) <= 1 {
            return .lastChoiceOption
        }
        guard let destinationCount = nodes(in: destination)?.count else { return .containerNotFound }
        let finalCount = destinationCount - (source.container.id == containerID ? 1 : 0)
        guard index >= 0, index <= finalCount else { return .indexOutOfBounds(max: finalCount) }

        guard let extracted = extractNode(id) else { return .nodeNotFound }
        guard insertNode(extracted, into: containerID, at: index) else {
            // Unreachable after the validation above; restore so a bug can never orphan the node.
            _ = insertNode(extracted, into: source.container.id, at: nil)
            return .containerNotFound
        }
        if case .choice = source.container, source.container.id != containerID {
            clampSelectionCount(ofChoice: source.container.id)
        }
        return nil
    }

    /// Remove any node by ID, returning the removed subtree so callers can purge its performed
    /// records. Refuses to empty a choice: its sole option cannot be removed (remove the choice).
    mutating func removeNode(_ id: UUID) -> Result<WorkoutNode, WorkoutNodeStructureError> {
        guard let source = locateNode(id) else { return .failure(.nodeNotFound) }
        if case .choice = source.container, (nodes(in: source.container)?.count ?? 0) <= 1 {
            return .failure(.lastChoiceOption)
        }
        guard let removed = extractNode(id) else { return .failure(.nodeNotFound) }
        if case .choice = source.container {
            clampSelectionCount(ofChoice: source.container.id)
        }
        return .success(removed)
    }

    /// Restore the selection-count invariant for one choice after its options shrank.
    private mutating func clampSelectionCount(ofChoice choiceID: UUID) {
        updateChoice(choiceID) { choice in
            choice.selectionCount = min(choice.selectionCount, max(choice.options.count, 1))
        }
    }
}

// MARK: - Typed node updates (all routed through `updateNode`)

extension Workout {
    @discardableResult
    mutating func updateExercise(_ id: UUID, _ transform: (inout PlannedExercise) -> Void) -> Bool {
        updateNode(id) { node in
            guard case .exercise(var exercise) = node else { return false }
            transform(&exercise)
            node = .exercise(exercise)
            return true
        }
    }

    @discardableResult
    mutating func updateGroup(_ id: UUID, _ transform: (inout WorkoutGroup) -> Void) -> Bool {
        updateNode(id) { node in
            guard case .group(var group) = node else { return false }
            transform(&group)
            node = .group(group)
            return true
        }
    }

    @discardableResult
    mutating func updateChoice(_ id: UUID, _ transform: (inout WorkoutChoice) -> Void) -> Bool {
        updateNode(id) { node in
            guard case .choice(var choice) = node else { return false }
            transform(&choice)
            node = .choice(choice)
            return true
        }
    }

    @discardableResult
    mutating func updateRest(_ id: UUID, _ transform: (inout PlannedRest) -> Void) -> Bool {
        updateNode(id) { node in
            guard case .rest(var rest) = node else { return false }
            transform(&rest)
            node = .rest(rest)
            return true
        }
    }

    /// Converts a parser/user choice into one required sequence without changing child identities.
    /// This is the lossless correction for text such as "B. Deadlifts + lateral burpees."
    @discardableResult
    mutating func convertChoiceToRequiredGroup(_ id: UUID) -> Bool {
        updateNode(id) { node in
            guard case .choice(let choice) = node else { return false }
            node = .group(WorkoutGroup(
                id: choice.id,
                label: choice.label,
                execution: GroupExecution(repetition: .once),
                children: choice.options
            ))
            return true
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
