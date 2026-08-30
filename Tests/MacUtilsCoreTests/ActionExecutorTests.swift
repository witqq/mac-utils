import Foundation
import MacUtilsCore
import Testing

private actor CallRecorder {
    private(set) var calls: [String] = []

    func record(_ value: String) {
        calls.append(value)
    }
}

private struct RecordingAction: UtilityAction {
    let metadata: ActionMetadata
    let recorder: CallRecorder

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        guard case let .string(value) = parameters["value"] else {
            throw TestFailure.missingValue
        }
        await recorder.record(value)
        return ActionResult(summary: value, values: ["runID": .string(context.runID.uuidString)])
    }
}

private struct FailingAction: UtilityAction {
    let metadata = ActionMetadata(
        id: ActionID("test.fail"),
        name: "Fail",
        description: "Fails predictably"
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        throw TestFailure.expected
    }
}

private enum TestFailure: Error {
    case expected
    case missingValue
}

private func recordingAction(id: String, recorder: CallRecorder) -> RecordingAction {
    RecordingAction(
        metadata: ActionMetadata(
            id: ActionID(id),
            name: "Record",
            description: "Records a typed value",
            parameters: [
                ActionParameter(name: "value", type: .string, description: "Value to record"),
            ]
        ),
        recorder: recorder
    )
}

@Test
func registryRegistersAndFindsAnAction() throws {
    let recorder = CallRecorder()
    let action = recordingAction(id: "test.record", recorder: recorder)
    var registry = ActionRegistry()

    try registry.register(action)

    #expect(registry.action(for: ActionID("test.record"))?.metadata == action.metadata)
    #expect(registry.metadata == [action.metadata])
}

@Test
func registryRejectsDuplicateIdentifiers() throws {
    let recorder = CallRecorder()
    let action = recordingAction(id: "test.record", recorder: recorder)
    var registry = ActionRegistry()
    try registry.register(action)

    #expect(throws: ActionRegistryError.duplicateAction(ActionID("test.record"))) {
        try registry.register(action)
    }
}

@Test
func customActionExecutesWithoutChangingTheExecutor() async throws {
    let recorder = CallRecorder()
    var registry = ActionRegistry()
    try registry.register(recordingAction(id: "custom.added", recorder: recorder))
    let executor = ActionExecutor(registry: registry)
    let runID = UUID()

    let result = try await executor.execute(
        ActionSequence(
            name: "Single custom action",
            steps: [
                ActionInvocation(actionID: ActionID("custom.added"), parameters: ["value": .string("one")]),
            ]
        ),
        context: ActionContext(runID: runID)
    )

    #expect(await recorder.calls == ["one"])
    #expect(result.runID == runID)
    #expect(result.steps.map(\.result.summary) == ["one"])
}

@Test
func sequenceExecutesActionsInOrderWithTypedParameters() async throws {
    let recorder = CallRecorder()
    var registry = ActionRegistry()
    try registry.register(recordingAction(id: "test.first", recorder: recorder))
    try registry.register(recordingAction(id: "test.second", recorder: recorder))
    let executor = ActionExecutor(registry: registry)

    let result = try await executor.execute(
        ActionSequence(
            name: "Ordered",
            steps: [
                ActionInvocation(actionID: ActionID("test.first"), parameters: ["value": .string("first")]),
                ActionInvocation(actionID: ActionID("test.second"), parameters: ["value": .string("second")]),
            ]
        )
    )

    #expect(await recorder.calls == ["first", "second"])
    #expect(result.steps.map(\.index) == [0, 1])
}

@Test
func sequenceStopsAfterAnActionFails() async throws {
    let recorder = CallRecorder()
    var registry = ActionRegistry()
    try registry.register(recordingAction(id: "test.record", recorder: recorder))
    try registry.register(FailingAction())
    let executor = ActionExecutor(registry: registry)
    let sequence = ActionSequence(
        name: "Stops",
        steps: [
            ActionInvocation(actionID: ActionID("test.record"), parameters: ["value": .string("before")]),
            ActionInvocation(actionID: ActionID("test.fail")),
            ActionInvocation(actionID: ActionID("test.record"), parameters: ["value": .string("after")]),
        ]
    )

    do {
        _ = try await executor.execute(sequence)
        Issue.record("Expected the failing action to stop the sequence")
    } catch let error as ActionExecutionError {
        #expect(error == .actionFailed(index: 1, actionID: ActionID("test.fail"), message: "expected"))
    }

    #expect(await recorder.calls == ["before"])
}

@Test
func validationRejectsMissingUnexpectedAndWronglyTypedParameters() throws {
    let recorder = CallRecorder()
    var registry = ActionRegistry()
    try registry.register(recordingAction(id: "test.record", recorder: recorder))
    let executor = ActionExecutor(registry: registry)

    #expect(throws: ActionExecutionError.missingParameter(
        index: 0,
        actionID: ActionID("test.record"),
        name: "value"
    )) {
        try executor.validate(ActionSequence(name: "Missing", steps: [
            ActionInvocation(actionID: ActionID("test.record")),
        ]))
    }

    #expect(throws: ActionExecutionError.unexpectedParameter(
        index: 0,
        actionID: ActionID("test.record"),
        name: "extra"
    )) {
        try executor.validate(ActionSequence(name: "Extra", steps: [
            ActionInvocation(
                actionID: ActionID("test.record"),
                parameters: ["value": .string("ok"), "extra": .boolean(true)]
            ),
        ]))
    }

    #expect(throws: ActionExecutionError.wrongParameterType(
        index: 0,
        actionID: ActionID("test.record"),
        name: "value",
        expected: .string,
        actual: .integer
    )) {
        try executor.validate(ActionSequence(name: "Wrong type", steps: [
            ActionInvocation(actionID: ActionID("test.record"), parameters: ["value": .integer(3)]),
        ]))
    }
}
