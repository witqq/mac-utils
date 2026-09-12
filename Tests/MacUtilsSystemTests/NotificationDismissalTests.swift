#if !APP_STORE
import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private struct PerformedAction: Equatable {
    let node: String
    let displayName: String
}

private actor FakeNotificationCenter: NotificationCenterAccessing {
    private let granted: Bool
    private let windows: [NotificationCenterNode]?
    private(set) var performed: [PerformedAction] = []
    private(set) var treeReads = 0

    init(granted: Bool = true, windows: [NotificationCenterNode]?) {
        self.granted = granted
        self.windows = windows
    }

    func isAccessibilityGranted() async -> Bool { granted }

    func windowTree() async throws -> [NotificationCenterNode]? {
        treeReads += 1
        return windows
    }

    func perform(actionName: String, on handle: NotificationCenterNodeHandle) async throws {
        performed.append(PerformedAction(
            node: handle.identifier,
            displayName: NotificationDismisser.displayName(ofRawActionName: actionName) ?? actionName
        ))
    }
}

private struct FixedNames: NotificationActionNaming {
    let closeNames: Set<String> = ["Close", "Закрыть"]
    let clearAllNames: Set<String> = ["Clear All", "Очистить все"]
}

private func rawAction(_ name: String) -> String {
    "Name:\(name)\nTarget:0x0\nSelector:(null)"
}

private func node(
    _ id: String,
    role: String = "AXGroup",
    subrole: String? = nil,
    actions: [String] = [],
    children: [NotificationCenterNode] = []
) -> NotificationCenterNode {
    NotificationCenterNode(
        role: role,
        subrole: subrole,
        actionNames: actions,
        children: children,
        handle: NotificationCenterNodeHandle(id)
    )
}

/// Mirrors the tree observed on macOS 26: window → hosting group → group → scroll area → banners.
private func notificationWindow(_ notifications: [NotificationCenterNode]) -> NotificationCenterNode {
    node(
        "window",
        role: "AXWindow",
        subrole: "AXSystemDialog",
        actions: ["AXRaise"],
        children: [
            node("hosting", subrole: "AXHostingView", children: [
                node("content", children: [
                    node("scroll", role: "AXScrollArea", actions: ["AXScrollUpByPage"], children: notifications),
                    node("widgets", children: []),
                ]),
            ]),
        ]
    )
}

private let mailAlert = node(
    "mail",
    subrole: "AXNotificationCenterAlert",
    actions: ["AXPress", rawAction("Показать"), rawAction("Закрыть")],
    children: [node("title", role: "AXStaticText", actions: ["AXShowMenu"])]
)

private let messageBanner = node(
    "message",
    subrole: "AXNotificationCenterBanner",
    actions: ["AXPress", rawAction("Show Details"), rawAction("Show"), rawAction("Close")]
)

private let stackedGroup = node(
    "stack",
    subrole: "AXNotificationCenterBanner",
    actions: ["AXPress", rawAction("Close"), rawAction("Clear All"), rawAction("Show")]
)

@Test
func bannersAndAlertsAreClosedThroughTheirLocalizedCloseAction() async throws {
    let center = FakeNotificationCenter(windows: [notificationWindow([mailAlert, messageBanner])])

    let report = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()

    #expect(report.dismissedCount == 2)
    #expect(await center.performed == [
        PerformedAction(node: "mail", displayName: "Закрыть"),
        PerformedAction(node: "message", displayName: "Close"),
    ])
}

@Test
func stackedGroupPrefersClearAllOverClose() async throws {
    let center = FakeNotificationCenter(windows: [notificationWindow([stackedGroup])])

    let report = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()

    #expect(report.dismissedCount == 1)
    #expect(await center.performed == [PerformedAction(node: "stack", displayName: "Clear All")])
}

@Test
func groupsThatAreNotNotificationsAreLeftAlone() async throws {
    let pressable = node("other", actions: ["AXPress", rawAction("Close")])
    let noCloseAction = node("stale", subrole: "AXNotificationCenterBanner", actions: ["AXPress"])
    let center = FakeNotificationCenter(windows: [notificationWindow([pressable, noCloseAction])])

    let report = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()

    #expect(report.dismissedCount == 0)
    #expect(await center.performed.isEmpty)
}

@Test
func emptyNotificationCenterReportsZeroWithoutFailing() async throws {
    let center = FakeNotificationCenter(windows: [notificationWindow([])])

    let report = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()

    #expect(report == NotificationDismissalReport(dismissedCount: 0))
}

@Test
func missingAccessibilityPermissionFailsBeforeReadingTheTree() async throws {
    let center = FakeNotificationCenter(granted: false, windows: [notificationWindow([mailAlert])])

    await #expect(throws: NotificationDismissalError.accessibilityNotGranted) {
        _ = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()
    }
    #expect(await center.treeReads == 0)
    #expect(await center.performed.isEmpty)
}

@Test
func absentNotificationCenterProcessIsReportedAsNotRunning() async throws {
    let center = FakeNotificationCenter(windows: nil)

    await #expect(throws: NotificationDismissalError.notificationCenterNotRunning) {
        _ = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()
    }
}

@Test
func rawActionNamesAreReducedToTheirDisplayName() {
    #expect(NotificationDismisser.displayName(ofRawActionName: rawAction("Clear All")) == "Clear All")
    #expect(NotificationDismisser.displayName(ofRawActionName: "Name:Close") == "Close")
    #expect(NotificationDismisser.displayName(ofRawActionName: "AXPress") == nil)
    #expect(NotificationDismisser.displayName(ofRawActionName: "Name:") == nil)
}

@Test
func systemActionNamesIncludeTheBuiltInFallbacksAndAnyReadableLocalizations() throws {
    let missingTable = NotificationCenterActionNames(tablePath: "/nonexistent/Localizable.loctable")
    #expect(missingTable.closeNames.isSuperset(of: ["Close", "Закрыть"]))
    #expect(missingTable.clearAllNames.isSuperset(of: ["Clear All", "Очистить все"]))

    let table: [String: [String: String]] = [
        "de": ["Close": "Schließen", "Clear All": "Alle löschen"],
        "fr": ["Close": "Fermer"],
    ]
    let url = FileManager.default.temporaryDirectory
        .appending(path: "mac-utils-\(UUID().uuidString).loctable")
    try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
        .write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let names = NotificationCenterActionNames(tablePath: url.path)
    #expect(names.closeNames.isSuperset(of: ["Close", "Schließen", "Fermer"]))
    #expect(names.clearAllNames.contains("Alle löschen"))
}

private actor FakeDismisser: NotificationDismissing {
    private(set) var calls = 0

    func dismissAll() async throws -> NotificationDismissalReport {
        calls += 1
        return NotificationDismissalReport(dismissedCount: 3)
    }
}

private actor DismissHotKeyRegistrar: GlobalHotKeyRegistering {
    private var nextToken: UInt32 = 1
    private var handlers: [GlobalShortcut: @Sendable () async -> Void] = [:]

    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @Sendable () async -> Void
    ) async throws -> HotKeyRegistrationToken {
        let token = HotKeyRegistrationToken(rawValue: nextToken)
        nextToken += 1
        handlers[shortcut] = handler
        return token
    }

    func unregister(_ token: HotKeyRegistrationToken) async {}

    func trigger(_ shortcut: GlobalShortcut) async {
        await handlers[shortcut]?()
    }
}

@Test
func actionRegistersWithoutParametersAndReportsTheDismissedCount() async throws {
    let dismisser = FakeDismisser()
    var registry = ActionRegistry()
    try NotificationActions.register(in: &registry, dismisser: dismisser)
    let action = try #require(registry.action(for: NotificationActions.dismissID))

    #expect(action.metadata.parameters.isEmpty)
    let result = try await action.execute(parameters: [:], context: ActionContext())
    #expect(result.values["dismissedCount"] == .integer(3))
    #expect(await dismisser.calls == 1)
}

@Test
func repeatedGlobalHotKeyDismissesNotificationsEveryTime() async throws {
    let dismisser = FakeDismisser()
    var registry = ActionRegistry()
    try NotificationActions.register(in: &registry, dismisser: dismisser)
    let registrar = DismissHotKeyRegistrar()
    let coordinator = ShortcutCoordinator(registrar: registrar, registry: registry)
    let script = UserScript(name: "Dismiss", source: NotificationActions.dismissID.rawValue)
    let shortcut = GlobalShortcut(keyCode: 45, modifiers: [.command, .option])
    let binding = ShortcutBinding(shortcut: shortcut, scriptID: script.id)

    try await coordinator.upsertScript(script)
    try await coordinator.register(binding)
    await registrar.trigger(shortcut)
    await registrar.trigger(shortcut)

    #expect(await dismisser.calls == 2)
    #expect(await coordinator.lastExecution == ShortcutExecutionEvent(
        bindingID: binding.id,
        status: .succeeded(stepCount: 1)
    ))
}
#endif
