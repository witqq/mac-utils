import ServiceManagement
@testable import MacUtilsSystem
import Testing

@MainActor
private final class LoginItemServiceFake: LoginItemService {
    enum Failure: Error { case register, unregister }

    var status: SMAppService.Status
    var registerCount = 0
    var unregisterCount = 0
    var registerError: (any Error)?
    var unregisterError: (any Error)?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

@Test @MainActor
func loginItemManagerMapsEveryServiceStatus() {
    for (serviceStatus, expected) in [
        (SMAppService.Status.notRegistered, LoginItemStatus.notRegistered),
        (.enabled, .enabled),
        (.requiresApproval, .requiresApproval),
        (.notFound, .notFound),
    ] {
        let service = LoginItemServiceFake(status: serviceStatus)
        #expect(SystemLoginItemManager(service: service).status == expected)
    }
}

@Test @MainActor
func loginItemManagerRegistersAndUnregistersOnlyWhenNeeded() throws {
    let service = LoginItemServiceFake(status: .notRegistered)
    let manager = SystemLoginItemManager(service: service)

    try manager.setEnabled(true)
    try manager.setEnabled(true)
    try manager.setEnabled(false)
    try manager.setEnabled(false)

    #expect(service.registerCount == 1)
    #expect(service.unregisterCount == 1)
    #expect(manager.status == .notRegistered)
}

@Test @MainActor
func loginItemManagerReturnsOperationSpecificErrors() {
    let service = LoginItemServiceFake(status: .notRegistered)
    let manager = SystemLoginItemManager(service: service)
    service.registerError = LoginItemServiceFake.Failure.register

    #expect(throws: LoginItemManagementError.registrationFailed("register")) {
        try manager.setEnabled(true)
    }

    service.status = .enabled
    service.unregisterError = LoginItemServiceFake.Failure.unregister
    #expect(throws: LoginItemManagementError.unregistrationFailed("unregister")) {
        try manager.setEnabled(false)
    }
}
