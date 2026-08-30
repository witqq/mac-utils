import MacUtilsCore
import Testing

private struct BuilderAction: UtilityAction {
    let metadata = ActionMetadata(
        id: ActionID("test.configure"),
        name: "Configure",
        description: "Tests every builder parameter editor",
        parameters: [
            ActionParameter(name: "name", type: .string, description: "Name"),
            ActionParameter(name: "count", type: .integer, description: "Count"),
            ActionParameter(name: "ratio", type: .number, description: "Ratio"),
            ActionParameter(name: "enabled", type: .boolean, description: "Enabled"),
        ]
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        ActionResult(summary: "configured")
    }
}

private struct BuilderDisplayAction: UtilityAction {
    let metadata = ActionMetadata(
        id: ActionID("test.display"),
        name: "Display",
        description: "Tests display choices",
        parameters: [
            ActionParameter(name: "display", type: .string, description: "Display"),
            ActionParameter(name: "source", type: .string, description: "Source"),
        ]
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        ActionResult(summary: "display")
    }
}

private func builderFixture() throws -> ActionSequenceBuilder {
    var registry = ActionRegistry()
    try registry.register(BuilderAction())
    try registry.register(BuilderDisplayAction())
    return ActionSequenceBuilder(registry: registry)
}

@Test
func buildsTypedOneAndMultiStepSequencesWithoutText() throws {
    var builder = try builderFixture()
    let first = try builder.add(actionID: ActionID("test.configure"))
    try builder.setParameter(stepID: first, name: "name", value: .string("Desk"))
    try builder.setParameter(stepID: first, name: "count", value: .integer(2))
    try builder.setParameter(stepID: first, name: "ratio", value: .number(1.5))
    try builder.setParameter(stepID: first, name: "enabled", value: .boolean(true))
    let second = try builder.add(actionID: ActionID("test.display"))
    try builder.setParameter(stepID: second, name: "display", value: .string("right-uuid"))
    try builder.setParameter(stepID: second, name: "source", value: .string("main-uuid"))

    let sequence = builder.sequence(name: "Desk")

    #expect(sequence.steps.count == 2)
    #expect(sequence.steps[0].parameters["count"] == .integer(2))
    #expect(sequence.steps[1].parameters == [
        "display": .string("right-uuid"),
        "source": .string("main-uuid"),
    ])
}

@Test
func reordersDuplicatesAndRemovesSteps() throws {
    var builder = try builderFixture()
    let configure = try builder.add(actionID: ActionID("test.configure"))
    let display = try builder.add(actionID: ActionID("test.display"))
    let duplicate = try builder.duplicate(stepID: display)

    try builder.move(stepID: duplicate, to: 0)
    try builder.remove(stepID: display)

    #expect(builder.steps.map(\.id) == [duplicate, configure])
}

@Test
func canonicalDSLHasAnExactTypedRoundTrip() throws {
    var builder = try builderFixture()
    let step = try builder.add(actionID: ActionID("test.configure"))
    try builder.setParameter(stepID: step, name: "name", value: .string("Desk \"A\"\nLine"))
    try builder.setParameter(stepID: step, name: "count", value: .integer(3))
    try builder.setParameter(stepID: step, name: "ratio", value: .number(2.25))
    try builder.setParameter(stepID: step, name: "enabled", value: .boolean(false))
    let canonical = builder.canonicalDSL()
    var restored = try builderFixture()

    try restored.replace(withDSL: canonical)

    #expect(restored.canonicalDSL() == canonical)
    #expect(restored.steps[0].parameters == builder.steps[0].parameters)
}

@Test
func invalidTextDoesNotMutateTheVisualModel() throws {
    var builder = try builderFixture()
    _ = try builder.add(actionID: ActionID("test.display"))
    let original = builder.steps

    #expect(throws: ScriptDiagnostic.self) {
        try builder.replace(withDSL: "test.configure count=\"not-an-integer\"")
    }

    #expect(builder.steps == original)
}

@Test
func rejectsWrongTypesSetByAVisualEditor() throws {
    var builder = try builderFixture()
    let step = try builder.add(actionID: ActionID("test.configure"))

    #expect(throws: ActionSequenceBuilderError.wrongParameterType(
        name: "count",
        expected: .integer,
        actual: .string
    )) {
        try builder.setParameter(stepID: step, name: "count", value: .string("2"))
    }
}
