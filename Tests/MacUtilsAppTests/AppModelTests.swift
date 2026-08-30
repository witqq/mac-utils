import AppKit
import Foundation
import MacUtilsCore
@testable import MacUtilsApp
@testable import MacUtilsSystem
import SwiftUI
import Testing

private actor AppModelDisplayManager: DisplayManaging {
    enum Command: Equatable {
        case main(DisplayID)
        case extended(DisplayID)
        case mirror(DisplayID, DisplayID)
    }

    private var current: [DisplayDescriptor]
    private(set) var commands: [Command] = []

    init(displays: [DisplayDescriptor]) {
        current = displays
    }

    func displays() async throws -> [DisplayDescriptor] { current }
    func setDisplays(_ displays: [DisplayDescriptor]) { current = displays }
    func setMainDisplay(_ display: DisplayID) async throws { commands.append(.main(display)) }
    func setExtendedDisplay(_ display: DisplayID) async throws {
        if let index = current.firstIndex(where: { $0.id == display }) {
            current[index].role = .extended
        }
        commands.append(.extended(display))
    }
    func setMirrorDisplay(_ display: DisplayID, source: DisplayID) async throws {
        if let index = current.firstIndex(where: { $0.id == display }) {
            current[index].role = .mirror(source: source)
        }
        commands.append(.mirror(display, source))
    }
}

private actor AppModelHotKeyRegistrar: GlobalHotKeyRegistering {
    private var nextID: UInt32 = 1
    private var handlers: [HotKeyRegistrationToken: @Sendable () async -> Void] = [:]
    private var shortcuts: [HotKeyRegistrationToken: GlobalShortcut] = [:]
    private var unavailable: Set<GlobalShortcut> = []

    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @Sendable () async -> Void
    ) async throws -> HotKeyRegistrationToken {
        if unavailable.contains(shortcut) {
            throw GlobalHotKeyError.unavailable(shortcut, status: -9878)
        }
        let token = HotKeyRegistrationToken(rawValue: nextID)
        nextID += 1
        handlers[token] = handler
        shortcuts[token] = shortcut
        return token
    }

    func unregister(_ token: HotKeyRegistrationToken) async {
        handlers[token] = nil
        shortcuts[token] = nil
    }

    func trigger(_ shortcut: GlobalShortcut) async {
        guard let token = shortcuts.first(where: { $0.value == shortcut })?.key,
              let handler = handlers[token] else { return }
        await handler()
    }

    func makeUnavailable(_ shortcut: GlobalShortcut) { unavailable.insert(shortcut) }
}

private actor AppModelConfigurationFile: ConfigurationFileAccess {
    enum Failure: Error { case write }
    var data: Data?
    private var failsWrites = false

    func read(from url: URL) async throws -> Data? { data }
    func writeAtomically(_ data: Data, to url: URL) async throws {
        if failsWrites { throw Failure.write }
        self.data = data
    }
    func seed(_ data: Data) { self.data = data }
    func setFailsWrites(_ value: Bool) { failsWrites = value }
}

@MainActor
private final class AppModelLoginItemManager: LoginItemManaging {
    enum Failure: Error { case change }

    var status: LoginItemStatus
    var requestedValues: [Bool] = []
    var opensSettingsCount = 0
    var failsChanges = false
    var statusAfterEnabling: LoginItemStatus = .enabled

    init(status: LoginItemStatus = .notRegistered) {
        self.status = status
    }

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)
        if failsChanges { throw Failure.change }
        status = enabled ? statusAfterEnabling : .notRegistered
    }

    func openSystemSettings() {
        opensSettingsCount += 1
    }
}

private let appMainID = DisplayID("app-main")
private let appSecondID = DisplayID("app-second")

private func appDisplay(_ id: DisplayID, role: DisplayRole, x: Int32 = 0) -> DisplayDescriptor {
    DisplayDescriptor(
        id: id,
        name: id.rawValue,
        frame: DisplayFrame(x: x, y: 0, width: 1920, height: 1080),
        role: role
    )
}

@MainActor
private func makeModel(
    displayManager: AppModelDisplayManager,
    configurationFile: AppModelConfigurationFile = AppModelConfigurationFile(),
    hotKeyRegistrar: AppModelHotKeyRegistrar = AppModelHotKeyRegistrar(),
    loginItemManager: AppModelLoginItemManager = AppModelLoginItemManager()
) throws -> AppModel {
    var registry = ActionRegistry()
    try DisplayActions.register(in: &registry, manager: displayManager)
    var stateProviders = StateProviderRegistry()
    try DisplayStateProviders.register(in: &stateProviders, manager: displayManager)
    let coordinator = ShortcutCoordinator(
        registrar: hotKeyRegistrar,
        registry: registry,
        stateProviders: stateProviders
    )
    let store = ConfigurationStore(
        fileURL: URL(fileURLWithPath: "/app-model-config.json"),
        fileAccess: configurationFile
    )
    let defaults = UserDefaults(suiteName: "AppModelTests-\(UUID().uuidString)")!
    defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
    return AppModel(
        displayManager: displayManager,
        registry: registry,
        stateProviders: stateProviders,
        shortcutCoordinator: coordinator,
        configurationStore: store,
        loginItemManager: loginItemManager,
        userDefaults: defaults
    )
}

@Test @MainActor
func loginItemStateIsReadWithoutSilentlyChangingItAndUserActionsAreForwarded() async throws {
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let loginItems = AppModelLoginItemManager(status: .requiresApproval)
    let model = try makeModel(displayManager: manager, loginItemManager: loginItems)

    await model.start()
    #expect(model.loginItemStatus == .requiresApproval)
    #expect(loginItems.requestedValues.isEmpty)

    model.setLaunchAtLoginEnabled(false)
    #expect(loginItems.requestedValues == [false])
    #expect(model.loginItemStatus == .notRegistered)
    #expect(model.noticeMessage == "Mac Utils will no longer launch when you log in.")

    model.openLoginItemsSettings()
    #expect(loginItems.opensSettingsCount == 1)
}

@Test @MainActor
func loginItemFailureKeepsTheSystemStatusAndShowsALocalizedError() throws {
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let loginItems = AppModelLoginItemManager()
    loginItems.failsChanges = true
    let model = try makeModel(displayManager: manager, loginItemManager: loginItems)

    model.setLaunchAtLoginEnabled(true)

    #expect(model.loginItemStatus == .notRegistered)
    #expect(model.errorMessage?.contains("could not complete the operation") == true)
}

@Test @MainActor
func loginItemEnableSurfacesTheSystemApprovalRequirement() throws {
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let loginItems = AppModelLoginItemManager()
    loginItems.statusAfterEnabling = .requiresApproval
    let model = try makeModel(displayManager: manager, loginItemManager: loginItems)

    model.setLaunchAtLoginEnabled(true)

    #expect(loginItems.requestedValues == [true])
    #expect(model.loginItemStatus == .requiresApproval)
    #expect(model.noticeMessage == "Allow Mac Utils in System Settings to finish enabling automatic launch.")
    #expect(model.errorMessage == nil)
}

@Test @MainActor
func visualToggleSavedAndTriggeredThroughHotkeyReadsCurrentDisplayState() async throws {
    let manager = AppModelDisplayManager(displays: [
        appDisplay(appMainID, role: .main),
        appDisplay(appSecondID, role: .mirror(source: appMainID), x: 0),
    ])
    let registrar = AppModelHotKeyRegistrar()
    let model = try makeModel(displayManager: manager, hotKeyRegistrar: registrar)
    await model.start()
    var builder = model.makeScenarioBuilder()
    let toggleID = try builder.addToggle(DisplayStateProviders.modeID, to: .root)
    try builder.setToggleParameter(
        stepID: toggleID,
        name: "display",
        value: .string(appSecondID.rawValue)
    )
    try builder.setExpectedValue(stepID: toggleID, value: .string("mirror"))
    let extendID = try builder.addAction(DisplayActions.extendID, to: .matching(toggleID: toggleID))
    try builder.setActionParameter(
        stepID: extendID,
        name: "display",
        value: .string(appSecondID.rawValue)
    )
    let mirrorID = try builder.addAction(DisplayActions.mirrorID, to: .otherwise(toggleID: toggleID))
    try builder.setActionParameter(
        stepID: mirrorID,
        name: "display",
        value: .string(appSecondID.rawValue)
    )
    try builder.setActionParameter(
        stepID: mirrorID,
        name: "source",
        value: .string(appMainID.rawValue)
    )
    let savedScriptID = await model.saveScript(
        id: nil,
        name: "Visual toggle",
        source: builder.canonicalDSL(name: "Visual toggle")
    )
    let scriptID = try #require(savedScriptID)
    let shortcut = GlobalShortcut(keyCode: 14, modifiers: [.command, .option, .shift])
    await model.assign(shortcut, to: scriptID)

    await registrar.trigger(shortcut)
    await registrar.trigger(shortcut)

    #expect(await manager.commands == [
        .extended(appSecondID),
        .mirror(appSecondID, appMainID),
    ])
}

@Test @MainActor
func uiModelUsesSharedActionsAndSupportsScriptAndShortcutLifecycle() async throws {
    let manager = AppModelDisplayManager(displays: [
        appDisplay(appMainID, role: .main),
        appDisplay(appSecondID, role: .extended, x: 1920),
    ])
    let model = try makeModel(displayManager: manager)
    await model.start()

    #expect(model.displays.count == 2)
    await model.makeMain(appSecondID)
    #expect(await manager.commands == [.main(appSecondID)])

    #expect(!model.validateScript(name: "Broken", source: "unknown-action"))
    #expect(model.errorMessage?.contains("unavailable action") == true)

    let source = "set-main-display display=\"app-second\""
    let scriptID = await model.saveScript(id: nil, name: "Desk layout", source: source)
    let savedID = try #require(scriptID)
    #expect(model.scripts.map(\.id) == [savedID])

    let shortcut = GlobalShortcut(keyCode: 40, modifiers: [.command, .option, .control])
    await model.assign(shortcut, to: savedID)
    #expect(model.bindings.count == 1)
    #expect(model.bindings.first?.shortcut == shortcut)
    await model.removeBinding(id: try #require(model.bindings.first?.id))
    #expect(model.bindings.isEmpty)
}

@Test @MainActor
func displaySystemNotificationRefreshesThePublishedList() async throws {
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let model = try makeModel(displayManager: manager)
    await model.start()
    await manager.setDisplays([
        appDisplay(appMainID, role: .main),
        appDisplay(appSecondID, role: .extended, x: 1920),
    ])

    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    for _ in 0..<100 where model.displays.count != 2 {
        await Task.yield()
    }

    #expect(model.displays.count == 2)
}

@Test @MainActor
func corruptStoredConfigurationProducesAnErrorAndSafeEmptyState() async throws {
    let file = AppModelConfigurationFile()
    await file.seed(Data("broken".utf8))
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let model = try makeModel(displayManager: manager, configurationFile: file)

    await model.start()

    #expect(model.scripts.isEmpty)
    #expect(model.bindings.isEmpty)
    #expect(model.errorMessage?.contains("damaged") == true)
}

@Test @MainActor
func invalidStoredScriptAndBindingStayEditableAndReactivateAfterCorrection() async throws {
    let file = AppModelConfigurationFile()
    let script = UserScript(name: "Needs correction", source: "unknown-action")
    let shortcut = GlobalShortcut(keyCode: 40, modifiers: [.command, .option])
    let binding = ShortcutBinding(shortcut: shortcut, scriptID: script.id)
    await file.seed(try JSONEncoder().encode(AppConfiguration(
        scripts: [script],
        bindings: [binding]
    )))
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let registrar = AppModelHotKeyRegistrar()
    let model = try makeModel(
        displayManager: manager,
        configurationFile: file,
        hotKeyRegistrar: registrar
    )

    await model.start()
    #expect(model.scripts == [script])
    #expect(model.bindings == [binding])
    #expect(model.errorMessage?.contains("needs to be corrected") == true)

    #expect(await model.saveScript(
        id: script.id,
        name: script.name,
        source: "set-main-display display=\"app-main\""
    ) == script.id)
    await registrar.trigger(shortcut)
    for _ in 0..<100 where await manager.commands.isEmpty { await Task.yield() }
    #expect(await manager.commands == [.main(appMainID)])
}

@Test @MainActor
func unavailableStoredHotkeyStaysEditableWithoutBlockingScriptChanges() async throws {
    let file = AppModelConfigurationFile()
    let script = UserScript(
        name: "Unavailable shortcut",
        source: "set-main-display display=\"app-main\""
    )
    let unavailable = GlobalShortcut(keyCode: 40, modifiers: [.command, .option])
    let replacement = GlobalShortcut(keyCode: 14, modifiers: [.command, .option])
    let binding = ShortcutBinding(shortcut: unavailable, scriptID: script.id)
    await file.seed(try JSONEncoder().encode(AppConfiguration(
        scripts: [script],
        bindings: [binding]
    )))
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let registrar = AppModelHotKeyRegistrar()
    await registrar.makeUnavailable(unavailable)
    let model = try makeModel(
        displayManager: manager,
        configurationFile: file,
        hotKeyRegistrar: registrar
    )

    await model.start()
    #expect(model.bindings == [binding])
    #expect(model.errorMessage?.contains("unavailable") == true)
    #expect(await model.saveScript(
        id: script.id,
        name: "Renamed shortcut",
        source: script.source
    ) == script.id)
    #expect(model.bindings == [binding])
    #expect(await model.updateBinding(id: binding.id, shortcut: replacement, scriptID: script.id))
    await registrar.trigger(replacement)
    for _ in 0..<100 where await manager.commands.isEmpty { await Task.yield() }
    #expect(await manager.commands == [.main(appMainID)])
}

@Test @MainActor
func inactiveStoredHotkeyStillPreventsADuplicateAssignment() async throws {
    let file = AppModelConfigurationFile()
    let script = UserScript(
        name: "Stored conflicts",
        source: "set-main-display display=\"app-main\""
    )
    let first = GlobalShortcut(keyCode: 40, modifiers: [.command, .option])
    let unavailable = GlobalShortcut(keyCode: 14, modifiers: [.command, .option])
    let firstBinding = ShortcutBinding(shortcut: first, scriptID: script.id)
    let unavailableBinding = ShortcutBinding(shortcut: unavailable, scriptID: script.id)
    await file.seed(try JSONEncoder().encode(AppConfiguration(
        scripts: [script],
        bindings: [firstBinding, unavailableBinding]
    )))
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let registrar = AppModelHotKeyRegistrar()
    await registrar.makeUnavailable(unavailable)
    let model = try makeModel(
        displayManager: manager,
        configurationFile: file,
        hotKeyRegistrar: registrar
    )
    await model.start()

    #expect(!(await model.updateBinding(
        id: firstBinding.id,
        shortcut: unavailable,
        scriptID: script.id
    )))

    #expect(model.bindings.first(where: { $0.id == firstBinding.id })?.shortcut == first)
    #expect(model.errorMessage?.contains("already assigned") == true)
}

@Test @MainActor
func editingAHotkeyReusesTheBindingAndPersistsTheReplacement() async throws {
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let registrar = AppModelHotKeyRegistrar()
    let model = try makeModel(displayManager: manager, hotKeyRegistrar: registrar)
    await model.start()
    let scriptID = try #require(await model.saveScript(
        id: nil,
        name: "Edit binding",
        source: "set-main-display display=\"app-main\""
    ))
    let first = GlobalShortcut(keyCode: 40, modifiers: [.command, .option])
    let replacement = GlobalShortcut(keyCode: 14, modifiers: [.command, .option])
    await model.assign(first, to: scriptID)
    let bindingID = try #require(model.bindings.first?.id)

    #expect(await model.updateBinding(id: bindingID, shortcut: replacement, scriptID: scriptID))

    #expect(model.bindings == [ShortcutBinding(id: bindingID, shortcut: replacement, scriptID: scriptID)])
}

@Test @MainActor
func conflictingHotkeyEditKeepsThePreviousBindingActive() async throws {
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let registrar = AppModelHotKeyRegistrar()
    let model = try makeModel(displayManager: manager, hotKeyRegistrar: registrar)
    await model.start()
    let scriptID = try #require(await model.saveScript(
        id: nil,
        name: "Conflict",
        source: "set-main-display display=\"app-main\""
    ))
    let first = GlobalShortcut(keyCode: 40, modifiers: [.command, .option])
    let occupied = GlobalShortcut(keyCode: 14, modifiers: [.command, .option])
    await model.assign(first, to: scriptID)
    await model.assign(occupied, to: scriptID)
    let firstBinding = try #require(model.bindings.first(where: { $0.shortcut == first }))

    #expect(!(await model.updateBinding(id: firstBinding.id, shortcut: occupied, scriptID: scriptID)))

    #expect(model.bindings.first(where: { $0.id == firstBinding.id })?.shortcut == first)
    #expect(model.errorMessage?.contains("previous shortcut is still active") == true)
}

@Test @MainActor
func failedPersistenceRollsAHotkeyEditBackInRuntimeAndModel() async throws {
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let registrar = AppModelHotKeyRegistrar()
    let file = AppModelConfigurationFile()
    let model = try makeModel(displayManager: manager, configurationFile: file, hotKeyRegistrar: registrar)
    await model.start()
    let scriptID = try #require(await model.saveScript(
        id: nil,
        name: "Rollback",
        source: "set-main-display display=\"app-main\""
    ))
    let first = GlobalShortcut(keyCode: 40, modifiers: [.command, .option])
    let replacement = GlobalShortcut(keyCode: 14, modifiers: [.command, .option])
    await model.assign(first, to: scriptID)
    let bindingID = try #require(model.bindings.first?.id)
    await file.setFailsWrites(true)

    #expect(!(await model.updateBinding(id: bindingID, shortcut: replacement, scriptID: scriptID)))

    #expect(model.bindings.first?.shortcut == first)
    await registrar.trigger(first)
    for _ in 0..<100 where await manager.commands.isEmpty { await Task.yield() }
    #expect(await manager.commands == [.main(appMainID)])
}

@Test @MainActor
func failedRuntimeRollbackIsSurfacedInsteadOfBeingHidden() async throws {
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    let registrar = AppModelHotKeyRegistrar()
    let file = AppModelConfigurationFile()
    let model = try makeModel(displayManager: manager, configurationFile: file, hotKeyRegistrar: registrar)
    await model.start()
    let scriptID = try #require(await model.saveScript(
        id: nil,
        name: "Rollback failure",
        source: "set-main-display display=\"app-main\""
    ))
    let first = GlobalShortcut(keyCode: 40, modifiers: [.command, .option])
    let replacement = GlobalShortcut(keyCode: 14, modifiers: [.command, .option])
    await model.assign(first, to: scriptID)
    let bindingID = try #require(model.bindings.first?.id)
    await registrar.makeUnavailable(first)
    await file.setFailsWrites(true)

    #expect(!(await model.updateBinding(id: bindingID, shortcut: replacement, scriptID: scriptID)))
    #expect(model.errorMessage?.contains("Restart Mac Utils") == true)
}

@Test @MainActor
func englishAndRussianCatalogsLocalizeUIActionsProvidersAndErrors() async throws {
    let english = AppText(language: .english)
    let russian = AppText(language: .russian)
    let manager = AppModelDisplayManager(displays: [appDisplay(appMainID, role: .main)])
    var actions = ActionRegistry()
    try DisplayActions.register(in: &actions, manager: manager)
    var providers = StateProviderRegistry()
    try DisplayStateProviders.register(in: &providers, manager: manager)
    let action = try #require(actions.metadata.first(where: { $0.id == DisplayActions.extendID }))
    let provider = try #require(providers.metadata.first(where: { $0.id == DisplayStateProviders.modeID }))

    #expect(english("help.title") == "How Mac Utils works")
    #expect(russian("help.title") == "Как работает Mac Utils")
    #expect(english.actionName(action) == "Extend display")
    #expect(russian.actionName(action) == "Расширить дисплей")
    #expect(english.providerName(provider) == "Display Mode")
    #expect(russian.providerName(provider) == "Режим дисплея")
    #expect(russian.error(ShortcutCoordinatorError.shortcutConflict(existingBindingID: UUID()))
        .contains("Прежняя горячая клавиша продолжает работать"))
    #expect(russian.error(ScriptDiagnostic(
        line: 2,
        column: 4,
        reason: .toggleMarkerRequired("@otherwise")
    )) == "Строка 2, столбец 4: Для переключения по состоянию требуется маркер «@otherwise».")
}

@Test
func localizationCatalogsHaveMatchingCompleteKeysAndFormatArguments() throws {
    let english = try AppText.localizationCatalog(for: .english)
    let russian = try AppText.localizationCatalog(for: .russian)

    #expect(Set(english.keys) == Set(russian.keys))
    #expect(english.values.allSatisfy { !$0.isEmpty })
    #expect(russian.values.allSatisfy { !$0.isEmpty })
    for key in english.keys {
        #expect(formatSpecifiers(in: english[key] ?? "") == formatSpecifiers(in: russian[key] ?? ""))
    }
}

private func formatSpecifiers(in value: String) -> [String] {
    value.matches(of: /%(?:\d+\$)?(?:@|d)/).map { String($0.output) }
}

@Test @MainActor
func releaseUISurfacesRenderForEnglishAndRussianIncludingOnboarding() async throws {
    let manager = AppModelDisplayManager(displays: [
        appDisplay(appMainID, role: .main),
        appDisplay(appSecondID, role: .extended, x: 1920),
    ])
    let file = AppModelConfigurationFile()
    let script = UserScript(name: "Display toggle", source: "set-main-display display=\"app-main\"")
    let binding = ShortcutBinding(
        shortcut: GlobalShortcut(keyCode: 40, modifiers: [.command, .option]),
        scriptID: script.id
    )
    let encoder = JSONEncoder()
    await file.seed(try encoder.encode(AppConfiguration(scripts: [script], bindings: [binding])))
    let model = try makeModel(displayManager: manager, configurationFile: file)
    await model.start()

    let menuData = try snapshot(
        MenuBarRootView(model: model, onOpenSettings: {}),
        size: NSSize(width: 390, height: 420)
    )
    #expect(menuData.count > 10_000)

    for (language, tab) in [
        (AppLanguage.english, SettingsTab.general),
        (AppLanguage.english, SettingsTab.scripts),
        (.english, .shortcuts),
        (.russian, .help),
        (.russian, .general),
    ] {
        model.setLanguage(language)
        let data = try snapshot(
            SettingsView(model: model, onboardingOverride: false, initialTab: tab),
            size: NSSize(width: 1_000, height: 720)
        )
        #expect(data.count > 20_000)
    }

    model.setLanguage(.russian)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 720),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = NSHostingView(
        rootView: SettingsView(model: model, onboardingOverride: true, initialTab: .scripts)
    )
    window.orderFront(nil)
    for _ in 0..<20 where window.attachedSheet == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let onboardingView = try #require(window.attachedSheet?.contentView)
    let onboardingData = try snapshot(view: onboardingView)
    #expect(onboardingData.count > 15_000)
    window.close()
}

@MainActor
private func snapshot<Content: SwiftUI.View>(_ content: Content, size: NSSize) throws -> Data {
    let view = NSHostingView(rootView: content)
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    return try snapshot(view: view)
}

@MainActor
private func snapshot(view: NSView) throws -> Data {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    view.layoutSubtreeIfNeeded()
    let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: representation)
    return try #require(representation.representation(using: .png, properties: [:]))
}

@Test
func diagnosticAndUITestLaunchArgumentsAreParsedWithoutAProductionCodePath() throws {
    let writeURL = URL(fileURLWithPath: "/tmp/mac-utils-diagnostic.json")
    #expect(try DiagnosticRequest.parse([
        "Mac Utils", "--configuration-write-smoke", writeURL.path,
    ]) == .configurationWrite(writeURL))
    #expect(try DiagnosticRequest.parse([
        "Mac Utils", "--execute-display-action", "mirror", "secondary", "main",
    ]) == .displayAction(name: "mirror", parameters: ["secondary", "main"]))
    #expect(throws: DiagnosticError.invalidDisplayAction) {
        try DiagnosticRequest.parse(["Mac Utils", "--execute-display-action", "mirror", "secondary"])
    }
    #expect(throws: DiagnosticError.missingValue("--configuration-read-smoke")) {
        try DiagnosticRequest.parse(["Mac Utils", "--configuration-read-smoke"])
    }
    #expect(try DiagnosticRequest.parse(["Mac Utils"]) == nil)
    #expect(try DiagnosticRequest.parse([
        "Mac Utils", "--hotkey-manual-smoke-test",
    ]) == .hotKeyManual)

    let options = AppLaunchOptions(arguments: [
        "Mac Utils",
        "--open-settings",
        "--skip-onboarding",
        "--ui-language", "russian",
        "--settings-tab", "help",
        "--configuration-file", writeURL.path,
        "--screenshot-fixture",
    ])
    #expect(options.configurationURL == writeURL)
    #expect(options.initialLanguage == .russian)
    #expect(options.opensSettings)
    #expect(options.onboardingOverride == false)
    #expect(options.initialSettingsTab == .help)
    #expect(options.usesScreenshotFixture)
}

@Test
func documentedUserGuideDSLExamplesCompileWithTheRealScenarioEngine() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let manager = AppModelDisplayManager(displays: [])
    var actions = ActionRegistry()
    try DisplayActions.register(in: &actions, manager: manager)
    var providers = StateProviderRegistry()
    try DisplayStateProviders.register(in: &providers, manager: manager)
    let engine = ScenarioScriptEngine(actions: actions, stateProviders: providers)
    let guideURLs = [
        projectRoot.appending(path: "docs/USER_GUIDE.md"),
        projectRoot.appending(path: "docs/USER_GUIDE.ru.md"),
    ]
    var examples: [String] = []
    for url in guideURLs {
        examples.append(contentsOf: fencedTextBlocks(in: try String(contentsOf: url, encoding: .utf8)))
    }

    #expect(examples.count == 4)
    for (index, example) in examples.enumerated() {
        _ = try engine.compile(example, name: "Documented example \(index + 1)")
    }
}

private func fencedTextBlocks(in markdown: String) -> [String] {
    var blocks: [String] = []
    var lines: [String] = []
    var isInsideTextBlock = false
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line == "```text" {
            isInsideTextBlock = true
            lines = []
        } else if line == "```", isInsideTextBlock {
            blocks.append(lines.joined(separator: "\n"))
            isInsideTextBlock = false
        } else if isInsideTextBlock {
            lines.append(line)
        }
    }
    return blocks
}

@Test @MainActor
func shortcutRecorderCapturesAModifiedKeyEventAndPublishesItsValue() throws {
    let button = ShortcutCaptureButton()
    button.text = AppText(language: .english)
    var captured: GlobalShortcut?
    button.onShortcut = { captured = $0 }
    button.beginRecording()
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .option],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "e",
        charactersIgnoringModifiers: "e",
        isARepeat: false,
        keyCode: 14
    ))

    button.keyDown(with: event)

    #expect(captured == GlobalShortcut(keyCode: 14, modifiers: [.command, .option]))
    #expect(button.accessibilityValue() as? String == "⌥⌘E")
}
