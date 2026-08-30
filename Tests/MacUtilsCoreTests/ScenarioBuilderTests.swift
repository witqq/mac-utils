import MacUtilsCore
import Testing

private struct VisualAction: UtilityAction {
    let metadata: ActionMetadata

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        ActionResult(summary: metadata.name)
    }
}

private struct VisualProvider: StateProvider {
    let metadata = StateProviderMetadata(
        id: StateProviderID("visual.mode"),
        name: "Visual Mode",
        description: "Builder state",
        parameters: [ActionParameter(name: "display", type: .string, description: "Display")],
        resultType: .string,
        options: [
            StateOption(value: .string("mirror"), label: "Mirror"),
            StateOption(value: .string("extended"), label: "Extended"),
        ]
    )

    func read(parameters: ActionParameters, context: ActionContext) async throws -> ActionValue {
        .string("mirror")
    }
}

private let visualExtendID = ActionID("visual.extend")
private let visualMirrorID = ActionID("visual.mirror")
private let visualProviderID = StateProviderID("visual.mode")

private func scenarioBuilderFixture() throws -> ScenarioBuilder {
    var actions = ActionRegistry()
    try actions.register(VisualAction(metadata: ActionMetadata(
        id: visualExtendID,
        name: "Extend",
        description: "Extend display",
        parameters: [ActionParameter(name: "display", type: .string, description: "Display")]
    )))
    try actions.register(VisualAction(metadata: ActionMetadata(
        id: visualMirrorID,
        name: "Mirror",
        description: "Mirror display",
        parameters: [
            ActionParameter(name: "display", type: .string, description: "Display"),
            ActionParameter(name: "source", type: .string, description: "Source"),
        ]
    )))
    var providers = StateProviderRegistry()
    try providers.register(VisualProvider())
    return ScenarioBuilder(actions: actions, stateProviders: providers)
}

@Test
func buildsUniversalToggleAndBothBranchesWithoutText() throws {
    var builder = try scenarioBuilderFixture()
    let toggleID = try builder.addToggle(visualProviderID, to: .root)
    try builder.setToggleParameter(
        stepID: toggleID,
        name: "display",
        value: .string("target-uuid")
    )
    try builder.setExpectedValue(stepID: toggleID, value: .string("mirror"))
    let extendID = try builder.addAction(visualExtendID, to: .matching(toggleID: toggleID))
    try builder.setActionParameter(stepID: extendID, name: "display", value: .string("target-uuid"))
    let mirrorID = try builder.addAction(visualMirrorID, to: .otherwise(toggleID: toggleID))
    try builder.setActionParameter(stepID: mirrorID, name: "display", value: .string("target-uuid"))
    try builder.setActionParameter(stepID: mirrorID, name: "source", value: .string("source-uuid"))

    let scenario = builder.scenario(name: "Mouse toggle")

    guard case let .toggle(toggle) = scenario.steps.first else {
        Issue.record("Expected toggle root step")
        return
    }
    #expect(toggle.parameters["display"] == .string("target-uuid"))
    #expect(toggle.matchingSteps.count == 1)
    #expect(toggle.otherSteps.count == 1)
}

@Test
func nestedBranchesSupportOrderDuplicateAndDelete() throws {
    var builder = try scenarioBuilderFixture()
    let toggleID = try builder.addToggle(visualProviderID, to: .root)
    let first = try builder.addAction(visualExtendID, to: .matching(toggleID: toggleID))
    let second = try builder.addAction(visualMirrorID, to: .matching(toggleID: toggleID))
    let duplicate = try builder.duplicate(stepID: second, in: .matching(toggleID: toggleID))

    try builder.move(
        stepID: duplicate,
        to: 0,
        in: .matching(toggleID: toggleID)
    )
    try builder.remove(stepID: second, from: .matching(toggleID: toggleID))

    #expect(try builder.steps(in: .matching(toggleID: toggleID)).map(\.id) == [duplicate, first])
}

@Test
func structuredBuilderDSLHasExactRoundTrip() throws {
    var builder = try scenarioBuilderFixture()
    let toggleID = try builder.addToggle(visualProviderID, to: .root)
    try builder.setToggleParameter(stepID: toggleID, name: "display", value: .string("target"))
    let actionID = try builder.addAction(visualExtendID, to: .matching(toggleID: toggleID))
    try builder.setActionParameter(stepID: actionID, name: "display", value: .string("target"))
    let canonical = builder.canonicalDSL()
    var restored = try scenarioBuilderFixture()

    try restored.replace(withDSL: canonical)

    #expect(restored.canonicalDSL() == canonical)
    #expect(restored.scenario(name: "Scenario") == builder.scenario(name: "Scenario"))
}

@Test
func invalidNestedTextDoesNotReplaceVisualTree() throws {
    var builder = try scenarioBuilderFixture()
    _ = try builder.addAction(visualExtendID, to: .root)
    let original = builder.rootSteps

    #expect(throws: ScriptDiagnostic.self) {
        try builder.replace(withDSL: "@toggle provider=\"visual.mode\" equals=\"mirror\"")
    }

    #expect(builder.rootSteps == original)
}
