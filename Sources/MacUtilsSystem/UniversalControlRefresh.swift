#if !APP_STORE
import Darwin
import Foundation
import MacUtilsCore

enum SystemProcessTerminationOutcome: Equatable, Sendable {
    case terminated
    case notRunning
}

struct SystemProcessTerminationFailure: Equatable, Sendable {
    let processName: String
    let message: String
}

enum SystemProcessTerminationError: Error, Equatable, Sendable, CustomStringConvertible {
    case couldNotList(message: String)
    case listFailed(status: Int32, message: String)
    case signalFailed(processName: String, pid: Int32, errorNumber: Int32)

    var description: String {
        switch self {
        case let .couldNotList(message):
            "Could not inspect running processes: \(message)"
        case let .listFailed(status, message):
            "Could not inspect running processes (ps status \(status)): \(message)"
        case let .signalFailed(processName, pid, errorNumber):
            "Could not restart '\(processName)' at PID \(pid) (errno \(errorNumber))."
        }
    }
}

protocol ExactProcessTerminating: Sendable {
    func terminateExactProcess(named processName: String, executablePath: String) async throws
        -> SystemProcessTerminationOutcome
}

struct SystemProcessDescriptor: Equatable, Sendable {
    let userID: UInt32
    let processID: Int32
    let executablePath: String
}

protocol SystemProcessListing: Sendable {
    func processes() async throws -> [SystemProcessDescriptor]
}

protocol SystemProcessSignaling: Sendable {
    func sendKill(to processID: Int32) throws
}

struct PSSystemProcessLister: SystemProcessListing {
    func processes() async throws -> [SystemProcessDescriptor] {
        try await Task.detached {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "uid=,pid=,comm="]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw SystemProcessTerminationError.couldNotList(message: String(describing: error))
            }
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let rawMessage = String(data: errorOutput, encoding: .utf8) ?? ""
                let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SystemProcessTerminationError.listFailed(
                    status: process.terminationStatus,
                    message: message.isEmpty ? "Unknown process error" : message
                )
            }

            let text = String(data: output, encoding: .utf8) ?? ""
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(
                    maxSplits: 2,
                    omittingEmptySubsequences: true,
                    whereSeparator: \.isWhitespace
                )
                guard fields.count == 3,
                      let userID = UInt32(fields[0]),
                      let processID = Int32(fields[1]) else { return nil }
                return SystemProcessDescriptor(
                    userID: userID,
                    processID: processID,
                    executablePath: String(fields[2])
                )
            }
        }.value
    }
}

private enum SystemProcessSignalError: Error {
    case noSuchProcess
}

struct DarwinSystemProcessSignaler: SystemProcessSignaling {
    func sendKill(to processID: Int32) throws {
        guard Darwin.kill(processID, SIGKILL) != 0 else { return }
        let errorNumber = errno
        if errorNumber == ESRCH { throw SystemProcessSignalError.noSuchProcess }
        throw SystemProcessTerminationError.signalFailed(
            processName: "process",
            pid: processID,
            errorNumber: errorNumber
        )
    }
}

struct ExactExecutableProcessTerminator: ExactProcessTerminating {
    private let lister: any SystemProcessListing
    private let signaler: any SystemProcessSignaling
    private let effectiveUserID: UInt32

    init(
        lister: any SystemProcessListing = PSSystemProcessLister(),
        signaler: any SystemProcessSignaling = DarwinSystemProcessSignaler(),
        effectiveUserID: UInt32 = geteuid()
    ) {
        self.lister = lister
        self.signaler = signaler
        self.effectiveUserID = effectiveUserID
    }

    func terminateExactProcess(named processName: String, executablePath: String) async throws
        -> SystemProcessTerminationOutcome {
        let matches = try await lister.processes().filter {
            $0.userID == effectiveUserID && $0.executablePath == executablePath
        }
        guard !matches.isEmpty else { return .notRunning }

        var terminatedAny = false
        for process in matches {
            try Task.checkCancellation()
            do {
                try signaler.sendKill(to: process.processID)
                terminatedAny = true
            } catch SystemProcessSignalError.noSuchProcess {
                continue
            } catch let error as SystemProcessTerminationError {
                if case let .signalFailed(_, pid, errorNumber) = error {
                    throw SystemProcessTerminationError.signalFailed(
                        processName: processName,
                        pid: pid,
                        errorNumber: errorNumber
                    )
                }
                throw error
            }
        }
        return terminatedAny ? .terminated : .notRunning
    }
}

enum UniversalControlService: CaseIterable, Sendable {
    case universalControl
    case rapport
    case sharing
    case sidecarRelay
    case userActivity

    var processName: String {
        switch self {
        case .universalControl: "UniversalControl"
        case .rapport: "rapportd"
        case .sharing: "sharingd"
        case .sidecarRelay: "SidecarRelay"
        case .userActivity: "useractivityd"
        }
    }

    var executablePath: String {
        switch self {
        case .universalControl:
            "/System/Library/CoreServices/UniversalControl.app/Contents/MacOS/UniversalControl"
        case .rapport:
            "/usr/libexec/rapportd"
        case .sharing:
            "/usr/libexec/sharingd"
        case .sidecarRelay:
            "/usr/libexec/SidecarRelay"
        case .userActivity:
            "/System/Library/PrivateFrameworks/UserActivity.framework/Agents/useractivityd"
        }
    }
}

struct UniversalControlRefreshReport: Equatable, Sendable {
    let terminated: [String]
    let notRunning: [String]
}

enum UniversalControlRefreshError: Error, Equatable, Sendable, CustomStringConvertible {
    case partialFailure([SystemProcessTerminationFailure])

    var description: String {
        switch self {
        case let .partialFailure(failures):
            let details = failures
                .map { "\($0.processName): \($0.message)" }
                .joined(separator: "; ")
            return "Universal Control refresh was incomplete. \(details)"
        }
    }
}

protocol UniversalControlRefreshing: Sendable {
    func refresh() async throws -> UniversalControlRefreshReport
}

struct UniversalControlRefresher: UniversalControlRefreshing {
    private let terminator: any ExactProcessTerminating

    init(terminator: any ExactProcessTerminating = ExactExecutableProcessTerminator()) {
        self.terminator = terminator
    }

    func refresh() async throws -> UniversalControlRefreshReport {
        var terminated: [String] = []
        var notRunning: [String] = []
        var failures: [SystemProcessTerminationFailure] = []

        for service in UniversalControlService.allCases {
            try Task.checkCancellation()
            do {
                switch try await terminator.terminateExactProcess(
                    named: service.processName,
                    executablePath: service.executablePath
                ) {
                case .terminated:
                    terminated.append(service.processName)
                case .notRunning:
                    notRunning.append(service.processName)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(SystemProcessTerminationFailure(
                    processName: service.processName,
                    message: String(describing: error)
                ))
            }
        }

        guard failures.isEmpty else {
            throw UniversalControlRefreshError.partialFailure(failures)
        }
        return UniversalControlRefreshReport(terminated: terminated, notRunning: notRunning)
    }
}

public enum UniversalControlActions {
    public static let refreshID = ActionID("refresh-universal-control")

    public static func register(in registry: inout ActionRegistry) throws {
        try register(in: &registry, refresher: UniversalControlRefresher())
    }

    static func register(
        in registry: inout ActionRegistry,
        refresher: any UniversalControlRefreshing
    ) throws {
        try registry.register(RefreshUniversalControlAction(refresher: refresher))
    }
}

private struct RefreshUniversalControlAction: UtilityAction {
    let refresher: any UniversalControlRefreshing
    let metadata = ActionMetadata(
        id: UniversalControlActions.refreshID,
        name: "Refresh Universal Control",
        description: "Restarts local Continuity services so Universal Control can reconnect."
    )

    func execute(parameters: ActionParameters, context: ActionContext) async throws -> ActionResult {
        let report = try await refresher.refresh()
        return ActionResult(
            summary: "Refreshed Universal Control services.",
            values: [
                "restartedCount": .integer(report.terminated.count),
                "notRunningCount": .integer(report.notRunning.count),
            ]
        )
    }
}
#endif
