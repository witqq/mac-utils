public enum ActionRegistryError: Error, Equatable, Sendable, CustomStringConvertible {
    case duplicateAction(ActionID)

    public var description: String {
        switch self {
        case let .duplicateAction(id):
            "An action with ID '\(id)' is already registered."
        }
    }
}

public struct ActionRegistry: Sendable {
    private var actions: [ActionID: any UtilityAction] = [:]

    public init() {}

    public var metadata: [ActionMetadata] {
        actions.values.map(\.metadata).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public mutating func register(_ action: any UtilityAction) throws {
        let id = action.metadata.id
        guard actions[id] == nil else {
            throw ActionRegistryError.duplicateAction(id)
        }
        actions[id] = action
    }

    public func action(for id: ActionID) -> (any UtilityAction)? {
        actions[id]
    }
}
