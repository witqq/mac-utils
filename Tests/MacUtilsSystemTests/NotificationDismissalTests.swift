#if !APP_STORE
import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private struct PerformedAction: Equatable {
    let node: String
    let displayName: String
}

/// Fake Notification Center whose tree actually shrinks: performing a dismissal removes that node,
/// the way macOS removes the notification it belongs to.
private actor FakeNotificationCenter: NotificationCenterAccessing {
    private let granted: Bool
    private var windows: [NotificationCenterNode]?
    private let undismissable: Set<String>
    private(set) var performed: [PerformedAction] = []
    private(set) var treeReads = 0

    init(
        granted: Bool = true,
        windows: [NotificationCenterNode]?,
        undismissable: Set<String> = []
    ) {
        self.granted = granted
        self.windows = windows
        self.undismissable = undismissable
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
        if undismissable.contains(handle.identifier) {
            throw NotificationDismissalError.actionFailed(action: actionName, status: -25202)
        }
        windows = windows?.compactMap { Self.removing(handle.identifier, from: $0) }
    }

    private static func removing(
        _ identifier: String,
        from node: NotificationCenterNode
    ) -> NotificationCenterNode? {
        guard node.handle.identifier != identifier else { return nil }
        return NotificationCenterNode(
            role: node.role,
            subrole: node.subrole,
            actionNames: node.actionNames,
            children: node.children.compactMap { removing(identifier, from: $0) },
            handle: node.handle
        )
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
    subrole: "AXNotificationCenterBannerStack",
    actions: ["AXPress", rawAction("Close"), rawAction("Clear All"), rawAction("Show")]
)

/// The shape macOS uses for repeated alerts from one app, observed on macOS 26 for an iTerm2 bell.
private let alertStack = node(
    "alert-stack",
    subrole: "AXNotificationCenterAlertStack",
    actions: ["AXPress", rawAction("Показать детали"), rawAction("Показать"), rawAction("Очистить все")],
    children: [node("title", role: "AXStaticText", actions: ["AXShowMenu"])]
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
func everyNotificationSubroleIncludingStacksIsDismissed() async throws {
    let center = FakeNotificationCenter(windows: [notificationWindow([
        mailAlert,
        messageBanner,
        stackedGroup,
        alertStack,
    ])])

    let report = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()

    #expect(report.dismissedCount == 4)
    #expect(await center.performed == [
        PerformedAction(node: "mail", displayName: "Закрыть"),
        PerformedAction(node: "message", displayName: "Close"),
        PerformedAction(node: "stack", displayName: "Clear All"),
        PerformedAction(node: "alert-stack", displayName: "Очистить все"),
    ])
}

@Test
func aStackNestedBehindAListContainerIsStillFound() async throws {
    // macOS 26 wraps notifications in an AXNotificationListItems group inside the scroll area.
    let list = node("AXNotificationListItems", children: [alertStack])
    let center = FakeNotificationCenter(windows: [notificationWindow([list])])

    let report = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()

    #expect(report.dismissedCount == 1)
    #expect(await center.performed == [
        PerformedAction(node: "alert-stack", displayName: "Очистить все"),
    ])
}

@Test
func anItemStillListedAfterItsDismissalIsNotDismissedOrCountedTwice() async throws {
    // Notification Center keeps reporting an item for a moment after it is removed.
    let center = LaggingNotificationCenter()

    let report = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()

    #expect(report.dismissedCount == 1)
    #expect(await center.performed == ["alert-stack"])
}

@Test
func anItemThatNeverGoesAwayFailsInsteadOfLoopingForever() async throws {
    let center = FakeNotificationCenter(
        windows: [notificationWindow([mailAlert, messageBanner])],
        undismissable: ["message"]
    )

    await #expect(throws: NotificationDismissalError.self) {
        _ = try await NotificationDismisser(access: center, names: FixedNames()).dismissAll()
    }
    #expect(await center.performed.filter { $0.node == "mail" }.count == 1)
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

/// Keeps listing the same stack no matter how often it is dismissed, the way the real tree does
/// while it catches up with the dismissal.
private actor LaggingNotificationCenter: NotificationCenterAccessing {
    private(set) var performed: [String] = []

    func isAccessibilityGranted() async -> Bool { true }

    func windowTree() async throws -> [NotificationCenterNode]? {
        [notificationWindow([alertStack])]
    }

    func perform(actionName: String, on handle: NotificationCenterNodeHandle) async throws {
        performed.append(handle.identifier)
    }
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
