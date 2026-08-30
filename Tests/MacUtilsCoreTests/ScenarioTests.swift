import MacUtilsCore
import Testing

private actor StateBox {
    var value: ActionValue
    private(set) var reads = 0

    init(_ value: ActionValue) { self.value = value }

    func read() -> ActionValue {
        reads += 1
        return value
    }
}

private struct TestStateProvider: StateProvider {
    let metadata: StateProviderMetadata
    let box: StateBox

    func read(parameters: ActionParameters, context: ActionContext) async throws -> ActionValue {
        await box.read()
    }
}

private actor ScenarioRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private struct ScenarioRecordingAction: UtilityAction {
    let metadata = ActionMetadata(
        id: ActionID("test.record-scenario"),
        name: "Record",
        description: "Records a scenario branch",
        parameters: [ActionParameter(name: "value", type: .string, description: "Value")]
    )
    let recorder: ScenarioRecorder

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        guard case let .string(value) = parameters["value"] else { throw ScenarioTestError.noValue }
        await recorder.append(value)
        return ActionResult(summary: value)
    }
}

private enum ScenarioTestError: Error { case noValue }

private let testStateID = StateProviderID("test.state")

private func scenarioFixture(
    state: ActionValue = .string("on")
) throws -> (ActionRegistry, StateProviderRegistry, StateBox, ScenarioRecorder) {
    let box = StateBox(state)
    let recorder = ScenarioRecorder()
    var actions = ActionRegistry()
    try actions.register(ScenarioRecordingAction(recorder: recorder))
    var providers = StateProviderRegistry()
    try providers.register(TestStateProvider(
        metadata: StateProviderMetadata(
            id: testStateID,
            name: "Test State",
            description: "A provider added without changing the toggle executor",
            resultType: .string,
            options: [
                StateOption(value: .string("on"), label: "On"),
                StateOption(value: .string("off"), label: "Off"),
            ]
        ),
        box: box
    ))
    return (actions, providers, box, recorder)
}

private func record(_ value: String) -> ScenarioStep {
    .action(ActionInvocation(
        actionID: ActionID("test.record-scenario"),
        parameters: ["value": .string(value)]
    ))
}

private func toggleScenario() -> Scenario {
    Scenario(
        name: "Toggle",
        steps: [
            .toggle(StateToggle(
                providerID: testStateID,
                parameters: [:],
                expectedValue: .string("on"),
                matchingSteps: [record("match-1"), record("match-2")],
                otherSteps: [record("otherwise")]
            )),
        ]
    )
}

@Test
func registeredProviderChoosesMatchingBranchAndRunsAllItsActions() async throws {
    let (actions, providers, box, recorder) = try scenarioFixture()
    let result = try await ScenarioExecutor(actions: actions, stateProviders: providers)
        .execute(toggleScenario())

    #expect(await box.reads == 1)
    #expect(await recorder.values == ["match-1", "match-2"])
    #expect(result.events.first == .toggle(
        providerID: testStateID,
        observed: .string("on"),
        matched: true
    ))
}

@Test
func providerActualValueChoosesOtherwiseBranch() async throws {
    let (actions, providers, _, recorder) = try scenarioFixture(state: .string("off"))

    _ = try await ScenarioExecutor(actions: actions, stateProviders: providers)
        .execute(toggleScenario())

    #expect(await recorder.values == ["otherwise"])
}

@Test
func invalidUnchosenBranchPreventsStateReadAndAllActions() async throws {
    let (actions, providers, box, recorder) = try scenarioFixture()
    let invalid = Scenario(
        name: "Invalid",
        steps: [
            .toggle(StateToggle(
                providerID: testStateID,
                parameters: [:],
                expectedValue: .string("on"),
                matchingSteps: [record("would-run")],
                otherSteps: [.action(ActionInvocation(actionID: ActionID("missing.action")))]
            )),
        ]
    )

    await #expect(throws: ScenarioValidationError.self) {
        try await ScenarioExecutor(actions: actions, stateProviders: providers).execute(invalid)
    }

    #expect(await box.reads == 0)
    #expect(await recorder.values.isEmpty)
}

@Test
func structuredDSLHasExactNestedRoundTrip() throws {
    let (actions, providers, _, _) = try scenarioFixture()
    let engine = ScenarioScriptEngine(actions: actions, stateProviders: providers)
    let serialized = engine.serialize(toggleScenario())

    let restored = try engine.compile(serialized, name: "Toggle")

    #expect(restored == toggleScenario())
    #expect(engine.serialize(restored) == serialized)
}
