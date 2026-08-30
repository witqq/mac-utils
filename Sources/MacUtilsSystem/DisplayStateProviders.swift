import MacUtilsCore

public enum DisplayStateProviders {
    public static let modeID = StateProviderID("display.mode")

    public static func register(
        in registry: inout StateProviderRegistry,
        manager: any DisplayManaging
    ) throws {
        try registry.register(DisplayModeStateProvider(manager: manager))
    }
}

private struct DisplayModeStateProvider: StateProvider {
    let manager: any DisplayManaging
    let metadata = StateProviderMetadata(
        id: DisplayStateProviders.modeID,
        name: "Display Mode",
        description: "Reads the current role of a connected display.",
        parameters: [
            ActionParameter(
                name: "display",
                type: .string,
                description: "Stable identifier of the display to inspect"
            ),
        ],
        resultType: .string,
        options: [
            StateOption(value: .string("main"), label: "Main"),
            StateOption(value: .string("extended"), label: "Extended"),
            StateOption(value: .string("mirror"), label: "Mirror"),
        ]
    )

    func read(parameters: ActionParameters, context: ActionContext) async throws -> ActionValue {
        let displayID = try await resolvedDisplay(
            parameter: "display",
            values: parameters,
            manager: manager
        )
        guard let display = try await manager.displays().first(where: { $0.id == displayID }) else {
            throw DisplayActionError.displayUnavailable(displayID)
        }
        return switch display.role {
        case .main: .string("main")
        case .extended: .string("extended")
        case .mirror: .string("mirror")
        }
    }
}
