import Foundation

public struct StateProviderID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(Self.isValid(rawValue), "State provider IDs must use lowercase dot-separated identifiers")
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func isValid(_ value: String) -> Bool {
        value.wholeMatch(of: /^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$/) != nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard Self.isValid(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid state provider identifier: \(value)"
            )
        }
        rawValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct StateOption: Hashable, Codable, Sendable {
    public let value: ActionValue
    public let label: String

    public init(value: ActionValue, label: String) {
        self.value = value
        self.label = label
    }
}

public struct StateProviderMetadata: Hashable, Codable, Sendable {
    public let id: StateProviderID
    public let name: String
    public let description: String
    public let parameters: [ActionParameter]
    public let resultType: ActionValueType
    public let options: [StateOption]

    public init(
        id: StateProviderID,
        name: String,
        description: String,
        parameters: [ActionParameter] = [],
        resultType: ActionValueType,
        options: [StateOption] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parameters = parameters
        self.resultType = resultType
        self.options = options
    }
}

public protocol StateProvider: Sendable {
    var metadata: StateProviderMetadata { get }

    func read(parameters: ActionParameters, context: ActionContext) async throws -> ActionValue
}

public enum StateProviderRegistryError: Error, Equatable, Sendable {
    case duplicateProvider(StateProviderID)
}

public struct StateProviderRegistry: Sendable {
    private var providers: [StateProviderID: any StateProvider] = [:]

    public init() {}

    public var metadata: [StateProviderMetadata] {
        providers.values.map(\.metadata).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public mutating func register(_ provider: any StateProvider) throws {
        let id = provider.metadata.id
        guard providers[id] == nil else {
            throw StateProviderRegistryError.duplicateProvider(id)
        }
        providers[id] = provider
    }

    public func provider(for id: StateProviderID) -> (any StateProvider)? {
        providers[id]
    }
}
