import AppKit
import Foundation
import MacUtilsCore
import MacUtilsSystem

enum DiagnosticRequest: Equatable {
    case configurationWrite(URL)
    case configurationRead(URL)
    case displayAction(name: String, parameters: [String])
    case sandboxEnvironment
    case appSmoke
    case displayProbe
    case hotKeyManual

    static func parse(_ arguments: [String]) throws -> DiagnosticRequest? {
        if arguments.contains("--configuration-write-smoke") {
            guard let path = value(after: "--configuration-write-smoke", in: arguments) else {
                throw DiagnosticError.missingValue("--configuration-write-smoke")
            }
            return .configurationWrite(URL(fileURLWithPath: path))
        }
        if arguments.contains("--configuration-read-smoke") {
            guard let path = value(after: "--configuration-read-smoke", in: arguments) else {
                throw DiagnosticError.missingValue("--configuration-read-smoke")
            }
            return .configurationRead(URL(fileURLWithPath: path))
        }
        if let index = arguments.firstIndex(of: "--execute-display-action") {
            let values = Array(arguments.dropFirst(index + 1))
            guard let name = values.first else { throw DiagnosticError.invalidDisplayAction }
            let parameters = Array(values.dropFirst())
            let isValid = switch name {
            case "main", "extend": parameters.count == 1
            case "mirror": parameters.count == 2
            default: false
            }
            guard isValid else { throw DiagnosticError.invalidDisplayAction }
            return .displayAction(name: name, parameters: parameters)
        }
        if arguments.contains("--sandbox-environment-smoke") { return .sandboxEnvironment }
        if arguments.contains("--smoke-test") { return .appSmoke }
        if arguments.contains("--display-probe") { return .displayProbe }
        if arguments.contains("--hotkey-manual-smoke-test") { return .hotKeyManual }
        return nil
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}

enum DiagnosticError: Error, Equatable, CustomStringConvertible {
    case invalidDisplayAction
    case missingValue(String)
    case configurationRoundTripFailed

    var description: String {
        switch self {
        case .invalidDisplayAction:
            "Use --execute-display-action main UUID | extend UUID | mirror UUID SOURCE_UUID."
        case let .missingValue(flag):
            "Option \(flag) requires a value."
        case .configurationRoundTripFailed:
            "The configuration written by the smoke check could not be loaded."
        }
    }
}

@MainActor
final class AppDiagnostics {
    private var shortcutCoordinator: ShortcutCoordinator?

    func runIfRequested(arguments: [String], statusItemCreated: Bool) -> Bool {
        let request: DiagnosticRequest
        do {
            guard let parsed = try DiagnosticRequest.parse(arguments) else { return false }
            request = parsed
        } catch {
            writeError("Diagnostic argument error: \(error)")
            terminate()
            return true
        }

        switch request {
        case let .configurationWrite(url): runConfigurationWrite(fileURL: url)
        case let .configurationRead(url): runConfigurationRead(fileURL: url)
        case let .displayAction(name, parameters): runDisplayAction(name, parameters: parameters)
        case .sandboxEnvironment: runSandboxEnvironment()
        case .appSmoke:
            print(
                "activationPolicyAccessory=\(NSApplication.shared.activationPolicy() == .accessory) "
                    + "statusItemCreated=\(statusItemCreated)"
            )
            terminate()
        case .displayProbe: runDisplayProbe()
        case .hotKeyManual: runHotKeySmoke()
        }
        return true
    }

    private func runSandboxEnvironment() {
        let fileURL = ConfigurationStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: "sandbox-smoke.json", directoryHint: .notDirectory)
        let store = ConfigurationStore(fileURL: fileURL)
        Task {
            do {
                try await store.save(.empty)
                let loaded = await store.load()
                guard loaded.configuration == .empty, loaded.recoveryError == nil else {
                    throw DiagnosticError.configurationRoundTripFailed
                }
                print(
                    "sandboxEnvironment=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil) "
                        + "configurationRoundTrip=true containerPath=\(fileURL.path)"
                )
            } catch {
                writeError("Sandbox environment smoke failed: \(error)")
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do { try FileManager.default.removeItem(at: fileURL) }
                catch { writeError("Sandbox smoke cleanup failed: \(error)") }
            }
            terminate()
        }
    }

    private func runDisplayProbe() {
        Task {
            do {
                let displays = try await DisplayController().displays()
                print("displayCount=\(displays.count)")
                for display in displays {
                    print(
                        "display id=\(display.id.rawValue) name=\(display.name) "
                            + "active=\(display.isActive) role=\(display.role) "
                            + "frame=\(display.frame.x),\(display.frame.y),"
                            + "\(display.frame.width)x\(display.frame.height)"
                    )
                }
            } catch {
                writeError("Display probe failed: \(error)")
            }
            terminate()
        }
    }

    private func runDisplayAction(_ name: String, parameters: [String]) {
        do {
            let displayManager = DisplayController()
            var registry = ActionRegistry()
            try DisplayActions.register(in: &registry, manager: displayManager)
            let invocation: ActionInvocation
            switch name {
            case "main":
                invocation = ActionInvocation(
                    actionID: DisplayActions.setMainID,
                    parameters: ["display": .string(parameters[0])]
                )
            case "extend":
                invocation = ActionInvocation(
                    actionID: DisplayActions.extendID,
                    parameters: ["display": .string(parameters[0])]
                )
            case "mirror":
                invocation = ActionInvocation(
                    actionID: DisplayActions.mirrorID,
                    parameters: [
                    "display": .string(parameters[0]),
                    "source": .string(parameters[1]),
                    ]
                )
            default:
                writeError("Display action setup failed: unsupported action '\(name)'.")
                terminate()
                return
            }
            let executor = ActionExecutor(registry: registry)
            Task {
                do {
                    let result = try await executor.execute(
                        ActionSequence(name: "Display diagnostic", steps: [invocation])
                    )
                    print("displayActionExecuted=true summary=\(result.steps[0].result.summary)")
                } catch {
                    writeError("Display action failed: \(error)")
                }
                terminate()
            }
        } catch {
            writeError("Display action setup failed: \(error)")
            terminate()
        }
    }

    private func runConfigurationWrite(fileURL: URL) {
        let store = ConfigurationStore(fileURL: fileURL)
        let script = UserScript(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "Persisted smoke script",
            source: "smoke.hotkey"
        )
        let configuration = AppConfiguration(
            scripts: [script],
            bindings: [
                ShortcutBinding(
                    id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                    shortcut: GlobalShortcut(keyCode: 40, modifiers: [.command, .option, .control]),
                    scriptID: script.id
                ),
            ]
        )
        Task {
            do {
                try await store.save(configuration)
                print("configurationSaved=true scripts=1 bindings=1")
            } catch {
                writeError("Configuration write smoke failed: \(error)")
            }
            terminate()
        }
    }

    private func runConfigurationRead(fileURL: URL) {
        let store = ConfigurationStore(fileURL: fileURL)
        Task {
            let result = await store.load()
            let binding = result.configuration.bindings.first
            print(
                "configurationLoaded=\(result.recoveryError == nil) "
                    + "scripts=\(result.configuration.scripts.count) "
                    + "bindings=\(result.configuration.bindings.count) "
                    + "keyCode=\(binding?.shortcut.keyCode ?? 0) "
                    + "modifiers=\(binding?.shortcut.modifiers.rawValue ?? 0)"
            )
            if let error = result.recoveryError {
                writeError("Configuration read smoke recovered: \(error)")
            }
            terminate()
        }
    }

    private func runHotKeySmoke() {
        do {
            var registry = ActionRegistry()
            try registry.register(HotKeySmokeAction())
            let coordinator = try ShortcutCoordinator.live(registry: registry, diagnostics: true)
            shortcutCoordinator = coordinator
            let script = UserScript(name: "Native hotkey smoke", source: "smoke.hotkey")
            let shortcut = GlobalShortcut(keyCode: 40, modifiers: [.command, .option, .control])
            let binding = ShortcutBinding(shortcut: shortcut, scriptID: script.id)

            Task {
                do {
                    try await coordinator.upsertScript(script)
                    try await coordinator.register(binding)
                    print("hotkeyRegistered=true appActiveBeforeEvent=\(NSApplication.shared.isActive)")
                    print("manualHotkey=control-option-command-K")
                    try await Task.sleep(for: .seconds(120))
                    writeError("Hotkey smoke timed out before execution.")
                    terminate()
                } catch is CancellationError {
                    // Successful smoke terminates the process from its action.
                } catch {
                    writeError("Hotkey smoke setup failed: \(error)")
                    terminate()
                }
            }
        } catch {
            writeError("Hotkey smoke setup failed: \(error)")
            terminate()
        }
    }

    private func writeError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
    }

    private func terminate() {
        NSApplication.shared.terminate(nil)
    }
}

private struct HotKeySmokeAction: UtilityAction {
    let metadata = ActionMetadata(
        id: ActionID("smoke.hotkey"),
        name: "Hotkey smoke",
        description: "Reports a safe native global-hotkey smoke event."
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        print("hotkeyScriptExecuted=true")
        Task { @MainActor in NSApplication.shared.terminate(nil) }
        return ActionResult(summary: "Native global hotkey reached the shared script engine.")
    }
}
