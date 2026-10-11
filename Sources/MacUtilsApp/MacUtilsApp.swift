import AppKit
import Combine
import Foundation
import MacUtilsCore
import MacUtilsSystem
import SwiftUI

@MainActor
private final class MacUtilsAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var shortcutCoordinator: ShortcutCoordinator?
    private var diagnostics: AppDiagnostics?
    private var model: AppModel?
    private var settingsWindow: NSWindow?
    private var utilityNavigation: UtilityNavigation?
    private var storageModel: StorageModel?
    private var menuLanguageSubscription: AnyCancellable?
    private let popover = NSPopover()

    private var launchText: AppText {
        let language = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        return AppText(language: language)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.mainMenu = ApplicationMenuFactory.make(text: launchText)
        setUpStatusItem()

        let diagnostics = AppDiagnostics()
        if diagnostics.runIfRequested(
            arguments: CommandLine.arguments,
            statusItemCreated: statusItem?.button != nil
        ) {
            self.diagnostics = diagnostics
            return
        }
        setUpProductionUI(options: AppLaunchOptions(arguments: CommandLine.arguments))
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menuIcon = NSImage(named: "MenuBarIcon")
        menuIcon?.isTemplate = true
        item.button?.image = menuIcon ?? NSImage(
            systemSymbolName: "rectangle.on.rectangle",
            accessibilityDescription: SystemEnvironment.productName
        )
        item.button?.toolTip = launchText("menu.status.help")
        item.button?.setAccessibilityLabel(SystemEnvironment.productName)
        item.button?.setAccessibilityHelp(launchText("menu.status.help"))
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        popover.behavior = .transient
        popover.contentViewController = MenuBarPopover.contentController(
            for: LaunchStatusView(message: launchText("status.loading"))
        )
    }


    private func setUpProductionUI(options: AppLaunchOptions) {
        do {
            let displayManager: any DisplayManaging = options.usesScreenshotFixture
                ? ScreenshotDisplayManager()
                : DisplayController()
            let loginItemManager: any LoginItemManaging = options.usesScreenshotFixture
                ? ScreenshotLoginItemManager()
                : SystemLoginItemManager()
            var registry = ActionRegistry()
            try DisplayActions.register(in: &registry, manager: displayManager)
            #if !APP_STORE
            try UniversalControlActions.register(in: &registry)
            try NotificationActions.register(in: &registry)
            #endif
            var stateProviders = StateProviderRegistry()
            try DisplayStateProviders.register(in: &stateProviders, manager: displayManager)
            let coordinator = if options.usesScreenshotFixture {
                ShortcutCoordinator.inMemoryFixture(
                    registry: registry,
                    stateProviders: stateProviders
                )
            } else {
                try ShortcutCoordinator.live(
                    registry: registry,
                    stateProviders: stateProviders
                )
            }
            let model = AppModel(
                displayManager: displayManager,
                registry: registry,
                stateProviders: stateProviders,
                shortcutCoordinator: coordinator,
                configurationStore: options.configurationURL.map(ConfigurationStore.init(fileURL:))
                    ?? ConfigurationStore(),
                loginItemManager: loginItemManager,
                initialLanguage: options.initialLanguage
            )
            shortcutCoordinator = coordinator
            self.model = model
            menuLanguageSubscription = model.$language.removeDuplicates().sink { [weak self] language in
                Task { @MainActor in
                    let text = AppText(language: language)
                    NSApplication.shared.mainMenu = ApplicationMenuFactory.make(text: text)
                    self?.statusItem?.button?.toolTip = text("menu.status.help")
                    self?.statusItem?.button?.setAccessibilityHelp(text("menu.status.help"))
                }
            }
            popover.contentViewController = MenuBarPopover.contentController(
                for: MenuBarRootView(model: model,
                    onOpenSettings: { [weak self] in self?.showSettings() },
                    onOpenStorage: { [weak self] in self?.showSettings(tab: .storage) })
            )
            Task {
                await model.start()
                await runUIHooks(options: options, model: model)
            }
        } catch {
            popover.contentViewController = MenuBarPopover.contentController(
                for: LaunchStatusView(message: launchText.error(error))
            )
        }
    }

    private func runUIHooks(options: AppLaunchOptions, model: AppModel) async {
        if options.opensSettings {
            showSettings(tab: options.capturesStorageProgress || options.showsStorageTrashConfirmation
                || options.storageInformationSheet != nil ? .storage : nil)
            if let root = options.storageRootURL, let storage = storageModel {
                storage.text = model.text
                await storage.start()
                await storage.selectFolder(root)
                if !storage.isScanning && (options.refreshesStorage
                    || (options.capturesStorageProgress && storage.error == nil)) {
                    storage.refresh()
                }
                if options.capturesStorageProgress, let captureURL = options.captureURL {
                    // Completion/failure is also observed so a short or failed scan cannot leave
                    // this diagnostic waiting forever for a nonzero progress update.
                    for await (progress, scanning) in storage.$progress.combineLatest(storage.$isScanning).values {
                        if !scanning || (progress?.visitedItems ?? 0) > 0 { break }
                    }
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { storage.cancelScan(); return }
                    print("storageCaptureWhileScanning=\(storage.isScanning)")
                    captureSettings(to: captureURL)
                    storage.cancelScan()
                    settingsWindow?.attachedSheet?.orderOut(nil)
                    settingsWindow?.close()
                    NSApplication.shared.terminate(nil)
                    return
                }
                await storage.waitForScan()
                if let metric = options.storageMetric { storage.metric = metric }
                if let path = options.storageExpansionPath { _ = await storage.expand(relativePath: path) }
                if let path = options.storageFolderPath { await storage.focus(relativePath: path) }
                if let mode = options.storageBrowser { storage.browserMode = mode }
                if let path = options.storageSelectionPath { await storage.select(relativePath: path) }
                await storage.waitForScan()
                if options.captureURL != nil {
                    print("storageCaptureTree schema=\(storage.snapshot?.schemaVersion ?? 0) "
                        + "indexedNodes=\(storage.snapshot?.tree?.nodeCount ?? 0) "
                        + "folderID=\(storage.folderID) selected=\(storage.selection.count)")
                }
                if options.showsStorageTrashConfirmation {
                    storage.requestTrashConfirmation()
                }
            }
            if let information = options.storageInformationSheet, let storage = storageModel {
                await storage.start()
                storage.informationSheet = information
            }
            if let captureURL = options.captureURL {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                if options.showsStorageTrashConfirmation {
                    print("storageConfirmationPresented=\(settingsWindow?.attachedSheet != nil)")
                }
                if let information = options.storageInformationSheet {
                    print("storageInformationSheet=\(information.rawValue) presented=\(settingsWindow?.attachedSheet != nil)")
                }
                captureSettings(to: captureURL)
                settingsWindow?.attachedSheet?.orderOut(nil)
                settingsWindow?.close()
                NSApplication.shared.terminate(nil)
                return
            }
        }
        if options.runsUISmoke {
            let countBeforeEvent = model.displayRefreshCount
            do { try await Task.sleep(for: .seconds(20)) }
            catch { return }
            NotificationCenter.default.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            print(
                "uiDisplayEventHandled=\(model.displayRefreshCount > countBeforeEvent) "
                    + "displayCount=\(model.displays.count)"
            )
        }
    }

    private func showSettings(tab: SettingsTab? = nil) {
        guard let model else { return }
        popover.performClose(nil)
        if let settingsWindow {
            if let tab { utilityNavigation?.selectedTab = tab }
            Task { [weak self] in await self?.storageModel?.start() }
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            return
        }

        let options = AppLaunchOptions(arguments: CommandLine.arguments)
        let navigation = UtilityNavigation(selectedTab: tab ?? options.initialSettingsTab)
        let storageService = if options.usesScreenshotFixture, let configuration = options.configurationURL {
            StorageService(grantsURL: configuration.deletingLastPathComponent().appending(path: "storage-grants.json"),
                cacheURL: configuration.deletingLastPathComponent().appending(path: "storage-snapshots.json"))
        } else { StorageService() }
        let storage = StorageModel(service: storageService)
        utilityNavigation = navigation
        storageModel = storage
        let controller = NSHostingController(
            rootView: SettingsView(
                model: model,
                onboardingOverride: options.onboardingOverride,
                initialTab: options.initialSettingsTab,
                navigation: navigation,
                storage: storage
            )
        )
        let window = NSWindow(contentViewController: controller)
        window.title = model.text("app.settings.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = UtilityWindowSize.minimum
        window.setContentSize(NSSize(
            width: max(UtilityWindowSize.minimum.width, options.windowWidth ?? UtilityWindowSize.defaultSize.width),
            height: max(UtilityWindowSize.minimum.height, options.windowHeight ?? UtilityWindowSize.defaultSize.height)
        ))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        storageModel?.stop()
    }

    private func captureSettings(to url: URL) {
        if let window = settingsWindow?.attachedSheet ?? settingsWindow,
           let view = window.contentView {
            view.layoutSubtreeIfNeeded()
            print("uiCaptureGeometry contentLayoutRect=\(window.contentLayoutRect) "
                + "contentViewBounds=\(view.bounds) fittingSize=\(view.fittingSize) "
                + "safeAreaInsets=\(view.safeAreaInsets)")
        }
        guard let window = settingsWindow?.attachedSheet ?? settingsWindow,
              let view = window.contentView,
              let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width * 2),
                pixelsHigh: Int(view.bounds.height * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            print("uiCaptureSucceeded=false")
            return
        }
        representation.size = view.bounds.size
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.wantsLayer = true
        view.layer?.backgroundColor = window.backgroundColor.cgColor
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            print("uiCaptureSucceeded=false")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            print("uiCaptureSucceeded=true path=\(url.path)")
        } catch {
            print("uiCaptureSucceeded=false error=\(error)")
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // An accessory application stays inactive while its popover opens, so the popover window
        // never becomes key and the keyboard cannot reach it, including Escape to close it.
        NSApplication.shared.activate()
        popover.contentViewController?.view.window?.makeKey()
    }
}

enum MenuBarPopover {
    /// Wraps popover content in a hosting controller that publishes its size.
    ///
    /// `NSPopover` places itself next to the status item using its content size. A hosting
    /// controller reports a zero preferred size unless it is asked to publish one, and the popover
    /// then opens as a panel detached from the menu bar icon instead of hanging under it.
    @MainActor
    static func contentController(for view: some View) -> NSHostingController<some View> {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }
}

enum ApplicationMenuFactory {
    @MainActor
    static func make(text: AppText) -> NSMenu {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: text.format("menu.quit", SystemEnvironment.productName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: text("menu.edit"))
        editMenu.addItem(NSMenuItem(
            title: text("menu.undo"),
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        let redoItem = NSMenuItem(
            title: text("menu.redo"),
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: text("menu.cut"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: text("menu.copy"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: text("menu.paste"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem(
            title: text("menu.selectAll"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: text("menu.window"))
        windowMenu.addItem(NSMenuItem(
            title: text("menu.closeWindow"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        windowMenu.addItem(NSMenuItem(
            title: text("menu.minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(NSMenuItem(
            title: text("menu.zoom"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        let fullScreenItem = NSMenuItem(title: text("menu.fullscreen"),
            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        windowMenu.addItem(fullScreenItem)
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        for (menu, keys) in [
            (applicationMenu, ["menu.quit.help"]),
            (editMenu, ["menu.undo.help", "menu.redo.help", "menu.cut.help",
                        "menu.copy.help", "menu.paste.help", "menu.selectAll.help"]),
            (windowMenu, ["menu.closeWindow.help", "menu.minimize.help",
                          "menu.zoom.help", "menu.fullscreen.help"]),
        ] {
            for (item, key) in zip(menu.items.filter { !$0.isSeparatorItem }, keys) {
                item.toolTip = text(key)
            }
        }
        applicationItem.toolTip = text("menu.application.help")
        editItem.toolTip = text("menu.edit.help")
        windowItem.toolTip = text("menu.window.help")

        return mainMenu
    }
}

struct AppLaunchOptions: Equatable {
    let configurationURL: URL?
    let initialLanguage: AppLanguage?
    let opensSettings: Bool
    let captureURL: URL?
    let runsUISmoke: Bool
    let onboardingOverride: Bool?
    let initialSettingsTab: SettingsTab
    let usesScreenshotFixture: Bool
    let storageRootURL: URL?
    let windowWidth: Double?
    let windowHeight: Double?
    let refreshesStorage: Bool
    let storageMetric: StorageSizeMetric?
    let storageBrowser: StorageBrowserMode?
    let storageFolderPath: String?
    let storageExpansionPath: String?
    let storageSelectionPath: String?
    let capturesStorageProgress: Bool
    let showsStorageTrashConfirmation: Bool
    let storageInformationSheet: StorageInformationSheet?

    init(arguments: [String]) {
        configurationURL = Self.value(after: "--configuration-file", in: arguments)
            .map(URL.init(fileURLWithPath:))
        initialLanguage = Self.value(after: "--ui-language", in: arguments)
            .flatMap(AppLanguage.init(rawValue:))
        captureURL = Self.value(after: "--capture-ui", in: arguments)
            .map(URL.init(fileURLWithPath:))
        runsUISmoke = arguments.contains("--ui-smoke-test")
        onboardingOverride = if arguments.contains("--show-onboarding") {
            true
        } else if arguments.contains("--skip-onboarding") {
            false
        } else {
            nil
        }
        initialSettingsTab = Self.value(after: "--settings-tab", in: arguments)
            .flatMap(SettingsTab.init(rawValue:)) ?? .scripts
        usesScreenshotFixture = arguments.contains("--screenshot-fixture")
        storageRootURL = Self.value(after: "--storage-root", in: arguments).map(URL.init(fileURLWithPath:))
        capturesStorageProgress = arguments.contains("--storage-capture-progress")
            && captureURL != nil && storageRootURL != nil
        showsStorageTrashConfirmation = arguments.contains("--storage-show-trash-confirmation")
            && usesScreenshotFixture && storageRootURL != nil && captureURL != nil
        storageInformationSheet = if usesScreenshotFixture && captureURL != nil {
            if arguments.contains("--storage-show-management") { .management }
            else if arguments.contains("--storage-show-access") { .access }
            else { nil }
        } else { nil }
        opensSettings = arguments.contains("--open-settings") || capturesStorageProgress
            || showsStorageTrashConfirmation || storageInformationSheet != nil
        windowWidth = Self.value(after: "--window-width", in: arguments).flatMap(Double.init)
            .flatMap { $0.isFinite && $0 >= UtilityWindowSize.minimum.width && $0 <= UtilityWindowSize.maximum.width ? $0 : nil }
        windowHeight = Self.value(after: "--window-height", in: arguments).flatMap(Double.init)
            .flatMap { $0.isFinite && $0 >= UtilityWindowSize.minimum.height && $0 <= UtilityWindowSize.maximum.height ? $0 : nil }
        refreshesStorage = arguments.contains("--storage-refresh")
        storageMetric = Self.value(after: "--storage-metric", in: arguments).flatMap(StorageSizeMetric.init(rawValue:))
        storageBrowser = Self.value(after: "--storage-browser", in: arguments).flatMap(StorageBrowserMode.init(rawValue:))
        storageFolderPath = Self.value(after: "--storage-folder", in: arguments)
        storageExpansionPath = Self.value(after: "--storage-expand", in: arguments)
        storageSelectionPath = Self.value(after: "--storage-select", in: arguments)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}

private struct LaunchStatusView: View {
    let message: String

    var body: some View {
        Text(message)
            .padding(14)
            .frame(width: 320, alignment: .leading)
    }
}

@main
@MainActor
private enum MacUtilsApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = MacUtilsAppDelegate()
        application.delegate = delegate
        application.run()
        _ = delegate
    }
}
