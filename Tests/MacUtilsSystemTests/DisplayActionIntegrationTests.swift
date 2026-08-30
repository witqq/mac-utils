import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private actor RecordingDisplayManager: DisplayManaging {
    enum Command: Equatable {
        case main(DisplayID)
        case extended(DisplayID)
        case mirror(DisplayID, source: DisplayID)
    }

    var connectedDisplays: [DisplayDescriptor]
    private(set) var commands: [Command] = []

    init(connectedDisplays: [DisplayDescriptor]) {
        self.connectedDisplays = connectedDisplays
    }

    func displays() async throws -> [DisplayDescriptor] {
        connectedDisplays
    }

    func setMainDisplay(_ display: DisplayID) async throws {
        commands.append(.main(display))
    }

    func setExtendedDisplay(_ display: DisplayID) async throws {
        commands.append(.extended(display))
    }

    func setMirrorDisplay(_ display: DisplayID, source: DisplayID) async throws {
        commands.append(.mirror(display, source: source))
    }
}

private let displayA = DisplayDescriptor(
    id: DisplayID("display-a"),
    name: "A",
    frame: DisplayFrame(x: 0, y: 0, width: 1920, height: 1080),
    role: .main
)
private let displayB = DisplayDescriptor(
    id: DisplayID("display-b"),
    name: "B",
    frame: DisplayFrame(x: 1920, y: 0, width: 1920, height: 1080),
    role: .extended
)

private func displayExecutor(
    manager: RecordingDisplayManager
) throws -> (ActionRegistry, ActionExecutor) {
    var registry = ActionRegistry()
    try DisplayActions.register(in: &registry, manager: manager)
    return (registry, ActionExecutor(registry: registry))
}

@Test
func registersAllDisplayActionsInTheSharedRegistry() throws {
    let manager = RecordingDisplayManager(connectedDisplays: [displayA, displayB])
    let (registry, _) = try displayExecutor(manager: manager)

    #expect(registry.metadata.map(\.id) == [
        DisplayActions.extendID,
        DisplayActions.mirrorID,
        DisplayActions.setMainID,
    ])
}

@Test
func sharedExecutorRoutesEveryDisplayActionToOneBackend() async throws {
    let manager = RecordingDisplayManager(connectedDisplays: [displayA, displayB])
    let (_, executor) = try displayExecutor(manager: manager)
    let sequence = ActionSequence(
        name: "Display layout",
        steps: [
            ActionInvocation(
                actionID: DisplayActions.setMainID,
                parameters: ["display": .string(displayB.id.rawValue)]
            ),
            ActionInvocation(
                actionID: DisplayActions.extendID,
                parameters: ["display": .string(displayB.id.rawValue)]
            ),
            ActionInvocation(
                actionID: DisplayActions.mirrorID,
                parameters: [
                    "display": .string(displayB.id.rawValue),
                    "source": .string(displayA.id.rawValue),
                ]
            ),
        ]
    )

    let result = try await executor.execute(sequence)

    #expect(result.steps.map(\.actionID) == [
        DisplayActions.setMainID,
        DisplayActions.extendID,
        DisplayActions.mirrorID,
    ])
    #expect(await manager.commands == [
        .main(displayB.id),
        .extended(displayB.id),
        .mirror(displayB.id, source: displayA.id),
    ])
}

@Test
func unavailableStableIdentifierFailsBeforeCallingTheBackend() async throws {
    let manager = RecordingDisplayManager(connectedDisplays: [displayA])
    let (_, executor) = try displayExecutor(manager: manager)
    let missing = DisplayID("disconnected-display")
    let sequence = ActionSequence(
        name: "Unavailable",
        steps: [
            ActionInvocation(
                actionID: DisplayActions.setMainID,
                parameters: ["display": .string(missing.rawValue)]
            ),
        ]
    )

    do {
        _ = try await executor.execute(sequence)
        Issue.record("Expected an unavailable display error")
    } catch let error as ActionExecutionError {
        #expect(error == .actionFailed(
            index: 0,
            actionID: DisplayActions.setMainID,
            message: DisplayActionError.displayUnavailable(missing).description
        ))
    }
    #expect(await manager.commands.isEmpty)
}
