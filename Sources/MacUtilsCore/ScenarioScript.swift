import Foundation

/// Parses and serializes structured Mac Utils scenarios.
///
/// Toggle grammar extends the one-action-per-line DSL without evaluating code:
/// ```text
/// @toggle provider="display.mode" equals="mirror" display="stable-uuid"
///   @match
///     extend-display display="stable-uuid"
///   @otherwise
///     mirror-display display="stable-uuid" source="source-uuid"
/// @end
/// ```
public struct ScenarioScriptEngine: Sendable {
    private let actions: ActionRegistry
    private let stateProviders: StateProviderRegistry
    private let actionParser = ActionScriptParser()
    private let actionEngine: ActionScriptEngine
    private let executor: ScenarioExecutor

    public init(actions: ActionRegistry, stateProviders: StateProviderRegistry) {
        self.actions = actions
        self.stateProviders = stateProviders
        actionEngine = ActionScriptEngine(registry: actions)
        executor = ScenarioExecutor(actions: actions, stateProviders: stateProviders)
    }

    public func compile(_ source: String, name: String = "Scenario") throws -> Scenario {
        var parser = StructuredParser(
            source: source,
            actions: actions,
            stateProviders: stateProviders,
            actionParser: actionParser,
            actionEngine: actionEngine
        )
        let scenario = try parser.parse(name: name)
        try executor.validate(scenario)
        return scenario
    }

    public func serialize(_ scenario: Scenario) -> String {
        serialize(steps: scenario.steps, indentation: 0).joined(separator: "\n")
    }

    public func execute(
        _ source: String,
        name: String = "Scenario",
        context: ActionContext = ActionContext()
    ) async throws -> ScenarioExecutionResult {
        let scenario = try compile(source, name: name)
        return try await executor.execute(scenario, context: context)
    }

    private func serialize(steps: [ScenarioStep], indentation: Int) -> [String] {
        let prefix = String(repeating: "  ", count: indentation)
        var lines: [String] = []
        for step in steps {
            switch step {
            case let .action(invocation):
                lines.append(
                    prefix + ActionDSL.serialize(
                        invocation,
                        metadata: actions.action(for: invocation.actionID)?.metadata
                    )
                )
            case let .toggle(toggle):
                let providerMetadata = stateProviders.provider(for: toggle.providerID)?.metadata
                let orderedNames = providerMetadata?.parameters.map(\.name) ?? []
                let extraNames = toggle.parameters.keys.filter { !orderedNames.contains($0) }.sorted()
                let parameterText = (orderedNames + extraNames).compactMap { name -> String? in
                    guard let value = toggle.parameters[name] else { return nil }
                    return "\(name)=\"\(ActionDSL.escape(ActionDSL.stringValue(value)))\""
                }
                let headerParts = [
                    "@toggle",
                    "provider=\"\(ActionDSL.escape(toggle.providerID.rawValue))\"",
                    "equals=\"\(ActionDSL.escape(ActionDSL.stringValue(toggle.expectedValue)))\"",
                ] + parameterText
                lines.append(prefix + headerParts.joined(separator: " "))
                lines.append(prefix + "  @match")
                lines.append(contentsOf: serialize(steps: toggle.matchingSteps, indentation: indentation + 2))
                lines.append(prefix + "  @otherwise")
                lines.append(contentsOf: serialize(steps: toggle.otherSteps, indentation: indentation + 2))
                lines.append(prefix + "@end")
            }
        }
        return lines
    }
}

private struct StructuredParser {
    private struct SourceLine {
        let number: Int
        let text: String
        var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    }

    private let lines: [SourceLine]
    private let actions: ActionRegistry
    private let stateProviders: StateProviderRegistry
    private let actionParser: ActionScriptParser
    private let actionEngine: ActionScriptEngine
    private var index = 0

    init(
        source: String,
        actions: ActionRegistry,
        stateProviders: StateProviderRegistry,
        actionParser: ActionScriptParser,
        actionEngine: ActionScriptEngine
    ) {
        lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { SourceLine(number: $0.offset + 1, text: String($0.element)) }
        self.actions = actions
        self.stateProviders = stateProviders
        self.actionParser = actionParser
        self.actionEngine = actionEngine
    }

    mutating func parse(name: String) throws -> Scenario {
        let steps = try parseSteps(stoppingAt: [])
        if let line = currentSignificantLine() {
            throw diagnostic(line, .unexpectedMarker(line.trimmed))
        }
        return Scenario(name: name, steps: steps)
    }

    private mutating func parseSteps(stoppingAt markers: Set<String>) throws -> [ScenarioStep] {
        var steps: [ScenarioStep] = []
        while let line = currentSignificantLine() {
            if markers.contains(line.trimmed) { break }
            if line.trimmed.hasPrefix("@toggle") {
                index += 1
                steps.append(.toggle(try parseToggle(header: line)))
            } else if line.trimmed.hasPrefix("@") {
                throw diagnostic(line, .unexpectedMarker(line.trimmed))
            } else {
                index += 1
                steps.append(.action(try parseAction(line)))
            }
        }
        return steps
    }

    private mutating func parseToggle(header: SourceLine) throws -> StateToggle {
        let suffix = String(header.trimmed.dropFirst("@toggle".count))
        let parsedHeader: ActionScript
        do {
            parsedHeader = try actionParser.parse("toggle\(suffix)", name: "Toggle header")
        } catch let error as ScriptDiagnostic {
            throw ScriptDiagnostic(line: header.number, column: error.column, reason: error.reason)
        }
        guard let invocation = parsedHeader.steps.first?.invocation,
              case let .string(providerRaw)? = invocation.parameters["provider"] else {
            throw diagnostic(header, .toggleProviderRequired)
        }
        guard StateProviderID.isValid(providerRaw) else {
            throw diagnostic(header, .invalidProviderIdentifier(providerRaw))
        }
        let providerID = StateProviderID(providerRaw)
        guard let provider = stateProviders.provider(for: providerID) else {
            throw diagnostic(header, .unknownProvider(providerID))
        }
        guard case let .string(expectedRaw)? = invocation.parameters["equals"] else {
            throw diagnostic(header, .toggleEqualsRequired)
        }
        let expectedValue: ActionValue
        do {
            expectedValue = try ActionValue.parse(expectedRaw, as: provider.metadata.resultType)
        } catch {
            throw diagnostic(header, .toggleComparisonType(provider.metadata.resultType))
        }

        let definitions = Dictionary(uniqueKeysWithValues: provider.metadata.parameters.map { ($0.name, $0) })
        var parameters: ActionParameters = [:]
        for (name, value) in invocation.parameters where name != "provider" && name != "equals" {
            guard case let .string(raw) = value else { continue }
            if let definition = definitions[name] {
                do {
                    parameters[name] = try ActionValue.parse(raw, as: definition.type)
                } catch {
                    throw diagnostic(header, .providerParameterType(name: name, type: definition.type))
                }
            } else {
                parameters[name] = value
            }
        }

        try consume(marker: "@match", after: header)
        let matching = try parseSteps(stoppingAt: ["@otherwise"])
        try consume(marker: "@otherwise", after: header)
        let other = try parseSteps(stoppingAt: ["@end"])
        try consume(marker: "@end", after: header)
        return StateToggle(
            providerID: providerID,
            parameters: parameters,
            expectedValue: expectedValue,
            matchingSteps: matching,
            otherSteps: other
        )
    }

    private func parseAction(_ line: SourceLine) throws -> ActionInvocation {
        do {
            let script = try actionEngine.compile(line.trimmed, name: "Scenario action")
            guard script.steps.count == 1, let invocation = script.steps.first?.invocation else {
                throw diagnostic(line, .expectedOneAction)
            }
            return invocation
        } catch let error as ScriptDiagnostic {
            throw ScriptDiagnostic(line: line.number, column: error.column, reason: error.reason)
        }
    }

    private mutating func consume(marker: String, after header: SourceLine) throws {
        guard let line = currentSignificantLine(), line.trimmed == marker else {
            throw diagnostic(header, .toggleMarkerRequired(marker))
        }
        index += 1
    }

    private mutating func currentSignificantLine() -> SourceLine? {
        while index < lines.count {
            let line = lines[index]
            if line.trimmed.isEmpty || line.trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            return line
        }
        return nil
    }

    private func diagnostic(_ line: SourceLine, _ reason: ScriptDiagnosticReason) -> ScriptDiagnostic {
        ScriptDiagnostic(line: line.number, column: 1, reason: reason)
    }
}
