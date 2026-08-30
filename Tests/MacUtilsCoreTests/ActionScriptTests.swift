import MacUtilsCore
import Testing

private actor ScriptRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private struct ScriptRecordingAction: UtilityAction {
    let recorder: ScriptRecorder
    let metadata = ActionMetadata(
        id: ActionID("test.record"),
        name: "Record",
        description: "Records a value",
        parameters: [
            ActionParameter(name: "value", type: .string, description: "Value"),
        ]
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        guard case let .string(value) = parameters["value"] else {
            throw ScriptTestError.noValue
        }
        await recorder.append(value)
        return ActionResult(summary: value)
    }
}

private enum ScriptTestError: Error {
    case noValue
}

private func scriptEngine(recorder: ScriptRecorder) throws -> ActionScriptEngine {
    var registry = ActionRegistry()
    try registry.register(ScriptRecordingAction(recorder: recorder))
    return ActionScriptEngine(registry: registry)
}

@Test
func executesOneCommandWithANamedQuotedValue() async throws {
    let recorder = ScriptRecorder()
    let engine = try scriptEngine(recorder: recorder)

    let result = try await engine.execute(#"test.record value="hello world""#)

    #expect(result.steps.map(\.result.summary) == ["hello world"])
    #expect(await recorder.values == ["hello world"])
}

@Test
func executesMultipleLinesAndIgnoresBlankLinesAndComments() async throws {
    let recorder = ScriptRecorder()
    let engine = try scriptEngine(recorder: recorder)
    let source = """
    # Display profile

    test.record value="first"
    test.record value="second\\nline" # inline comment
    """

    _ = try await engine.execute(source)

    #expect(await recorder.values == ["first", "second\nline"])
}

@Test
func unknownCommandReportsItsSourceLine() throws {
    let recorder = ScriptRecorder()
    let engine = try scriptEngine(recorder: recorder)

    #expect(throws: ScriptDiagnostic(
        line: 2,
        column: 1,
        message: "Step 1 references unknown action 'unknown.action'."
    )) {
        try engine.compile("# comment\nunknown.action value=\"x\"")
    }
}

@Test
func missingAndUnexpectedParametersReportTheirLines() throws {
    let recorder = ScriptRecorder()
    let engine = try scriptEngine(recorder: recorder)

    #expect(throws: ScriptDiagnostic(
        line: 1,
        column: 1,
        message: "Step 1 action 'test.record' requires parameter 'value'."
    )) {
        try engine.compile("test.record")
    }

    #expect(throws: ScriptDiagnostic(
        line: 2,
        column: 1,
        message: "Step 2 action 'test.record' does not accept parameter 'extra'."
    )) {
        try engine.compile("test.record value=\"ok\"\ntest.record value=\"x\" extra=\"y\"")
    }
}

@Test
func syntaxErrorIncludesExactLineAndColumn() throws {
    let parser = ActionScriptParser()

    #expect(throws: ScriptDiagnostic(
        line: 3,
        column: 24,
        message: "Unterminated quoted string."
    )) {
        try parser.parse("# first\n\ntest.record value=\"open")
    }
}

@Test
func fullPrevalidationPreventsEarlierCommandsFromRunning() async throws {
    let recorder = ScriptRecorder()
    let engine = try scriptEngine(recorder: recorder)
    let source = """
    test.record value="must not run"
    test.record extra="invalid"
    """

    await #expect(throws: ScriptDiagnostic.self) {
        try await engine.execute(source)
    }

    #expect(await recorder.values.isEmpty)
}

@Test
func arbitraryRuntimeNamesHaveNoExecutionPath() throws {
    let recorder = ScriptRecorder()
    let engine = try scriptEngine(recorder: recorder)

    #expect(throws: ScriptDiagnostic.self) {
        try engine.compile("shell command=\"rm -rf something\"")
    }
}
