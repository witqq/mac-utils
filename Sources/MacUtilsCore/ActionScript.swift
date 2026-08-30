import Foundation

public enum ScriptDiagnosticReason: Equatable, Sendable {
    case raw(String)
    case invalidActionIdentifier(String)
    case expectedParameterName
    case duplicateParameter(String)
    case expectedEquals(String)
    case expectedWhitespaceOrComment
    case actionExecution(ActionExecutionError)
    case parameterType(name: String, type: ActionValueType)
    case expectedQuotedString
    case unterminatedEscape
    case unsupportedEscape(Character)
    case unterminatedQuotedString
    case unexpectedMarker(String)
    case toggleProviderRequired
    case invalidProviderIdentifier(String)
    case unknownProvider(StateProviderID)
    case toggleEqualsRequired
    case toggleComparisonType(ActionValueType)
    case providerParameterType(name: String, type: ActionValueType)
    case expectedOneAction
    case toggleMarkerRequired(String)

    public var englishMessage: String {
        switch self {
        case let .raw(message): message
        case let .invalidActionIdentifier(value): "Invalid action identifier '\(value)'."
        case .expectedParameterName: "Expected a lowercase parameter name."
        case let .duplicateParameter(name): "Parameter '\(name)' is specified more than once."
        case let .expectedEquals(name): "Expected '=' after parameter '\(name)'."
        case .expectedWhitespaceOrComment: "Expected whitespace or a comment after the quoted value."
        case let .actionExecution(error): error.description
        case let .parameterType(name, type): "Parameter '\(name)' must be \(type.rawValue)."
        case .expectedQuotedString: "Expected a quoted string value."
        case .unterminatedEscape: "Unterminated escape sequence."
        case let .unsupportedEscape(value): "Unsupported escape '\\\(value)'."
        case .unterminatedQuotedString: "Unterminated quoted string."
        case let .unexpectedMarker(marker): "Unexpected marker '\(marker)'."
        case .toggleProviderRequired: "Toggle requires provider=\"...\"."
        case let .invalidProviderIdentifier(value): "Invalid state provider identifier '\(value)'."
        case let .unknownProvider(id): "Unknown state provider '\(id)'."
        case .toggleEqualsRequired: "Toggle requires equals=\"...\"."
        case let .toggleComparisonType(type): "Toggle comparison must be \(type.rawValue)."
        case let .providerParameterType(name, type): "Provider parameter '\(name)' must be \(type.rawValue)."
        case .expectedOneAction: "Expected exactly one action."
        case let .toggleMarkerRequired(marker): "Toggle requires '\(marker)'."
        }
    }
}

public struct ScriptDiagnostic: Error, Equatable, Sendable, CustomStringConvertible {
    public let line: Int
    public let column: Int
    public let reason: ScriptDiagnosticReason
    public var message: String { reason.englishMessage }

    public init(line: Int, column: Int, message: String) {
        self.line = line
        self.column = column
        reason = .raw(message)
    }

    public init(line: Int, column: Int, reason: ScriptDiagnosticReason) {
        self.line = line
        self.column = column
        self.reason = reason
    }

    public static func == (lhs: ScriptDiagnostic, rhs: ScriptDiagnostic) -> Bool {
        lhs.line == rhs.line && lhs.column == rhs.column && lhs.message == rhs.message
    }

    public var description: String {
        "Line \(line), column \(column): \(message)"
    }
}

public struct ScriptStep: Hashable, Sendable {
    public let line: Int
    public let invocation: ActionInvocation
}

public struct ActionScript: Hashable, Sendable {
    public let name: String
    public let steps: [ScriptStep]

    public var sequence: ActionSequence {
        ActionSequence(name: name, steps: steps.map(\.invocation))
    }
}

/// Parses the deliberately small Mac Utils action language.
///
/// Grammar:
/// ```text
/// script       := { blank-line | comment-line | command-line }
/// command-line := action-id { whitespace parameter } [ whitespace comment ]
/// parameter    := parameter-name whitespace* "=" whitespace* quoted-string
/// comment      := "#" { any-character }
/// quoted-string supports: \\"  \\\\  \\n  \\t
/// ```
///
/// Every command resolves only through `ActionRegistry`; the language has no
/// expression evaluation, file access, process launch, shell, or foreign runtime.
public struct ActionScriptParser: Sendable {
    public init() {}

    public func parse(_ source: String, name: String = "Script") throws -> ActionScript {
        var steps: [ScriptStep] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)
            var cursor = LineCursor(line)
            cursor.skipWhitespace()
            guard !cursor.isAtEnd, cursor.current != "#" else { continue }

            let actionColumn = cursor.column
            let actionName = cursor.consumeToken()
            guard isActionIdentifier(actionName) else {
                throw ScriptDiagnostic(
                    line: lineNumber,
                    column: actionColumn,
                    reason: .invalidActionIdentifier(actionName)
                )
            }

            var parameters: ActionParameters = [:]
            while true {
                cursor.skipWhitespace()
                guard !cursor.isAtEnd, cursor.current != "#" else { break }

                let parameterColumn = cursor.column
                let parameterName = cursor.consumeParameterName()
                guard isParameterName(parameterName) else {
                    throw ScriptDiagnostic(
                        line: lineNumber,
                        column: parameterColumn,
                        reason: .expectedParameterName
                    )
                }
                guard parameters[parameterName] == nil else {
                    throw ScriptDiagnostic(
                        line: lineNumber,
                        column: parameterColumn,
                        reason: .duplicateParameter(parameterName)
                    )
                }

                cursor.skipWhitespace()
                guard cursor.consume("=") else {
                    throw ScriptDiagnostic(
                        line: lineNumber,
                        column: cursor.column,
                        reason: .expectedEquals(parameterName)
                    )
                }
                cursor.skipWhitespace()
                parameters[parameterName] = .string(try cursor.consumeQuotedString(line: lineNumber))

                if !cursor.isAtEnd, cursor.current != "#", !cursor.currentIsWhitespace {
                    throw ScriptDiagnostic(
                        line: lineNumber,
                        column: cursor.column,
                        reason: .expectedWhitespaceOrComment
                    )
                }
            }

            steps.append(
                ScriptStep(
                    line: lineNumber,
                    invocation: ActionInvocation(actionID: ActionID(actionName), parameters: parameters)
                )
            )
        }

        return ActionScript(name: name, steps: steps)
    }

    private func isActionIdentifier(_ value: String) -> Bool {
        value.wholeMatch(of: /^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$/) != nil
    }

    private func isParameterName(_ value: String) -> Bool {
        value.wholeMatch(of: /^[a-z][a-z0-9_-]*$/) != nil
    }
}

public struct ActionScriptEngine: Sendable {
    private let registry: ActionRegistry
    private let executor: ActionExecutor
    private let parser: ActionScriptParser

    public init(registry: ActionRegistry, parser: ActionScriptParser = ActionScriptParser()) {
        self.registry = registry
        executor = ActionExecutor(registry: registry)
        self.parser = parser
    }

    public func compile(_ source: String, name: String = "Script") throws -> ActionScript {
        let parsed = try parser.parse(source, name: name)
        let script = try normalizeTypes(in: parsed)
        do {
            try executor.validate(script.sequence)
        } catch let error as ActionExecutionError {
            let index = stepIndex(of: error)
            let line = script.steps.indices.contains(index) ? script.steps[index].line : 1
            throw ScriptDiagnostic(line: line, column: 1, reason: .actionExecution(error))
        }
        return script
    }

    public func execute(
        _ source: String,
        name: String = "Script",
        context: ActionContext = ActionContext()
    ) async throws -> ActionSequenceResult {
        let script = try compile(source, name: name)
        return try await executor.execute(script.sequence, context: context)
    }

    private func stepIndex(of error: ActionExecutionError) -> Int {
        switch error {
        case let .unknownAction(index, _),
             let .missingParameter(index, _, _),
             let .unexpectedParameter(index, _, _),
             let .wrongParameterType(index, _, _, _, _),
             let .actionFailed(index, _, _):
            index
        }
    }

    private func normalizeTypes(in script: ActionScript) throws -> ActionScript {
        var normalizedSteps: [ScriptStep] = []
        for step in script.steps {
            guard let action = registry.action(for: step.invocation.actionID) else {
                normalizedSteps.append(step)
                continue
            }
            let definitions = Dictionary(
                uniqueKeysWithValues: action.metadata.parameters.map { ($0.name, $0) }
            )
            var values = step.invocation.parameters
            for (name, value) in values {
                guard case let .string(rawValue) = value,
                      let definition = definitions[name] else { continue }
                do {
                    values[name] = try ActionValue.parse(rawValue, as: definition.type)
                } catch {
                    throw ScriptDiagnostic(
                        line: step.line,
                        column: 1,
                        reason: .parameterType(name: name, type: definition.type)
                    )
                }
            }
            normalizedSteps.append(
                ScriptStep(
                    line: step.line,
                    invocation: ActionInvocation(
                        actionID: step.invocation.actionID,
                        parameters: values
                    )
                )
            )
        }
        return ActionScript(name: script.name, steps: normalizedSteps)
    }

}

private struct LineCursor {
    private let text: String
    private var index: String.Index
    private(set) var column = 1

    init(_ text: String) {
        self.text = text
        index = text.startIndex
    }

    var isAtEnd: Bool { index == text.endIndex }
    var current: Character? { isAtEnd ? nil : text[index] }
    var currentIsWhitespace: Bool { current?.isWhitespace == true }

    mutating func skipWhitespace() {
        while currentIsWhitespace { advance() }
    }

    mutating func consume(_ expected: Character) -> Bool {
        guard current == expected else { return false }
        advance()
        return true
    }

    mutating func consumeToken() -> String {
        consumeWhile { !$0.isWhitespace && $0 != "#" }
    }

    mutating func consumeParameterName() -> String {
        consumeWhile { !$0.isWhitespace && $0 != "=" && $0 != "#" }
    }

    mutating func consumeQuotedString(line: Int) throws -> String {
        guard consume("\"") else {
            throw ScriptDiagnostic(line: line, column: column, reason: .expectedQuotedString)
        }

        var result = ""
        while let character = current {
            if character == "\"" {
                advance()
                return result
            }
            if character == "\\" {
                let escapeColumn = column
                advance()
                guard let escaped = current else {
                    throw ScriptDiagnostic(line: line, column: escapeColumn, reason: .unterminatedEscape)
                }
                switch escaped {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "t": result.append("\t")
                default:
                    throw ScriptDiagnostic(
                        line: line,
                        column: escapeColumn,
                        reason: .unsupportedEscape(escaped)
                    )
                }
                advance()
            } else {
                result.append(character)
                advance()
            }
        }

        throw ScriptDiagnostic(line: line, column: column, reason: .unterminatedQuotedString)
    }

    private mutating func consumeWhile(_ predicate: (Character) -> Bool) -> String {
        var result = ""
        while let character = current, predicate(character) {
            result.append(character)
            advance()
        }
        return result
    }

    private mutating func advance() {
        guard !isAtEnd else { return }
        index = text.index(after: index)
        column += 1
    }
}
