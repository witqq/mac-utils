import AppKit
import Foundation
import MacUtilsCore
import MacUtilsSystem
import SwiftUI

@MainActor
private final class MacUtilsAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var shortcutCoordinator: ShortcutCoordinator?
    private var diagnostics: AppDiagnostics?
    private var model: AppModel?
    private var settingsWindow: NSWindow?
    private let popover = NSPopover()

    private var launchText: AppText {
        let language = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        return AppText(language: language)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
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
        item.button?.toolTip = SystemEnvironment.productName
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: LaunchStatusView(message: launchText("status.loading"))
        )
    }

    private func setUpProductionUI(options: AppLaunchOptions) {
        do {
            let displayManager: any DisplayManaging = options.usesScreenshotFixture
                ? ScreenshotDisplayManager()
                : DisplayController()
            var registry = ActionRegistry()
            try DisplayActions.register(in: &registry, manager: displayManager)
            var stateProviders = StateProviderRegistry()
            try DisplayStateProviders.register(in: &stateProviders, manager: displayManager)
            let coordinator = try ShortcutCoordinator.live(
                registry: registry,
                stateProviders: stateProviders
            )
            let model = AppModel(
                displayManager: displayManager,
                registry: registry,
                stateProviders: stateProviders,
                shortcutCoordinator: coordinator,
                configurationStore: options.configurationURL.map(ConfigurationStore.init(fileURL:))
                    ?? ConfigurationStore(),
                initialLanguage: options.initialLanguage
            )
            shortcutCoordinator = coordinator
            self.model = model
            popover.contentViewController = NSHostingController(
                rootView: MenuBarRootView(model: model) { [weak self] in self?.showSettings() }
            )
            Task {
                await model.start()
                await runUIHooks(options: options, model: model)
            }
        } catch {
            popover.contentViewController = NSHostingController(
                rootView: LaunchStatusView(message: launchText.error(error))
            )
        }
    }

    private func runUIHooks(options: AppLaunchOptions, model: AppModel) async {
        if options.opensSettings {
            showSettings()
            if let captureURL = options.captureURL {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
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

    private func showSettings() {
        guard let model else { return }
        popover.performClose(nil)
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            return
        }

        let options = AppLaunchOptions(arguments: CommandLine.arguments)
        let controller = NSHostingController(
            rootView: SettingsView(
                model: model,
                onboardingOverride: options.onboardingOverride,
                initialTab: options.initialSettingsTab
            )
        )
        let window = NSWindow(contentViewController: controller)
        window.title = model.text("app.settings.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1_000, height: 720))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    private func captureSettings(to url: URL) {
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
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
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

    init(arguments: [String]) {
        configurationURL = Self.value(after: "--configuration-file", in: arguments)
            .map(URL.init(fileURLWithPath:))
        initialLanguage = Self.value(after: "--ui-language", in: arguments)
            .flatMap(AppLanguage.init(rawValue:))
        opensSettings = arguments.contains("--open-settings")
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
