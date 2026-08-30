import Foundation

public struct StateToggle: Hashable, Codable, Sendable {
    public let providerID: StateProviderID
    public var parameters: ActionParameters
    public var expectedValue: ActionValue
    public var matchingSteps: [ScenarioStep]
    public var otherSteps: [ScenarioStep]

    public init(
        providerID: StateProviderID,
        parameters: ActionParameters,
        expectedValue: ActionValue,
        matchingSteps: [ScenarioStep],
        otherSteps: [ScenarioStep]
    ) {
        self.providerID = providerID
        self.parameters = parameters
        self.expectedValue = expectedValue
        self.matchingSteps = matchingSteps
        self.otherSteps = otherSteps
    }
}

public indirect enum ScenarioStep: Hashable, Codable, Sendable {
    case action(ActionInvocation)
    case toggle(StateToggle)
}

public struct Scenario: Hashable, Codable, Sendable {
    public let name: String
    public var steps: [ScenarioStep]

    public init(name: String, steps: [ScenarioStep]) {
        self.name = name
        self.steps = steps
    }
}

public enum ScenarioValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case action(ActionExecutionError)
    case unknownProvider(StateProviderID)
    case providerParameter(providerID: StateProviderID, violation: ParameterSchemaViolation)
    case expectedValueType(providerID: StateProviderID, expected: ActionValueType, actual: ActionValueType)
    case unsupportedExpectedValue(providerID: StateProviderID, value: ActionValue)

    public var description: String {
        switch self {
        case let .action(error):
            error.description
        case let .unknownProvider(id):
            "Unknown state provider '\(id)'."
        case let .providerParameter(providerID, violation):
            "State provider '\(providerID)' has invalid parameters: \(violation)."
        case let .expectedValueType(providerID, expected, actual):
            "State provider '\(providerID)' returns \(expected.rawValue), but toggle compares \(actual.rawValue)."
        case let .unsupportedExpectedValue(providerID, value):
            "State provider '\(providerID)' does not expose toggle value '\(value)'."
        }
    }
}

public enum ScenarioExecutionError: Error, Equatable, Sendable, CustomStringConvertible {
    case stateReadFailed(providerID: StateProviderID, message: String)

    public var description: String {
        switch self {
        case let .stateReadFailed(providerID, message):
            "State provider '\(providerID)' failed: \(message)"
        }
    }
}

public enum ScenarioExecutionEvent: Hashable, Sendable {
    case action(actionID: ActionID, result: ActionResult)
    case toggle(providerID: StateProviderID, observed: ActionValue, matched: Bool)
}

public struct ScenarioExecutionResult: Hashable, Sendable {
    public let runID: UUID
    public let events: [ScenarioExecutionEvent]
}

public struct ScenarioExecutor: Sendable {
    private let actionExecutor: ActionExecutor
    private let stateProviders: StateProviderRegistry

    public init(actions: ActionRegistry, stateProviders: StateProviderRegistry) {
        actionExecutor = ActionExecutor(registry: actions)
        self.stateProviders = stateProviders
    }

    public func validate(_ scenario: Scenario) throws {
        try validate(steps: scenario.steps)
    }

    public func execute(
        _ scenario: Scenario,
        context: ActionContext = ActionContext()
    ) async throws -> ScenarioExecutionResult {
        try validate(scenario)
        let events = try await execute(steps: scenario.steps, context: context)
        return ScenarioExecutionResult(runID: context.runID, events: events)
    }

    private func validate(steps: [ScenarioStep]) throws {
        for step in steps {
            switch step {
            case let .action(invocation):
                do {
                    try actionExecutor.validate(ActionSequence(name: "Scenario validation", steps: [invocation]))
                } catch let error as ActionExecutionError {
                    throw ScenarioValidationError.action(error)
                }
            case let .toggle(toggle):
                guard let provider = stateProviders.provider(for: toggle.providerID) else {
                    throw ScenarioValidationError.unknownProvider(toggle.providerID)
                }
                do {
                    try ParameterSchema.validate(
                        toggle.parameters,
                        definitions: provider.metadata.parameters
                    )
                } catch let violation as ParameterSchemaViolation {
                    throw ScenarioValidationError.providerParameter(
                        providerID: toggle.providerID,
                        violation: violation
                    )
                }
                guard toggle.expectedValue.type == provider.metadata.resultType else {
                    throw ScenarioValidationError.expectedValueType(
                        providerID: toggle.providerID,
                        expected: provider.metadata.resultType,
                        actual: toggle.expectedValue.type
                    )
                }
                if !provider.metadata.options.isEmpty,
                   !provider.metadata.options.contains(where: { $0.value == toggle.expectedValue }) {
                    throw ScenarioValidationError.unsupportedExpectedValue(
                        providerID: toggle.providerID,
                        value: toggle.expectedValue
                    )
                }
                try validate(steps: toggle.matchingSteps)
                try validate(steps: toggle.otherSteps)
            }
        }
    }

    private func execute(
        steps: [ScenarioStep],
        context: ActionContext
    ) async throws -> [ScenarioExecutionEvent] {
        var events: [ScenarioExecutionEvent] = []
        for step in steps {
            try Task.checkCancellation()
            switch step {
            case let .action(invocation):
                let result = try await actionExecutor.execute(
                    ActionSequence(name: "Scenario branch", steps: [invocation]),
                    context: context
                )
                if let actionResult = result.steps.first?.result {
                    events.append(.action(actionID: invocation.actionID, result: actionResult))
                }
            case let .toggle(toggle):
                guard let provider = stateProviders.provider(for: toggle.providerID) else {
                    throw ScenarioValidationError.unknownProvider(toggle.providerID)
                }
                let observed: ActionValue
                do {
                    observed = try await provider.read(parameters: toggle.parameters, context: context)
                } catch {
                    throw ScenarioExecutionError.stateReadFailed(
                        providerID: toggle.providerID,
                        message: String(describing: error)
                    )
                }
                let matched = observed == toggle.expectedValue
                events.append(.toggle(providerID: toggle.providerID, observed: observed, matched: matched))
                events.append(contentsOf: try await execute(
                    steps: matched ? toggle.matchingSteps : toggle.otherSteps,
                    context: context
                ))
            }
        }
        return events
    }
}
