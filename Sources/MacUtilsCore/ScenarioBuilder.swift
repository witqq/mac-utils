import Foundation

public struct ToggleBuilderStep: Hashable, Identifiable, Sendable {
    public let id: UUID
    public let providerID: StateProviderID
    public var parameters: ActionParameters
    public var expectedValue: ActionValue
    public var matchingSteps: [ScenarioBuilderStep]
    public var otherSteps: [ScenarioBuilderStep]

    public init(
        id: UUID = UUID(),
        providerID: StateProviderID,
        parameters: ActionParameters,
        expectedValue: ActionValue,
        matchingSteps: [ScenarioBuilderStep] = [],
        otherSteps: [ScenarioBuilderStep] = []
    ) {
        self.id = id
        self.providerID = providerID
        self.parameters = parameters
        self.expectedValue = expectedValue
        self.matchingSteps = matchingSteps
        self.otherSteps = otherSteps
    }
}

public indirect enum ScenarioBuilderStep: Hashable, Identifiable, Sendable {
    case action(ActionBuilderStep)
    case toggle(ToggleBuilderStep)

    public var id: UUID {
        switch self {
        case let .action(step): step.id
        case let .toggle(step): step.id
        }
    }
}

public enum ScenarioBuilderLocation: Hashable, Sendable {
    case root
    case matching(toggleID: UUID)
    case otherwise(toggleID: UUID)
}

public enum ScenarioBuilderError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownAction(ActionID)
    case unknownProvider(StateProviderID)
    case stepNotFound(UUID)
    case locationNotFound(ScenarioBuilderLocation)
    case expectedAction(UUID)
    case expectedToggle(UUID)
    case parameterNotFound(String)
    case wrongParameterType(name: String, expected: ActionValueType, actual: ActionValueType)
    case invalidExpectedValue(ActionValue)

    public var description: String {
        switch self {
        case let .unknownAction(id): "Action '\(id)' is not available."
        case let .unknownProvider(id): "State provider '\(id)' is not available."
        case let .stepNotFound(id): "Builder step '\(id)' does not exist."
        case let .locationNotFound(location): "Builder branch '\(location)' does not exist."
        case let .expectedAction(id): "Builder step '\(id)' is not an action."
        case let .expectedToggle(id): "Builder step '\(id)' is not a toggle."
        case let .parameterNotFound(name): "Parameter '\(name)' does not exist."
        case let .wrongParameterType(name, expected, actual):
            "Parameter '\(name)' expects \(expected.rawValue), got \(actual.rawValue)."
        case let .invalidExpectedValue(value): "Toggle cannot compare provider state with '\(value)'."
        }
    }
}

public struct ScenarioBuilder: Sendable {
    public let actionCatalog: [ActionMetadata]
    public let stateProviderCatalog: [StateProviderMetadata]
    public private(set) var rootSteps: [ScenarioBuilderStep]

    private let actions: ActionRegistry
    private let stateProviders: StateProviderRegistry
    private let scriptEngine: ScenarioScriptEngine

    public init(
        actions: ActionRegistry,
        stateProviders: StateProviderRegistry,
        rootSteps: [ScenarioBuilderStep] = []
    ) {
        self.actions = actions
        self.stateProviders = stateProviders
        scriptEngine = ScenarioScriptEngine(actions: actions, stateProviders: stateProviders)
        actionCatalog = actions.metadata
        stateProviderCatalog = stateProviders.metadata
        self.rootSteps = rootSteps
    }

    public func steps(in location: ScenarioBuilderLocation) throws -> [ScenarioBuilderStep] {
        switch location {
        case .root:
            rootSteps
        case let .matching(toggleID):
            try toggle(id: toggleID).matchingSteps
        case let .otherwise(toggleID):
            try toggle(id: toggleID).otherSteps
        }
    }

    public func step(id: UUID) throws -> ScenarioBuilderStep {
        guard let step = Self.find(id: id, in: rootSteps) else {
            throw ScenarioBuilderError.stepNotFound(id)
        }
        return step
    }

    public func actionMetadata(for id: ActionID) -> ActionMetadata? {
        actions.action(for: id)?.metadata
    }

    public func providerMetadata(for id: StateProviderID) -> StateProviderMetadata? {
        stateProviders.provider(for: id)?.metadata
    }

    @discardableResult
    public mutating func addAction(
        _ actionID: ActionID,
        to location: ScenarioBuilderLocation
    ) throws -> UUID {
        guard let metadata = actions.action(for: actionID)?.metadata else {
            throw ScenarioBuilderError.unknownAction(actionID)
        }
        let step = ActionBuilderStep(
            actionID: actionID,
            parameters: ParameterSchema.defaults(for: metadata.parameters)
        )
        try mutate(location: location) { $0.append(.action(step)) }
        return step.id
    }

    @discardableResult
    public mutating func addToggle(
        _ providerID: StateProviderID,
        to location: ScenarioBuilderLocation
    ) throws -> UUID {
        guard let metadata = stateProviders.provider(for: providerID)?.metadata else {
            throw ScenarioBuilderError.unknownProvider(providerID)
        }
        let expectedValue = metadata.options.first?.value ?? defaultValue(for: metadata.resultType)
        let step = ToggleBuilderStep(
            providerID: providerID,
            parameters: ParameterSchema.defaults(for: metadata.parameters),
            expectedValue: expectedValue
        )
        try mutate(location: location) { $0.append(.toggle(step)) }
        return step.id
    }

    public mutating func setActionParameter(
        stepID: UUID,
        name: String,
        value: ActionValue?
    ) throws {
        guard case let .action(step) = try self.step(id: stepID) else {
            throw ScenarioBuilderError.expectedAction(stepID)
        }
        guard let definition = actions.action(for: step.actionID)?.metadata.parameters
            .first(where: { $0.name == name }) else {
            throw ScenarioBuilderError.parameterNotFound(name)
        }
        try validate(value: value, definition: definition)
        try replace(id: stepID) { node in
            guard case var .action(updated) = node else { return node }
            updated.parameters[name] = value
            return .action(updated)
        }
    }

    public mutating func setToggleParameter(
        stepID: UUID,
        name: String,
        value: ActionValue?
    ) throws {
        let current = try toggle(id: stepID)
        guard let definition = stateProviders.provider(for: current.providerID)?.metadata.parameters
            .first(where: { $0.name == name }) else {
            throw ScenarioBuilderError.parameterNotFound(name)
        }
        try validate(value: value, definition: definition)
        try replace(id: stepID) { node in
            guard case var .toggle(updated) = node else { return node }
            updated.parameters[name] = value
            return .toggle(updated)
        }
    }

    public mutating func setExpectedValue(stepID: UUID, value: ActionValue) throws {
        let current = try toggle(id: stepID)
        guard let metadata = stateProviders.provider(for: current.providerID)?.metadata,
              value.type == metadata.resultType,
              metadata.options.isEmpty || metadata.options.contains(where: { $0.value == value }) else {
            throw ScenarioBuilderError.invalidExpectedValue(value)
        }
        try replace(id: stepID) { node in
            guard case var .toggle(updated) = node else { return node }
            updated.expectedValue = value
            return .toggle(updated)
        }
    }

    @discardableResult
    public mutating func duplicate(
        stepID: UUID,
        in location: ScenarioBuilderLocation
    ) throws -> UUID {
        let source = try step(id: stepID)
        let copy = Self.clone(source)
        try mutate(location: location) { steps in
            guard let index = steps.firstIndex(where: { $0.id == stepID }) else { return }
            steps.insert(copy, at: index + 1)
        }
        return copy.id
    }

    public mutating func remove(stepID: UUID, from location: ScenarioBuilderLocation) throws {
        var found = false
        try mutate(location: location) { steps in
            if let index = steps.firstIndex(where: { $0.id == stepID }) {
                steps.remove(at: index)
                found = true
            }
        }
        if !found { throw ScenarioBuilderError.stepNotFound(stepID) }
    }

    public mutating func move(
        fromOffsets: IndexSet,
        toOffset: Int,
        in location: ScenarioBuilderLocation
    ) throws {
        try mutate(location: location) { steps in
            let moving = fromOffsets.sorted().map { steps[$0] }
            for index in fromOffsets.sorted(by: >) { steps.remove(at: index) }
            let removedBefore = fromOffsets.filter { $0 < toOffset }.count
            let insertion = min(max(0, toOffset - removedBefore), steps.count)
            steps.insert(contentsOf: moving, at: insertion)
        }
    }

    public mutating func move(
        stepID: UUID,
        to destination: Int,
        in location: ScenarioBuilderLocation
    ) throws {
        var moved = false
        try mutate(location: location) { steps in
            guard let source = steps.firstIndex(where: { $0.id == stepID }),
                  (0..<steps.count).contains(destination) else { return }
            let step = steps.remove(at: source)
            steps.insert(step, at: destination)
            moved = true
        }
        if !moved { throw ScenarioBuilderError.stepNotFound(stepID) }
    }

    public func scenario(name: String) -> Scenario {
        Scenario(name: name, steps: rootSteps.map(Self.scenarioStep))
    }

    public func canonicalDSL(name: String = "Scenario") -> String {
        scriptEngine.serialize(scenario(name: name))
    }

    public mutating func replace(withDSL source: String, name: String = "Scenario") throws {
        let compiled = try scriptEngine.compile(source, name: name)
        rootSteps = compiled.steps.map(Self.builderStep)
    }

    private func toggle(id: UUID) throws -> ToggleBuilderStep {
        guard case let .toggle(toggle) = try step(id: id) else {
            throw ScenarioBuilderError.expectedToggle(id)
        }
        return toggle
    }

    private mutating func mutate(
        location: ScenarioBuilderLocation,
        _ operation: (inout [ScenarioBuilderStep]) -> Void
    ) throws {
        switch location {
        case .root:
            operation(&rootSteps)
        case let .matching(toggleID):
            guard Self.mutateToggle(id: toggleID, in: &rootSteps, branch: .matching, operation) else {
                throw ScenarioBuilderError.locationNotFound(location)
            }
        case let .otherwise(toggleID):
            guard Self.mutateToggle(id: toggleID, in: &rootSteps, branch: .otherwise, operation) else {
                throw ScenarioBuilderError.locationNotFound(location)
            }
        }
    }

    private mutating func replace(
        id: UUID,
        transform: (ScenarioBuilderStep) -> ScenarioBuilderStep
    ) throws {
        guard Self.replace(id: id, in: &rootSteps, transform: transform) else {
            throw ScenarioBuilderError.stepNotFound(id)
        }
    }

    private func validate(value: ActionValue?, definition: ActionParameter) throws {
        guard let value else { return }
        guard value.type == definition.type else {
            throw ScenarioBuilderError.wrongParameterType(
                name: definition.name,
                expected: definition.type,
                actual: value.type
            )
        }
    }

    private func defaultValue(for type: ActionValueType) -> ActionValue {
        switch type {
        case .string: .string("")
        case .integer: .integer(0)
        case .number: .number(0)
        case .boolean: .boolean(false)
        }
    }

    private enum Branch { case matching, otherwise }

    private static func mutateToggle(
        id: UUID,
        in steps: inout [ScenarioBuilderStep],
        branch: Branch,
        _ operation: (inout [ScenarioBuilderStep]) -> Void
    ) -> Bool {
        for index in steps.indices {
            guard case var .toggle(toggle) = steps[index] else { continue }
            if toggle.id == id {
                switch branch {
                case .matching: operation(&toggle.matchingSteps)
                case .otherwise: operation(&toggle.otherSteps)
                }
                steps[index] = .toggle(toggle)
                return true
            }
            if mutateToggle(id: id, in: &toggle.matchingSteps, branch: branch, operation)
                || mutateToggle(id: id, in: &toggle.otherSteps, branch: branch, operation) {
                steps[index] = .toggle(toggle)
                return true
            }
        }
        return false
    }

    private static func replace(
        id: UUID,
        in steps: inout [ScenarioBuilderStep],
        transform: (ScenarioBuilderStep) -> ScenarioBuilderStep
    ) -> Bool {
        for index in steps.indices {
            if steps[index].id == id {
                steps[index] = transform(steps[index])
                return true
            }
            guard case var .toggle(toggle) = steps[index] else { continue }
            if replace(id: id, in: &toggle.matchingSteps, transform: transform)
                || replace(id: id, in: &toggle.otherSteps, transform: transform) {
                steps[index] = .toggle(toggle)
                return true
            }
        }
        return false
    }

    private static func find(id: UUID, in steps: [ScenarioBuilderStep]) -> ScenarioBuilderStep? {
        for step in steps {
            if step.id == id { return step }
            if case let .toggle(toggle) = step {
                if let found = find(id: id, in: toggle.matchingSteps) ?? find(id: id, in: toggle.otherSteps) {
                    return found
                }
            }
        }
        return nil
    }

    private static func clone(_ step: ScenarioBuilderStep) -> ScenarioBuilderStep {
        switch step {
        case let .action(action):
            .action(ActionBuilderStep(actionID: action.actionID, parameters: action.parameters))
        case let .toggle(toggle):
            .toggle(ToggleBuilderStep(
                providerID: toggle.providerID,
                parameters: toggle.parameters,
                expectedValue: toggle.expectedValue,
                matchingSteps: toggle.matchingSteps.map(clone),
                otherSteps: toggle.otherSteps.map(clone)
            ))
        }
    }

    private static func scenarioStep(_ step: ScenarioBuilderStep) -> ScenarioStep {
        switch step {
        case let .action(action):
            .action(ActionInvocation(actionID: action.actionID, parameters: action.parameters))
        case let .toggle(toggle):
            .toggle(StateToggle(
                providerID: toggle.providerID,
                parameters: toggle.parameters,
                expectedValue: toggle.expectedValue,
                matchingSteps: toggle.matchingSteps.map(scenarioStep),
                otherSteps: toggle.otherSteps.map(scenarioStep)
            ))
        }
    }

    private static func builderStep(_ step: ScenarioStep) -> ScenarioBuilderStep {
        switch step {
        case let .action(action):
            .action(ActionBuilderStep(actionID: action.actionID, parameters: action.parameters))
        case let .toggle(toggle):
            .toggle(ToggleBuilderStep(
                providerID: toggle.providerID,
                parameters: toggle.parameters,
                expectedValue: toggle.expectedValue,
                matchingSteps: toggle.matchingSteps.map(builderStep),
                otherSteps: toggle.otherSteps.map(builderStep)
            ))
        }
    }
}
