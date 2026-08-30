import Foundation

public enum ActionDSL {
    public static func serialize(
        _ invocation: ActionInvocation,
        metadata: ActionMetadata? = nil
    ) -> String {
        let orderedNames = metadata?.parameters.map(\.name) ?? []
        let extraNames = invocation.parameters.keys.filter { !orderedNames.contains($0) }.sorted()
        let parameters = (orderedNames + extraNames).compactMap { name -> String? in
            guard let value = invocation.parameters[name] else { return nil }
            return "\(name)=\"\(escape(stringValue(value)))\""
        }
        return ([invocation.actionID.rawValue] + parameters).joined(separator: " ")
    }

    public static func stringValue(_ value: ActionValue) -> String {
        switch value {
        case let .string(string): string
        case let .integer(integer): String(integer)
        case let .number(number): String(number)
        case let .boolean(boolean): String(boolean)
        }
    }

    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
