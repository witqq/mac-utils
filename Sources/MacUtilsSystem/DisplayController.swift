import MacUtilsCore

protocol DisplayConfigurationDriver: Sendable {
    func readDisplays() async throws -> [DisplayDescriptor]
    func apply(_ operations: [DisplayConfigurationOperation]) async throws
}

public actor DisplayController: DisplayManaging {
    private let driver: any DisplayConfigurationDriver

    init(driver: any DisplayConfigurationDriver) {
        self.driver = driver
    }

    public init() {
        driver = CoreGraphicsDisplayDriver()
    }

    public func displays() async throws -> [DisplayDescriptor] {
        try await driver.readDisplays()
    }

    public func setMainDisplay(_ display: DisplayID) async throws {
        let snapshot = try await driver.readDisplays()
        let operations = try DisplayLayoutPlanner.setMain(display, displays: snapshot)
        try await driver.apply(operations)
    }

    public func setExtendedDisplay(_ display: DisplayID) async throws {
        let snapshot = try await driver.readDisplays()
        let operations = try DisplayLayoutPlanner.setExtended(display, displays: snapshot)
        try await driver.apply(operations)
    }

    public func setMirrorDisplay(_ display: DisplayID, source: DisplayID) async throws {
        let snapshot = try await driver.readDisplays()
        let operations = try DisplayLayoutPlanner.setMirror(display, source: source, displays: snapshot)
        try await driver.apply(operations)
    }
}
