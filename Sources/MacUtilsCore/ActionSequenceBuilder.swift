import Foundation

public struct ActionBuilderStep: Hashable, Identifiable, Sendable {
    public let id: UUID
    public let actionID: ActionID
    public var parameters: ActionParameters

    public init(id: UUID = UUID(), actionID: ActionID, parameters: ActionParameters = [:]) {
        self.id = id
        self.actionID = actionID
        self.parameters = parameters
    }
}

public enum ActionSequenceBuilderError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownAction(ActionID)
    case stepNotFound(UUID)
    case parameterNotFound(actionID: ActionID, name: String)
    case wrongParameterType(name: String, expected: ActionValueType, actual: ActionValueType)
    case invalidMoveIndex(Int)

    public var description: String {
        switch self {
        case let .unknownAction(id):
            "Action '\(id)' is not available."
        case let .stepNotFound(id):
            "Builder step '\(id)' does not exist."
        case let .parameterNotFound(actionID, name):
            "Action '\(actionID)' has no parameter named '\(name)'."
        case let .wrongParameterType(name, expected, actual):
            "Parameter '\(name)' expects \(expected.rawValue), got \(actual.rawValue)."
        case let .invalidMoveIndex(index):
            "Step cannot be moved to index \(index)."
        }
    }
}

public struct ActionSequenceBuilder: Sendable {
    public let catalog: [ActionMetadata]
    public private(set) var steps: [ActionBuilderStep]

    private let registry: ActionRegistry
    private let scriptEngine: ActionScriptEngine

    public init(registry: ActionRegistry, steps: [ActionBuilderStep] = []) {
        self.registry = registry
        scriptEngine = ActionScriptEngine(registry: registry)
        catalog = registry.metadata
        self.steps = steps
    }

    @discardableResult
    public mutating func add(actionID: ActionID) throws -> UUID {
        guard registry.action(for: actionID) != nil else {
            throw ActionSequenceBuilderError.unknownAction(actionID)
        }
        let metadata = registry.action(for: actionID)?.metadata
        let defaults = ParameterSchema.defaults(for: metadata?.parameters ?? [])
        let step = ActionBuilderStep(actionID: actionID, parameters: defaults)
        steps.append(step)
        return step.id
    }

    public mutating func setParameter(stepID: UUID, name: String, value: ActionValue?) throws {
        guard let stepIndex = steps.firstIndex(where: { $0.id == stepID }) else {
            throw ActionSequenceBuilderError.stepNotFound(stepID)
        }
        guard let metadata = registry.action(for: steps[stepIndex].actionID)?.metadata,
              let definition = metadata.parameters.first(where: { $0.name == name }) else {
            throw ActionSequenceBuilderError.parameterNotFound(
                actionID: steps[stepIndex].actionID,
                name: name
            )
        }
        if let value, value.type != definition.type {
            throw ActionSequenceBuilderError.wrongParameterType(
                name: name,
                expected: definition.type,
                actual: value.type
            )
        }
        steps[stepIndex].parameters[name] = value
    }

    @discardableResult
    public mutating func duplicate(stepID: UUID) throws -> UUID {
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else {
            throw ActionSequenceBuilderError.stepNotFound(stepID)
        }
        let copy = ActionBuilderStep(
            actionID: steps[index].actionID,
            parameters: steps[index].parameters
        )
        steps.insert(copy, at: index + 1)
        return copy.id
    }

    public mutating func remove(stepID: UUID) throws {
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else {
            throw ActionSequenceBuilderError.stepNotFound(stepID)
        }
        steps.remove(at: index)
    }

    public mutating func move(stepID: UUID, to destination: Int) throws {
        guard let source = steps.firstIndex(where: { $0.id == stepID }) else {
            throw ActionSequenceBuilderError.stepNotFound(stepID)
        }
        guard (0..<steps.count).contains(destination) else {
            throw ActionSequenceBuilderError.invalidMoveIndex(destination)
        }
        let step = steps.remove(at: source)
        steps.insert(step, at: destination)
    }

    public mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { steps[$0] }
        for index in fromOffsets.sorted(by: >) {
            steps.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let insertionIndex = min(max(0, toOffset - removedBeforeDestination), steps.count)
        steps.insert(contentsOf: moving, at: insertionIndex)
    }

    public func metadata(for step: ActionBuilderStep) -> ActionMetadata? {
        registry.action(for: step.actionID)?.metadata
    }

    public func sequence(name: String) -> ActionSequence {
        ActionSequence(
            name: name,
            steps: steps.map {
                ActionInvocation(actionID: $0.actionID, parameters: $0.parameters)
            }
        )
    }

    public func canonicalDSL() -> String {
        steps.map { step in
            let metadata = registry.action(for: step.actionID)?.metadata
            return ActionDSL.serialize(
                ActionInvocation(actionID: step.actionID, parameters: step.parameters),
                metadata: metadata
            )
        }.joined(separator: "\n")
    }

    public mutating func replace(withDSL source: String, name: String = "Script") throws {
        let compiled = try scriptEngine.compile(source, name: name)
        let replacement = compiled.sequence.steps.map {
            ActionBuilderStep(actionID: $0.actionID, parameters: $0.parameters)
        }
        steps = replacement
    }

}
