import Foundation
import MacUtilsCore

public enum ShortcutCoordinatorError: Error, Equatable, Sendable, CustomStringConvertible {
    case scriptNotFound(UUID)
    case shortcutConflict(existingBindingID: UUID)

    public var description: String {
        switch self {
        case let .scriptNotFound(id):
            "Script '\(id)' does not exist."
        case let .shortcutConflict(id):
            "This global shortcut is already assigned to binding '\(id)'."
        }
    }
}

public enum ShortcutExecutionStatus: Equatable, Sendable {
    case succeeded(stepCount: Int)
    case failed(message: String)
}

public struct ShortcutExecutionEvent: Equatable, Sendable {
    public let bindingID: UUID
    public let status: ShortcutExecutionStatus
}

public actor ShortcutCoordinator {
    private struct ActiveBinding: Sendable {
        var binding: ShortcutBinding
        let token: HotKeyRegistrationToken
    }

    private let registrar: any GlobalHotKeyRegistering
    private let engine: ScenarioScriptEngine
    private var scripts: [UUID: UserScript] = [:]
    private var bindings: [UUID: ActiveBinding] = [:]
    public private(set) var lastExecution: ShortcutExecutionEvent?

    init(
        registrar: any GlobalHotKeyRegistering,
        registry: ActionRegistry,
        stateProviders: StateProviderRegistry = StateProviderRegistry()
    ) {
        self.registrar = registrar
        engine = ScenarioScriptEngine(actions: registry, stateProviders: stateProviders)
    }

    @MainActor
    public static func live(
        registry: ActionRegistry,
        stateProviders: StateProviderRegistry = StateProviderRegistry(),
        diagnostics: Bool = false
    ) throws -> ShortcutCoordinator {
        ShortcutCoordinator(
            registrar: try CarbonHotKeyRegistrar(diagnostics: diagnostics),
            registry: registry,
            stateProviders: stateProviders
        )
    }

    /// Creates an isolated coordinator for deterministic UI and screenshot fixtures.
    public static func inMemoryFixture(
        registry: ActionRegistry,
        stateProviders: StateProviderRegistry = StateProviderRegistry()
    ) -> ShortcutCoordinator {
        ShortcutCoordinator(
            registrar: InMemoryHotKeyRegistrar(),
            registry: registry,
            stateProviders: stateProviders
        )
    }

    public func upsertScript(_ script: UserScript) throws {
        _ = try engine.compile(script.source, name: script.name)
        scripts[script.id] = script
    }

    public func removeScript(id: UUID) {
        scripts[id] = nil
    }

    public func register(_ binding: ShortcutBinding) async throws {
        guard scripts[binding.scriptID] != nil else {
            throw ShortcutCoordinatorError.scriptNotFound(binding.scriptID)
        }
        if let conflict = bindings.values.first(where: {
            $0.binding.shortcut == binding.shortcut && $0.binding.id != binding.id
        }) {
            throw ShortcutCoordinatorError.shortcutConflict(existingBindingID: conflict.binding.id)
        }

        if let existing = bindings[binding.id], existing.binding.shortcut == binding.shortcut {
            bindings[binding.id]?.binding = binding
            return
        }

        let token = try await registrar.register(binding.shortcut) { [weak self] in
            await self?.execute(bindingID: binding.id)
        }
        if let existing = bindings[binding.id] {
            await registrar.unregister(existing.token)
        }
        bindings[binding.id] = ActiveBinding(binding: binding, token: token)
    }

    public func remove(bindingID: UUID) async {
        guard let existing = bindings.removeValue(forKey: bindingID) else { return }
        await registrar.unregister(existing.token)
    }

    public func registeredBindings() -> [ShortcutBinding] {
        bindings.values.map(\.binding).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func execute(bindingID: UUID) async {
        guard let binding = bindings[bindingID]?.binding,
              let script = scripts[binding.scriptID] else {
            lastExecution = ShortcutExecutionEvent(
                bindingID: bindingID,
                status: .failed(message: "The binding or its script no longer exists.")
            )
            return
        }

        do {
            let result = try await engine.execute(script.source, name: script.name)
            let actionCount = result.events.reduce(into: 0) { count, event in
                if case .action = event { count += 1 }
            }
            lastExecution = ShortcutExecutionEvent(
                bindingID: bindingID,
                status: .succeeded(stepCount: actionCount)
            )
        } catch {
            lastExecution = ShortcutExecutionEvent(
                bindingID: bindingID,
                status: .failed(message: String(describing: error))
            )
        }
    }
}

private actor InMemoryHotKeyRegistrar: GlobalHotKeyRegistering {
    private var nextID: UInt32 = 1
    private var registrations: Set<HotKeyRegistrationToken> = []

    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @Sendable () async -> Void
    ) async throws -> HotKeyRegistrationToken {
        let token = HotKeyRegistrationToken(rawValue: nextID)
        nextID += 1
        registrations.insert(token)
        return token
    }

    func unregister(_ token: HotKeyRegistrationToken) async {
        registrations.remove(token)
    }
}
