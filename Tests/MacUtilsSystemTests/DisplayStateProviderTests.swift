import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private actor StatefulDisplayManager: DisplayManaging {
    enum Command: Equatable {
        case extended(DisplayID)
        case mirror(DisplayID, source: DisplayID)
    }

    private var current: [DisplayDescriptor]
    private(set) var commands: [Command] = []

    init(displays: [DisplayDescriptor]) { current = displays }

    func displays() async throws -> [DisplayDescriptor] { current }

    func setMainDisplay(_ display: DisplayID) async throws {}

    func setExtendedDisplay(_ display: DisplayID) async throws {
        guard let index = current.firstIndex(where: { $0.id == display }) else {
            throw DisplayManagerError.displayNotFound(display)
        }
        current[index].role = .extended
        commands.append(.extended(display))
    }

    func setMirrorDisplay(_ display: DisplayID, source: DisplayID) async throws {
        guard let index = current.firstIndex(where: { $0.id == display }) else {
            throw DisplayManagerError.displayNotFound(display)
        }
        current[index].role = .mirror(source: source)
        commands.append(.mirror(display, source: source))
    }
}

private let toggleMain = DisplayID("toggle-main")
private let toggleTarget = DisplayID("toggle-target")

private func toggleDisplays(targetRole: DisplayRole) -> [DisplayDescriptor] {
    [
        DisplayDescriptor(
            id: toggleMain,
            name: "Main",
            frame: DisplayFrame(x: 0, y: 0, width: 1920, height: 1080),
            role: .main
        ),
        DisplayDescriptor(
            id: toggleTarget,
            name: "Target",
            frame: DisplayFrame(x: 1920, y: 0, width: 1920, height: 1080),
            role: targetRole
        ),
    ]
}

private func displayToggleScenario() -> Scenario {
    Scenario(
        name: "Mirror or extend",
        steps: [
            .toggle(StateToggle(
                providerID: DisplayStateProviders.modeID,
                parameters: ["display": .string(toggleTarget.rawValue)],
                expectedValue: .string("mirror"),
                matchingSteps: [
                    .action(ActionInvocation(
                        actionID: DisplayActions.extendID,
                        parameters: ["display": .string(toggleTarget.rawValue)]
                    )),
                ],
                otherSteps: [
                    .action(ActionInvocation(
                        actionID: DisplayActions.mirrorID,
                        parameters: [
                            "display": .string(toggleTarget.rawValue),
                            "source": .string(toggleMain.rawValue),
                        ]
                    )),
                ]
            )),
        ]
    )
}

@Test
func displayModeProviderReadsActualRoleAndToggleTracksExternalState() async throws {
    let manager = StatefulDisplayManager(displays: toggleDisplays(targetRole: .mirror(source: toggleMain)))
    var actions = ActionRegistry()
    try DisplayActions.register(in: &actions, manager: manager)
    var providers = StateProviderRegistry()
    try DisplayStateProviders.register(in: &providers, manager: manager)
    let executor = ScenarioExecutor(actions: actions, stateProviders: providers)

    _ = try await executor.execute(displayToggleScenario())
    _ = try await executor.execute(displayToggleScenario())

    #expect(await manager.commands == [
        .extended(toggleTarget),
        .mirror(toggleTarget, source: toggleMain),
    ])
}

@Test
func disconnectedDisplayProducesAStateReadErrorWithoutAnAction() async throws {
    let manager = StatefulDisplayManager(displays: toggleDisplays(targetRole: .extended))
    var actions = ActionRegistry()
    try DisplayActions.register(in: &actions, manager: manager)
    var providers = StateProviderRegistry()
    try DisplayStateProviders.register(in: &providers, manager: manager)
    let missing = DisplayID("missing-toggle-display")
    let scenario = Scenario(
        name: "Missing",
        steps: [
            .toggle(StateToggle(
                providerID: DisplayStateProviders.modeID,
                parameters: ["display": .string(missing.rawValue)],
                expectedValue: .string("mirror"),
                matchingSteps: [],
                otherSteps: []
            )),
        ]
    )

    do {
        _ = try await ScenarioExecutor(actions: actions, stateProviders: providers).execute(scenario)
        Issue.record("Expected disconnected display failure")
    } catch let error as ScenarioExecutionError {
        #expect(error == .stateReadFailed(
            providerID: DisplayStateProviders.modeID,
            message: DisplayActionError.displayUnavailable(missing).description
        ))
    }
    #expect(await manager.commands.isEmpty)
}
