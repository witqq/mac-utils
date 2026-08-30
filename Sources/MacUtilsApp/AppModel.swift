import AppKit
import Combine
import Foundation
import MacUtilsCore
import MacUtilsSystem

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var displays: [DisplayDescriptor] = []
    @Published private(set) var scripts: [UserScript] = []
    @Published private(set) var bindings: [ShortcutBinding] = []
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published private(set) var isRefreshingDisplays = false
    @Published private(set) var isStarting = true
    @Published private(set) var displayRefreshCount = 0
    @Published private(set) var language: AppLanguage

    private let displayManager: any DisplayManaging
    private let registry: ActionRegistry
    private let stateProviders: StateProviderRegistry
    private let executor: ActionExecutor
    private let scriptEngine: ScenarioScriptEngine
    private let shortcutCoordinator: ShortcutCoordinator
    private let configurationStore: ConfigurationStore
    private let userDefaults: UserDefaults
    private var displayChangeSubscription: AnyCancellable?

    init(
        displayManager: any DisplayManaging,
        registry: ActionRegistry,
        stateProviders: StateProviderRegistry,
        shortcutCoordinator: ShortcutCoordinator,
        configurationStore: ConfigurationStore,
        userDefaults: UserDefaults = .standard,
        initialLanguage: AppLanguage? = nil
    ) {
        self.displayManager = displayManager
        self.registry = registry
        self.stateProviders = stateProviders
        executor = ActionExecutor(registry: registry)
        scriptEngine = ScenarioScriptEngine(actions: registry, stateProviders: stateProviders)
        self.shortcutCoordinator = shortcutCoordinator
        self.configurationStore = configurationStore
        self.userDefaults = userDefaults
        language = initialLanguage ?? userDefaults.string(forKey: AppLanguage.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        displayChangeSubscription = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshDisplays()
                }
            }
    }

    func start() async {
        isStarting = true
        defer { isStarting = false }
        let loaded = await configurationStore.load()
        var startupErrors: [String] = []
        if let error = loaded.recoveryError {
            startupErrors.append(text.error(error))
        }

        var runnableScriptIDs: Set<UUID> = []
        for script in loaded.configuration.scripts {
            do {
                try await shortcutCoordinator.upsertScript(script)
                runnableScriptIDs.insert(script.id)
            } catch {
                startupErrors.append(text.format("error.startup.script", script.name, text.error(error)))
            }
        }
        scripts = loaded.configuration.scripts.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        bindings = loaded.configuration.bindings
        for binding in loaded.configuration.bindings {
            guard runnableScriptIDs.contains(binding.scriptID) else {
                startupErrors.append(text.format(
                    "error.startup.shortcut",
                    text.shortcut(binding.shortcut),
                    text("error.shortcut.scriptInvalid")
                ))
                continue
            }
            do {
                try await shortcutCoordinator.register(binding)
            } catch {
                startupErrors.append(text.format(
                    "error.startup.shortcut",
                    text.shortcut(binding.shortcut),
                    text.error(error)
                ))
            }
        }
        if !startupErrors.isEmpty {
            errorMessage = startupErrors.joined(separator: "\n")
        }
        await refreshDisplays()
    }

    func refreshDisplays() async {
        isRefreshingDisplays = true
        defer { isRefreshingDisplays = false }
        do {
            displays = try await displayManager.displays()
            displayRefreshCount += 1
        } catch {
            show(error: error)
        }
    }

    func makeMain(_ display: DisplayID) async {
        await runDisplayAction(
            DisplayActions.setMainID,
            parameters: ["display": .string(display.rawValue)]
        )
    }

    func extend(_ display: DisplayID) async {
        await runDisplayAction(
            DisplayActions.extendID,
            parameters: ["display": .string(display.rawValue)]
        )
    }

    func mirror(_ display: DisplayID, source: DisplayID) async {
        await runDisplayAction(
            DisplayActions.mirrorID,
            parameters: [
                "display": .string(display.rawValue),
                "source": .string(source.rawValue),
            ]
        )
    }

    @discardableResult
    func validateScript(name: String, source: String) -> Bool {
        do {
            _ = try scriptEngine.compile(source, name: name)
            errorMessage = nil
            noticeMessage = text("status.scriptValid")
            return true
        } catch {
            show(error: error)
            return false
        }
    }

    func saveScript(id: UUID?, name: String, source: String) async -> UUID? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            show(message: text("status.scriptNameRequired"))
            return nil
        }
        guard validateScript(name: normalizedName, source: source) else { return nil }

        let script = UserScript(id: id ?? UUID(), name: normalizedName, source: source)
        let previousScripts = scripts
        let previousScript = scripts.first(where: { $0.id == script.id })
        let previousWasRunnable = previousScript.map {
            (try? scriptEngine.compile($0.source, name: $0.name)) != nil
        } ?? false
        let relatedBindings = bindings.filter { $0.scriptID == script.id }
        let activeBindingIDs = Set(await shortcutCoordinator.registeredBindings().map(\.id))
        var activationErrors: [String] = []
        do {
            try await shortcutCoordinator.upsertScript(script)
            for binding in relatedBindings {
                do {
                    try await shortcutCoordinator.register(binding)
                } catch {
                    activationErrors.append(text.format(
                        "error.startup.shortcut",
                        text.shortcut(binding.shortcut),
                        text.error(error)
                    ))
                }
            }
            if let index = scripts.firstIndex(where: { $0.id == script.id }) {
                scripts[index] = script
            } else {
                scripts.append(script)
            }
            scripts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            try await persist()
            if activationErrors.isEmpty {
                noticeMessage = text("status.scriptSaved")
                errorMessage = nil
            } else {
                show(message: activationErrors.joined(separator: "\n"))
            }
            return script.id
        } catch let originalError {
            scripts = previousScripts
            do {
                for binding in relatedBindings where !activeBindingIDs.contains(binding.id) {
                    await shortcutCoordinator.remove(bindingID: binding.id)
                }
                if let previousScript, previousWasRunnable {
                    try await shortcutCoordinator.upsertScript(previousScript)
                } else {
                    await shortcutCoordinator.removeScript(id: script.id)
                }
            } catch {
                showRollbackFailure(original: originalError, rollback: error)
                return nil
            }
            show(error: originalError)
            return nil
        }
    }

    func removeScript(id: UUID) async {
        guard let script = scripts.first(where: { $0.id == id }) else { return }
        let previousScripts = scripts
        let previousBindings = bindings
        let relatedBindings = bindings.filter { $0.scriptID == id }
        let activeBindingIDs = Set(await shortcutCoordinator.registeredBindings().map(\.id))
        let wasRunnable = (try? scriptEngine.compile(script.source, name: script.name)) != nil
        for binding in relatedBindings { await shortcutCoordinator.remove(bindingID: binding.id) }
        await shortcutCoordinator.removeScript(id: id)
        bindings.removeAll { $0.scriptID == id }
        scripts.removeAll { $0.id == id }
        do {
            try await persist()
            noticeMessage = text("status.scriptRemoved")
            errorMessage = nil
        } catch let originalError {
            scripts = previousScripts
            bindings = previousBindings
            do {
                if wasRunnable {
                    try await shortcutCoordinator.upsertScript(script)
                    for binding in relatedBindings where activeBindingIDs.contains(binding.id) {
                        try await shortcutCoordinator.register(binding)
                    }
                }
            } catch {
                showRollbackFailure(original: originalError, rollback: error)
                return
            }
            show(error: originalError)
        }
    }

    func assign(_ shortcut: GlobalShortcut, to scriptID: UUID) async {
        let binding = ShortcutBinding(shortcut: shortcut, scriptID: scriptID)
        do {
            try await shortcutCoordinator.register(binding)
            bindings.append(binding)
            do {
                try await persist()
            } catch {
                bindings.removeAll { $0.id == binding.id }
                await shortcutCoordinator.remove(bindingID: binding.id)
                throw error
            }
            noticeMessage = text("status.shortcutAssigned")
            errorMessage = nil
        } catch {
            show(error: error)
        }
    }

    @discardableResult
    func updateBinding(id: UUID, shortcut: GlobalShortcut, scriptID: UUID) async -> Bool {
        guard let index = bindings.firstIndex(where: { $0.id == id }) else {
            show(message: text("error.shortcut.bindingMissing"))
            return false
        }
        let previous = bindings[index]
        let replacement = ShortcutBinding(id: id, shortcut: shortcut, scriptID: scriptID)
        let wasRegistered = await shortcutCoordinator.registeredBindings().contains { $0.id == id }
        do {
            try await shortcutCoordinator.register(replacement)
            bindings[index] = replacement
            do {
                try await persist()
            } catch let persistenceError {
                bindings[index] = previous
                if wasRegistered {
                    do {
                        try await shortcutCoordinator.register(previous)
                    } catch {
                        showRollbackFailure(original: persistenceError, rollback: error)
                        return false
                    }
                } else {
                    await shortcutCoordinator.remove(bindingID: id)
                }
                show(message: text.format("error.config.rollback", String(describing: persistenceError)))
                return false
            }
            noticeMessage = text("status.shortcutChanged")
            errorMessage = nil
            return true
        } catch {
            show(error: error)
            return false
        }
    }

    func removeBinding(id: UUID) async {
        guard let binding = bindings.first(where: { $0.id == id }) else { return }
        let previousBindings = bindings
        let wasRegistered = await shortcutCoordinator.registeredBindings().contains { $0.id == id }
        await shortcutCoordinator.remove(bindingID: id)
        bindings.removeAll { $0.id == id }
        do {
            try await persist()
            noticeMessage = text("status.shortcutRemoved")
            errorMessage = nil
        } catch let originalError {
            bindings = previousBindings
            if wasRegistered {
                do {
                    try await shortcutCoordinator.register(binding)
                } catch {
                    showRollbackFailure(original: originalError, rollback: error)
                    return
                }
            }
            show(error: originalError)
        }
    }

    func scriptName(for id: UUID) -> String {
        scripts.first(where: { $0.id == id })?.name ?? text("status.missingScript")
    }

    var text: AppText { AppText(language: language) }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        userDefaults.set(language.rawValue, forKey: AppLanguage.defaultsKey)
        dismissMessages()
    }

    func bindingCount(for scriptID: UUID) -> Int {
        bindings.count { $0.scriptID == scriptID }
    }

    func makeScenarioBuilder() -> ScenarioBuilder {
        ScenarioBuilder(actions: registry, stateProviders: stateProviders)
    }

    func reportEditorError(_ error: any Error) {
        show(error: error)
    }

    func dismissMessages() {
        errorMessage = nil
        noticeMessage = nil
    }

    private func runDisplayAction(_ actionID: ActionID, parameters: ActionParameters) async {
        do {
            let result = try await executor.execute(
                ActionSequence(
                    name: "Display command",
                    steps: [ActionInvocation(actionID: actionID, parameters: parameters)]
                )
            )
            _ = result
            noticeMessage = switch actionID {
            case DisplayActions.setMainID: text("status.display.main")
            case DisplayActions.extendID: text("status.display.extended")
            case DisplayActions.mirrorID: text("status.display.mirrored")
            default: text("status.operationComplete")
            }
            errorMessage = nil
            await refreshDisplays()
        } catch {
            show(error: error)
        }
    }

    private func persist() async throws {
        try await configurationStore.save(AppConfiguration(scripts: scripts, bindings: bindings))
    }

    private func show(error: any Error) {
        show(message: text.error(error))
    }

    private func show(message: String) {
        noticeMessage = nil
        errorMessage = message
    }

    private func showRollbackFailure(original: any Error, rollback: any Error) {
        show(message: text.format(
            "error.transaction.rollbackFailed",
            String(describing: original),
            String(describing: rollback)
        ))
    }

}
