import MacUtilsCore

public enum DisplayActions {
    public static let setMainID = ActionID("set-main-display")
    public static let extendID = ActionID("extend-display")
    public static let mirrorID = ActionID("mirror-display")

    public static func register(
        in registry: inout ActionRegistry,
        manager: any DisplayManaging
    ) throws {
        try registry.register(SetMainDisplayAction(manager: manager))
        try registry.register(ExtendDisplayAction(manager: manager))
        try registry.register(MirrorDisplayAction(manager: manager))
    }
}

public enum DisplayActionError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidIdentifier(parameter: String)
    case displayUnavailable(DisplayID)

    public var description: String {
        switch self {
        case let .invalidIdentifier(parameter):
            "Parameter '\(parameter)' must contain a non-empty stable display identifier."
        case let .displayUnavailable(id):
            "Display '\(id)' is not currently connected. Refresh the display list or reconnect it."
        }
    }
}

private struct SetMainDisplayAction: UtilityAction {
    let manager: any DisplayManaging
    let metadata = ActionMetadata(
        id: DisplayActions.setMainID,
        name: "Set main display",
        description: "Makes a connected display the macOS main display.",
        parameters: [displayParameter]
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        let display = try await resolvedDisplay(parameter: "display", values: parameters, manager: manager)
        try await manager.setMainDisplay(display)
        return ActionResult(summary: "Made display \(display) the main display.")
    }
}

private struct ExtendDisplayAction: UtilityAction {
    let manager: any DisplayManaging
    let metadata = ActionMetadata(
        id: DisplayActions.extendID,
        name: "Extend display",
        description: "Removes a connected display from mirroring and extends the desktop onto it.",
        parameters: [displayParameter]
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        let display = try await resolvedDisplay(parameter: "display", values: parameters, manager: manager)
        try await manager.setExtendedDisplay(display)
        return ActionResult(summary: "Extended the desktop onto display \(display).")
    }
}

private struct MirrorDisplayAction: UtilityAction {
    let manager: any DisplayManaging
    let metadata = ActionMetadata(
        id: DisplayActions.mirrorID,
        name: "Mirror display",
        description: "Makes one connected display mirror another connected display.",
        parameters: [
            displayParameter,
            ActionParameter(
                name: "source",
                type: .string,
                description: "Stable identifier of the display whose content should be mirrored"
            ),
        ]
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        let display = try await resolvedDisplay(parameter: "display", values: parameters, manager: manager)
        let source = try await resolvedDisplay(parameter: "source", values: parameters, manager: manager)
        try await manager.setMirrorDisplay(display, source: source)
        return ActionResult(summary: "Made display \(display) mirror display \(source).")
    }
}

private let displayParameter = ActionParameter(
    name: "display",
    type: .string,
    description: "Stable identifier of the display to change"
)

func resolvedDisplay(
    parameter: String,
    values: ActionParameters,
    manager: any DisplayManaging
) async throws -> DisplayID {
    guard case let .string(rawID) = values[parameter], !rawID.isEmpty else {
        throw DisplayActionError.invalidIdentifier(parameter: parameter)
    }
    let id = DisplayID(rawID)
    guard try await manager.displays().contains(where: { $0.id == id }) else {
        throw DisplayActionError.displayUnavailable(id)
    }
    return id
}
