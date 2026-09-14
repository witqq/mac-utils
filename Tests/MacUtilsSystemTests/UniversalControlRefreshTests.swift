#if !APP_STORE
import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private enum RefreshTestError: Error, CustomStringConvertible {
    case denied

    var description: String { "denied" }
}

private actor FakeProcessTerminator: ExactProcessTerminating {
    private(set) var processNames: [String] = []
    private(set) var executablePaths: [String] = []
    var outcomes: [String: SystemProcessTerminationOutcome] = [:]
    var failures: Set<String> = []
    var cancellationProcess: String?

    func terminateExactProcess(named processName: String, executablePath: String) async throws
        -> SystemProcessTerminationOutcome {
        processNames.append(processName)
        executablePaths.append(executablePath)
        if cancellationProcess == processName { throw CancellationError() }
        if failures.contains(processName) { throw RefreshTestError.denied }
        return outcomes[processName] ?? .terminated
    }

    func setOutcome(_ outcome: SystemProcessTerminationOutcome, for processName: String) {
        outcomes[processName] = outcome
    }

    func fail(_ processName: String) {
        failures.insert(processName)
    }

    func cancel(at processName: String) {
        cancellationProcess = processName
    }
}

private struct FakeProcessLister: SystemProcessListing {
    let descriptors: [SystemProcessDescriptor]

    func processes() async throws -> [SystemProcessDescriptor] { descriptors }
}

private final class FakeProcessSignaler: SystemProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []

    var processIDs: [Int32] {
        lock.withLock { storage }
    }

    func sendKill(to processID: Int32) throws {
        lock.withLock { storage.append(processID) }
    }
}

private actor FakeUniversalControlRefresher: UniversalControlRefreshing {
    private(set) var refreshCount = 0

    func refresh() async throws -> UniversalControlRefreshReport {
        refreshCount += 1
        return UniversalControlRefreshReport(terminated: [], notRunning: [])
    }
}

private actor RefreshHotKeyRegistrar: GlobalHotKeyRegistering {
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

private let expectedUniversalControlProcesses = [
    "UniversalControl",
    "rapportd",
    "sharingd",
    "SidecarRelay",
    "useractivityd",
]

private let expectedUniversalControlPaths = [
    "/System/Library/CoreServices/UniversalControl.app/Contents/MacOS/UniversalControl",
    "/usr/libexec/rapportd",
    "/usr/libexec/sharingd",
    "/usr/libexec/SidecarRelay",
    "/System/Library/PrivateFrameworks/UserActivity.framework/Agents/useractivityd",
]

@Test
func refreshTerminatesTheFixedAllowlistInOrder() async throws {
    let terminator = FakeProcessTerminator()
    let report = try await UniversalControlRefresher(terminator: terminator).refresh()

    #expect(await terminator.processNames == expectedUniversalControlProcesses)
    #expect(await terminator.executablePaths == expectedUniversalControlPaths)
    #expect(report.terminated == expectedUniversalControlProcesses)
    #expect(report.notRunning.isEmpty)
}

@Test
func exactTerminatorSignalsOnlyTheCurrentUsersExactExecutablePath() async throws {
    let expected = SystemProcessDescriptor(
        userID: 501,
        processID: 10,
        executablePath: "/usr/libexec/rapportd"
    )
    let simulator = SystemProcessDescriptor(
        userID: 501,
        processID: 11,
        executablePath: "/Library/Developer/CoreSimulator/RuntimeRoot/usr/libexec/rapportd"
    )
    let otherUser = SystemProcessDescriptor(
        userID: 502,
        processID: 12,
        executablePath: "/usr/libexec/rapportd"
    )
    let signaler = FakeProcessSignaler()
    let terminator = ExactExecutableProcessTerminator(
        lister: FakeProcessLister(descriptors: [simulator, otherUser, expected]),
        signaler: signaler,
        effectiveUserID: 501
    )

    let outcome = try await terminator.terminateExactProcess(
        named: "rapportd",
        executablePath: "/usr/libexec/rapportd"
    )

    #expect(outcome == .terminated)
    #expect(signaler.processIDs == [10])
}

@Test
func exactTerminatorTreatsOnlyWrongPathOrUserAsNotRunning() async throws {
    let signaler = FakeProcessSignaler()
    let terminator = ExactExecutableProcessTerminator(
        lister: FakeProcessLister(descriptors: [
            SystemProcessDescriptor(
                userID: 501,
                processID: 11,
                executablePath: "/Library/Developer/CoreSimulator/RuntimeRoot/usr/libexec/sharingd"
            ),
            SystemProcessDescriptor(
                userID: 502,
                processID: 12,
                executablePath: "/usr/libexec/sharingd"
            ),
        ]),
        signaler: signaler,
        effectiveUserID: 501
    )

    let outcome = try await terminator.terminateExactProcess(
        named: "sharingd",
        executablePath: "/usr/libexec/sharingd"
    )

    #expect(outcome == .notRunning)
    #expect(signaler.processIDs.isEmpty)
}

@Test
func refreshTreatsAbsentProcessesAsSuccessfulNoOps() async throws {
    let terminator = FakeProcessTerminator()
    await terminator.setOutcome(.notRunning, for: "SidecarRelay")

    let report = try await UniversalControlRefresher(terminator: terminator).refresh()

    #expect(report.terminated == expectedUniversalControlProcesses.filter { $0 != "SidecarRelay" })
    #expect(report.notRunning == ["SidecarRelay"])
}

@Test
func refreshAttemptsEveryProcessBeforeReportingPartialFailure() async throws {
    let terminator = FakeProcessTerminator()
    await terminator.fail("rapportd")
    await terminator.fail("SidecarRelay")

    do {
        _ = try await UniversalControlRefresher(terminator: terminator).refresh()
        Issue.record("Expected a partial failure")
    } catch let UniversalControlRefreshError.partialFailure(failures) {
        #expect(failures.map(\.processName) == ["rapportd", "SidecarRelay"])
    }
    #expect(await terminator.processNames == expectedUniversalControlProcesses)
}

@Test
func refreshStopsImmediatelyWhenCancelled() async throws {
    let terminator = FakeProcessTerminator()
    await terminator.cancel(at: "sharingd")

    await #expect(throws: CancellationError.self) {
        _ = try await UniversalControlRefresher(terminator: terminator).refresh()
    }
    #expect(await terminator.processNames == ["UniversalControl", "rapportd", "sharingd"])
}

@Test
func actionRegistersWithoutParametersAndExecutesTheSharedRefresher() async throws {
    let refresher = FakeUniversalControlRefresher()
    var registry = ActionRegistry()
    try UniversalControlActions.register(in: &registry, refresher: refresher)
    let metadata = try #require(registry.metadata.first)
    let action = try #require(registry.action(for: UniversalControlActions.refreshID))

    #expect(metadata.id == UniversalControlActions.refreshID)
    #expect(metadata.parameters.isEmpty)
    let result = try await action.execute(parameters: [:], context: ActionContext())
    #expect(result.summary == "Refreshed Universal Control services.")
    #expect(await refresher.refreshCount == 1)
}

@Test
func repeatedGlobalHotKeyRunsTheRefreshActionEveryTime() async throws {
    let refresher = FakeUniversalControlRefresher()
    var registry = ActionRegistry()
    try UniversalControlActions.register(in: &registry, refresher: refresher)
    let registrar = RefreshHotKeyRegistrar()
    let coordinator = ShortcutCoordinator(registrar: registrar, registry: registry)
    let script = UserScript(
        name: "Refresh Universal Control",
        source: UniversalControlActions.refreshID.rawValue
    )
    let shortcut = GlobalShortcut(keyCode: 15, modifiers: [.command, .option])
    let binding = ShortcutBinding(shortcut: shortcut, scriptID: script.id)

    try await coordinator.upsertScript(script)
    try await coordinator.register(binding)
    await registrar.trigger(shortcut)
    await registrar.trigger(shortcut)

    #expect(await refresher.refreshCount == 2)
    #expect(await coordinator.lastExecution == ShortcutExecutionEvent(
        bindingID: binding.id,
        status: .succeeded(stepCount: 1)
    ))
}
#endif
