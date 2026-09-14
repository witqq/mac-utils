#if !APP_STORE
import AppKit
import ApplicationServices
import Foundation
import MacUtilsCore

/// One node of the Notification Center accessibility tree, reduced to what dismissal needs.
struct NotificationCenterNode: Sendable {
    let role: String
    let subrole: String?
    /// Raw accessibility action names, for example `AXPress` or
    /// `Name:Close\nTarget:0x0\nSelector:(null)`.
    let actionNames: [String]
    let children: [NotificationCenterNode]
    /// Opaque handle the source uses to perform an action on this node.
    let handle: NotificationCenterNodeHandle

    init(
        role: String,
        subrole: String?,
        actionNames: [String],
        children: [NotificationCenterNode],
        handle: NotificationCenterNodeHandle
    ) {
        self.role = role
        self.subrole = subrole
        self.actionNames = actionNames
        self.children = children
        self.handle = handle
    }
}

/// Identifies a node for the source that produced it. The live source keeps the accessibility
/// element itself so an action targets exactly the node that was inspected, even after earlier
/// notifications in the same window were dismissed.
final class NotificationCenterNodeHandle: Hashable, @unchecked Sendable {
    let identifier: String
    let element: AXUIElement?

    init(_ identifier: String, element: AXUIElement? = nil) {
        self.identifier = identifier
        self.element = element
    }

    static func == (lhs: NotificationCenterNodeHandle, rhs: NotificationCenterNodeHandle) -> Bool {
        lhs.identifier == rhs.identifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

public enum NotificationDismissalError: Error, Equatable, Sendable, CustomStringConvertible {
    case accessibilityNotGranted
    case notificationCenterNotRunning
    case actionFailed(action: String, status: Int32)

    public var description: String {
        switch self {
        case .accessibilityNotGranted:
            "Mac Utils needs Accessibility access to close notifications. "
                + "Allow Mac Utils in System Settings → Privacy & Security → Accessibility and run the action again."
        case .notificationCenterNotRunning:
            "Notification Center is not running, so there are no notifications to close."
        case let .actionFailed(action, status):
            "Notification Center rejected the '\(action)' action (accessibility status \(status))."
        }
    }
}

/// Supplies the Notification Center accessibility tree and performs actions on its nodes.
protocol NotificationCenterAccessing: Sendable {
    /// Returns `false` when the process lacks Accessibility permission; may prompt the user.
    func isAccessibilityGranted() async -> Bool
    /// Returns `nil` when the Notification Center process is not running.
    func windowTree() async throws -> [NotificationCenterNode]?
    func perform(actionName: String, on handle: NotificationCenterNodeHandle) async throws
}

/// Supplies the localized names Notification Center uses for its dismissal actions.
protocol NotificationActionNaming: Sendable {
    /// Every localization of the "Close" action name.
    var closeNames: Set<String> { get }
    /// Every localization of the "Clear All" action name.
    var clearAllNames: Set<String> { get }
}

struct NotificationDismissalReport: Equatable, Sendable {
    /// Number of dismissed Notification Center items. A stack of repeated notifications from one
    /// application is one item, because macOS removes the whole stack with a single action.
    let dismissedCount: Int
}

protocol NotificationDismissing: Sendable {
    func dismissAll() async throws -> NotificationDismissalReport
}

/// Walks the Notification Center windows and dismisses every banner, alert and stack.
struct NotificationDismisser: NotificationDismissing {
    /// Every Notification Center subrole that stands for a dismissable notification. macOS groups
    /// repeated notifications from one application into a stack, which carries its own subrole and
    /// is dismissed as a whole. `AXNotificationCenterNextFocus` is a focus helper rather than a
    /// notification and is deliberately absent.
    static let notificationSubroles: Set<String> = [
        "AXNotificationCenterAlert",
        "AXNotificationCenterAlertStack",
        "AXNotificationCenterBanner",
        "AXNotificationCenterBannerStack",
    ]

    /// Dismissing one element rearranges the remaining ones, so the tree is re-read between passes
    /// instead of acting on elements that may no longer exist.
    private static let maximumPasses = 8

    /// Notification Center updates its accessibility tree shortly after an item goes away, so a
    /// pass waits before asking what is left. Without the pause the same item is seen as remaining.
    private static let settleDelay = Duration.milliseconds(250)

    private struct DismissalTarget {
        let handle: NotificationCenterNodeHandle
        let actionName: String
    }

    private let access: any NotificationCenterAccessing
    private let names: any NotificationActionNaming

    init(access: any NotificationCenterAccessing, names: any NotificationActionNaming) {
        self.access = access
        self.names = names
    }

    func dismissAll() async throws -> NotificationDismissalReport {
        guard await access.isAccessibilityGranted() else {
            throw NotificationDismissalError.accessibilityNotGranted
        }

        var dismissed = 0
        var remainingBeforePass = Int.max
        for _ in 0 ..< Self.maximumPasses {
            try Task.checkCancellation()
            guard let windows = try await access.windowTree() else {
                throw NotificationDismissalError.notificationCenterNotRunning
            }

            // Stop once nothing is left, and also once a pass stops shortening the list: repeating
            // the same action on the same items would inflate the count without removing anything.
            let targets = windows.flatMap(dismissalTargets(in:))
            guard !targets.isEmpty, targets.count < remainingBeforePass else { break }
            remainingBeforePass = targets.count

            var dismissedInPass = 0
            var failure: (any Error)?
            for target in targets {
                try Task.checkCancellation()
                do {
                    try await access.perform(actionName: target.actionName, on: target.handle)
                    dismissedInPass += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failure = error
                }
            }

            dismissed += dismissedInPass
            if dismissedInPass == 0 {
                if let failure { throw failure }
                break
            }
            try await Task.sleep(for: Self.settleDelay)
        }
        return NotificationDismissalReport(dismissedCount: dismissed)
    }

    private func dismissalTargets(in node: NotificationCenterNode) -> [DismissalTarget] {
        if node.role == "AXGroup",
           let subrole = node.subrole,
           Self.notificationSubroles.contains(subrole),
           let actionName = dismissalAction(in: node.actionNames) {
            return [DismissalTarget(handle: node.handle, actionName: actionName)]
        }
        return node.children.flatMap(dismissalTargets(in:))
    }

    /// Picks the raw action name whose display name is a localized "Clear All" or "Close".
    /// "Clear All" wins because a stacked group exposes both and only "Clear All" removes
    /// every notification in it.
    private func dismissalAction(in actionNames: [String]) -> String? {
        let named = actionNames.compactMap { raw -> (raw: String, name: String)? in
            guard let name = Self.displayName(ofRawActionName: raw) else { return nil }
            return (raw, name)
        }
        if let clearAll = named.first(where: { names.clearAllNames.contains($0.name) }) {
            return clearAll.raw
        }
        return named.first(where: { names.closeNames.contains($0.name) })?.raw
    }

    static func displayName(ofRawActionName raw: String) -> String? {
        guard raw.hasPrefix("Name:") else { return nil }
        let body = raw.dropFirst("Name:".count)
        let name = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(body)
        return name.isEmpty ? nil : name
    }
}

/// Reads the localized "Close" and "Clear All" names from the Notification Center bundle so the
/// dismissal works in every system language, and falls back to built-in English and Russian.
struct NotificationCenterActionNames: NotificationActionNaming {
    static let defaultTablePath =
        "/System/Library/CoreServices/NotificationCenter.app/Contents/Resources/Localizable.loctable"

    let closeNames: Set<String>
    let clearAllNames: Set<String>

    init(tablePath: String = NotificationCenterActionNames.defaultTablePath) {
        var close: Set<String> = ["Close", "Закрыть"]
        var clearAll: Set<String> = ["Clear All", "Очистить все"]
        if let data = FileManager.default.contents(atPath: tablePath),
           let table = try? PropertyListSerialization.propertyList(from: data, format: nil)
           as? [String: [String: Any]] {
            for localization in table.values {
                if let value = localization["Close"] as? String { close.insert(value) }
                if let value = localization["Clear All"] as? String { clearAll.insert(value) }
            }
        }
        closeNames = close
        clearAllNames = clearAll
    }
}

/// Live accessibility access to the Notification Center process.
struct AccessibilityNotificationCenter: NotificationCenterAccessing {
    private static let bundleIdentifier = "com.apple.notificationcenterui"
    private static let maximumDepth = 12

    func isAccessibilityGranted() async -> Bool {
        // The option key is the constant string "AXTrustedCheckOptionPrompt"; the exported
        // `kAXTrustedCheckOptionPrompt` global is not concurrency-safe under strict checking.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func windowTree() async throws -> [NotificationCenterNode]? {
        let processID = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
                .first?.processIdentifier
        }
        guard let processID else { return nil }
        let application = AXUIElementCreateApplication(processID)
        let windows = Self.attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] ?? []
        return windows.enumerated().map { index, window in
            Self.node(for: window, path: "\(index)", depth: 0)
        }
    }

    func perform(actionName: String, on handle: NotificationCenterNodeHandle) async throws {
        guard let element = handle.element else {
            throw NotificationDismissalError.actionFailed(
                action: actionName,
                status: Int32(AXError.invalidUIElement.rawValue)
            )
        }
        let status = AXUIElementPerformAction(element, actionName as CFString)
        guard status == .success else {
            throw NotificationDismissalError.actionFailed(action: actionName, status: Int32(status.rawValue))
        }
    }

    private static func node(for element: AXUIElement, path: String, depth: Int) -> NotificationCenterNode {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        let children: [NotificationCenterNode]
        if depth < maximumDepth,
           let elements = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] {
            children = elements.enumerated().map { index, child in
                node(for: child, path: "\(path)/\(index)", depth: depth + 1)
            }
        } else {
            children = []
        }
        return NotificationCenterNode(
            role: attribute(kAXRoleAttribute, of: element) as? String ?? "",
            subrole: attribute(kAXSubroleAttribute, of: element) as? String,
            actionNames: names as? [String] ?? [],
            children: children,
            handle: NotificationCenterNodeHandle(path, element: element)
        )
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}

public enum NotificationActions {
    public static let dismissID = ActionID("dismiss-notifications")

    public static func register(in registry: inout ActionRegistry) throws {
        try register(
            in: &registry,
            dismisser: NotificationDismisser(
                access: AccessibilityNotificationCenter(),
                names: NotificationCenterActionNames()
            )
        )
    }

    static func register(in registry: inout ActionRegistry, dismisser: any NotificationDismissing) throws {
        try registry.register(DismissNotificationsAction(dismisser: dismisser))
    }
}

private struct DismissNotificationsAction: UtilityAction {
    let dismisser: any NotificationDismissing
    let metadata = ActionMetadata(
        id: NotificationActions.dismissID,
        name: "Dismiss all notifications",
        description: "Closes every visible Notification Center banner and alert."
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        let report = try await dismisser.dismissAll()
        return ActionResult(
            summary: "Dismissed \(report.dismissedCount) Notification Center item(s).",
            values: ["dismissedCount": .integer(report.dismissedCount)]
        )
    }
}
#endif
