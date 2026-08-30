import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private actor FakeHotKeyRegistrar: GlobalHotKeyRegistering {
    private var nextToken: UInt32 = 1
    private var handlers: [HotKeyRegistrationToken: @Sendable () async -> Void] = [:]
    private(set) var shortcuts: [HotKeyRegistrationToken: GlobalShortcut] = [:]
    var unavailable: Set<GlobalShortcut> = []

    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @Sendable () async -> Void
    ) async throws -> HotKeyRegistrationToken {
        if unavailable.contains(shortcut) {
            throw GlobalHotKeyError.unavailable(shortcut, status: -9878)
        }
        let token = HotKeyRegistrationToken(rawValue: nextToken)
        nextToken += 1
        shortcuts[token] = shortcut
        handlers[token] = handler
        return token
    }

    func unregister(_ token: HotKeyRegistrationToken) async {
        shortcuts[token] = nil
        handlers[token] = nil
    }

    func makeUnavailable(_ shortcut: GlobalShortcut) {
        unavailable.insert(shortcut)
    }

    func trigger(_ shortcut: GlobalShortcut) async {
        guard let token = shortcuts.first(where: { $0.value == shortcut })?.key,
              let handler = handlers[token] else { return }
        await handler()
    }
}

private actor HotKeyRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private struct HotKeyRecordingAction: UtilityAction {
    let recorder: HotKeyRecorder
    let metadata = ActionMetadata(
        id: ActionID("test.record-hotkey"),
        name: "Record hotkey",
        description: "Records a hotkey execution",
        parameters: [ActionParameter(name: "value", type: .string, description: "Value")]
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        guard case let .string(value) = parameters["value"] else {
            throw ShortcutTestError.noValue
        }
        await recorder.append(value)
        return ActionResult(summary: value)
    }
}

private enum ShortcutTestError: Error {
    case noValue
}

private let shortcutA = GlobalShortcut(keyCode: 79, modifiers: [.command, .option, .control, .shift])
private let shortcutB = GlobalShortcut(keyCode: 80, modifiers: [.command, .option, .control, .shift])

private func coordinatorFixture() throws -> (
    ShortcutCoordinator,
    FakeHotKeyRegistrar,
    HotKeyRecorder,
    UserScript
) {
    let registrar = FakeHotKeyRegistrar()
    let recorder = HotKeyRecorder()
    var registry = ActionRegistry()
    try registry.register(HotKeyRecordingAction(recorder: recorder))
    let script = UserScript(name: "Hotkey", source: "test.record-hotkey value=\"fired\"")
    return (ShortcutCoordinator(registrar: registrar, registry: registry), registrar, recorder, script)
}

@Test
func registersTriggersReplacesAndRemovesABinding() async throws {
    let (coordinator, registrar, recorder, script) = try coordinatorFixture()
    try await coordinator.upsertScript(script)
    var binding = ShortcutBinding(shortcut: shortcutA, scriptID: script.id)

    try await coordinator.register(binding)
    await registrar.trigger(shortcutA)
    #expect(await recorder.values == ["fired"])
    #expect(await coordinator.lastExecution == ShortcutExecutionEvent(
        bindingID: binding.id,
        status: .succeeded(stepCount: 1)
    ))

    binding.shortcut = shortcutB
    try await coordinator.register(binding)
    #expect(await registrar.shortcuts.count == 1)
    #expect(await registrar.shortcuts.values.first == shortcutB)

    await coordinator.remove(bindingID: binding.id)
    #expect(await coordinator.registeredBindings().isEmpty)
    #expect(await registrar.shortcuts.isEmpty)
}

@Test
func detectsAnInApplicationShortcutConflict() async throws {
    let (coordinator, _, _, script) = try coordinatorFixture()
    try await coordinator.upsertScript(script)
    let first = ShortcutBinding(shortcut: shortcutA, scriptID: script.id)
    let second = ShortcutBinding(shortcut: shortcutA, scriptID: script.id)
    try await coordinator.register(first)

    await #expect(throws: ShortcutCoordinatorError.shortcutConflict(existingBindingID: first.id)) {
        try await coordinator.register(second)
    }
}

@Test
func unavailableReplacementKeepsTheWorkingRegistration() async throws {
    let (coordinator, registrar, _, script) = try coordinatorFixture()
    try await coordinator.upsertScript(script)
    var binding = ShortcutBinding(shortcut: shortcutA, scriptID: script.id)
    try await coordinator.register(binding)
    await registrar.makeUnavailable(shortcutB)
    binding.shortcut = shortcutB

    await #expect(throws: GlobalHotKeyError.unavailable(shortcutB, status: -9878)) {
        try await coordinator.register(binding)
    }

    #expect(await coordinator.registeredBindings().first?.shortcut == shortcutA)
    #expect(await registrar.shortcuts.values.first == shortcutA)
}

@Test
func rejectsABindingWhoseScriptDoesNotExist() async throws {
    let (coordinator, _, _, _) = try coordinatorFixture()
    let missingScriptID = UUID()
    let binding = ShortcutBinding(shortcut: shortcutA, scriptID: missingScriptID)

    await #expect(throws: ShortcutCoordinatorError.scriptNotFound(missingScriptID)) {
        try await coordinator.register(binding)
    }
}
