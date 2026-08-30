import ServiceManagement

public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public enum LoginItemManagementError: Error, Equatable, Sendable {
    case registrationFailed(String)
    case unregistrationFailed(String)
}

@MainActor
public protocol LoginItemManaging: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
public final class SystemLoginItemManager: LoginItemManaging {
    private let service: any LoginItemService

    public convenience init() {
        self.init(service: SMAppService.mainApp)
    }

    init(service: any LoginItemService) {
        self.service = service
    }

    public var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard status != .enabled else { return }
            do {
                try service.register()
            } catch {
                throw LoginItemManagementError.registrationFailed(String(describing: error))
            }
        } else {
            guard status != .notRegistered else { return }
            do {
                try service.unregister()
            } catch {
                throw LoginItemManagementError.unregistrationFailed(String(describing: error))
            }
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
