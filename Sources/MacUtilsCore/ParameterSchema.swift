public enum ParameterSchemaViolation: Error, Equatable, Sendable {
    case missing(name: String)
    case unexpected(name: String)
    case wrongType(name: String, expected: ActionValueType, actual: ActionValueType)
}

public enum ParameterSchema {
    public static func validate(
        _ values: ActionParameters,
        definitions: [ActionParameter]
    ) throws {
        let definitionsByName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
        for definition in definitions where definition.isRequired && values[definition.name] == nil {
            throw ParameterSchemaViolation.missing(name: definition.name)
        }
        for (name, value) in values {
            guard let definition = definitionsByName[name] else {
                throw ParameterSchemaViolation.unexpected(name: name)
            }
            guard value.type == definition.type else {
                throw ParameterSchemaViolation.wrongType(
                    name: name,
                    expected: definition.type,
                    actual: value.type
                )
            }
        }
    }

    public static func defaults(for definitions: [ActionParameter]) -> ActionParameters {
        Dictionary(uniqueKeysWithValues: definitions.compactMap { parameter in
            guard parameter.isRequired else { return nil }
            return switch parameter.type {
            case .string: nil
            case .integer: (parameter.name, .integer(0))
            case .number: (parameter.name, .number(0))
            case .boolean: (parameter.name, .boolean(false))
            }
        })
    }
}
