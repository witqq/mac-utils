import Foundation

public struct ActionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(Self.isValid(rawValue), "Action IDs must use lowercase dot-separated identifiers")
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    private static func isValid(_ value: String) -> Bool {
        value.wholeMatch(of: /^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$/) != nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard Self.isValid(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid action identifier: \(value)"
            )
        }
        rawValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ActionValueType: String, Codable, CaseIterable, Sendable {
    case string
    case integer
    case number
    case boolean
}

public enum ActionValue: Hashable, Codable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)

    public var type: ActionValueType {
        switch self {
        case .string: .string
        case .integer: .integer
        case .number: .number
        case .boolean: .boolean
        }
    }

    public static func parse(_ rawValue: String, as type: ActionValueType) throws -> ActionValue {
        switch type {
        case .string:
            .string(rawValue)
        case .integer:
            if let value = Int(rawValue) { .integer(value) } else { throw ActionValueConversionError.invalid(rawValue, type) }
        case .number:
            if let value = Double(rawValue) { .number(value) } else { throw ActionValueConversionError.invalid(rawValue, type) }
        case .boolean:
            switch rawValue.lowercased() {
            case "true": .boolean(true)
            case "false": .boolean(false)
            default: throw ActionValueConversionError.invalid(rawValue, type)
            }
        }
    }
}

public enum ActionValueConversionError: Error, Equatable, Sendable {
    case invalid(String, ActionValueType)
}

public struct ActionParameter: Hashable, Codable, Sendable {
    public let name: String
    public let type: ActionValueType
    public let isRequired: Bool
    public let description: String

    public init(name: String, type: ActionValueType, isRequired: Bool = true, description: String) {
        precondition(!name.isEmpty, "Parameter names cannot be empty")
        self.name = name
        self.type = type
        self.isRequired = isRequired
        self.description = description
    }
}

public struct ActionMetadata: Hashable, Codable, Sendable {
    public let id: ActionID
    public let name: String
    public let description: String
    public let parameters: [ActionParameter]

    public init(id: ActionID, name: String, description: String, parameters: [ActionParameter] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public typealias ActionParameters = [String: ActionValue]

public struct ActionContext: Hashable, Codable, Sendable {
    public let runID: UUID

    public init(runID: UUID = UUID()) {
        self.runID = runID
    }
}

public struct ActionResult: Hashable, Codable, Sendable {
    public let summary: String
    public let values: [String: ActionValue]

    public init(summary: String, values: [String: ActionValue] = [:]) {
        self.summary = summary
        self.values = values
    }
}

public protocol UtilityAction: Sendable {
    var metadata: ActionMetadata { get }

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult
}
