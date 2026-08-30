import Foundation

public struct ActionInvocation: Hashable, Codable, Sendable {
    public let actionID: ActionID
    public let parameters: ActionParameters

    public init(actionID: ActionID, parameters: ActionParameters = [:]) {
        self.actionID = actionID
        self.parameters = parameters
    }
}

public struct ActionSequence: Hashable, Codable, Sendable {
    public let name: String
    public let steps: [ActionInvocation]

    public init(name: String, steps: [ActionInvocation]) {
        self.name = name
        self.steps = steps
    }
}

public struct ActionStepResult: Hashable, Codable, Sendable {
    public let index: Int
    public let actionID: ActionID
    public let result: ActionResult
}

public struct ActionSequenceResult: Hashable, Codable, Sendable {
    public let runID: UUID
    public let steps: [ActionStepResult]
}

public enum ActionExecutionError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownAction(index: Int, actionID: ActionID)
    case missingParameter(index: Int, actionID: ActionID, name: String)
    case unexpectedParameter(index: Int, actionID: ActionID, name: String)
    case wrongParameterType(
        index: Int,
        actionID: ActionID,
        name: String,
        expected: ActionValueType,
        actual: ActionValueType
    )
    case actionFailed(index: Int, actionID: ActionID, message: String)

    public var description: String {
        switch self {
        case let .unknownAction(index, actionID):
            "Step \(index + 1) references unknown action '\(actionID)'."
        case let .missingParameter(index, actionID, name):
            "Step \(index + 1) action '\(actionID)' requires parameter '\(name)'."
        case let .unexpectedParameter(index, actionID, name):
            "Step \(index + 1) action '\(actionID)' does not accept parameter '\(name)'."
        case let .wrongParameterType(index, actionID, name, expected, actual):
            "Step \(index + 1) action '\(actionID)' expects '\(name)' to be \(expected.rawValue), got \(actual.rawValue)."
        case let .actionFailed(index, actionID, message):
            "Step \(index + 1) action '\(actionID)' failed: \(message)"
        }
    }
}

public struct ActionExecutor: Sendable {
    private let registry: ActionRegistry

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    public func validate(_ sequence: ActionSequence) throws {
        for (index, invocation) in sequence.steps.enumerated() {
            guard let action = registry.action(for: invocation.actionID) else {
                throw ActionExecutionError.unknownAction(index: index, actionID: invocation.actionID)
            }
            try validate(invocation.parameters, against: action.metadata, index: index)
        }
    }

    public func execute(
        _ sequence: ActionSequence,
        context: ActionContext = ActionContext()
    ) async throws -> ActionSequenceResult {
        try validate(sequence)
        var results: [ActionStepResult] = []

        for (index, invocation) in sequence.steps.enumerated() {
            try Task.checkCancellation()
            guard let action = registry.action(for: invocation.actionID) else {
                throw ActionExecutionError.unknownAction(index: index, actionID: invocation.actionID)
            }

            do {
                let result = try await action.execute(parameters: invocation.parameters, context: context)
                results.append(ActionStepResult(index: index, actionID: invocation.actionID, result: result))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ActionExecutionError.actionFailed(
                    index: index,
                    actionID: invocation.actionID,
                    message: String(describing: error)
                )
            }
        }

        return ActionSequenceResult(runID: context.runID, steps: results)
    }

    private func validate(
        _ values: ActionParameters,
        against metadata: ActionMetadata,
        index: Int
    ) throws {
        do {
            try ParameterSchema.validate(values, definitions: metadata.parameters)
        } catch let violation as ParameterSchemaViolation {
            switch violation {
            case let .missing(name):
                throw ActionExecutionError.missingParameter(index: index, actionID: metadata.id, name: name)
            case let .unexpected(name):
                throw ActionExecutionError.unexpectedParameter(index: index, actionID: metadata.id, name: name)
            case let .wrongType(name, expected, actual):
                throw ActionExecutionError.wrongParameterType(
                    index: index,
                    actionID: metadata.id,
                    name: name,
                    expected: expected,
                    actual: actual
                )
            }
        }
    }
}
