import Darwin
import Foundation
import MacUtilsCore
import OSLog
import Synchronization

/// Bounded, local-only evidence for display reconfiguration and hardware diagnosis.
/// Writes are serialized across callbacks and commands; logging failure never changes a display.
public final class DisplayDiagnostics: Sendable {
    public static let shared = DisplayDiagnostics()
    @TaskLocal public static var correlationID: String?

    public static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/com.witqq.mac-utils", directoryHint: .isDirectory)
    }

    public let directoryURL: URL
    public var fileURL: URL { directoryURL.appending(path: "displays.jsonl") }

    private let sessionID = UUID().uuidString
    private let maximumBytes: Int
    private let writeLock = Mutex(())
    private let logger = Logger(subsystem: "com.witqq.mac-utils", category: "Displays")

    public init(directoryURL: URL = DisplayDiagnostics.defaultDirectoryURL, maximumBytes: Int = 2_000_000) {
        self.directoryURL = directoryURL
        self.maximumBytes = max(1_024, maximumBytes)
    }

    public func record(
        _ event: String,
        correlationID: String? = nil,
        displays: [DisplayDescriptor]? = nil,
        operations: [DisplayConfigurationOperation]? = nil,
        details: [String: String] = [:]
    ) {
        let correlationID = correlationID ?? Self.correlationID
        let entry = Entry(
            date: Date(), sessionID: sessionID, processID: ProcessInfo.processInfo.processIdentifier,
            event: event, correlationID: correlationID, displays: displays, operations: operations,
            details: details
        )
        writeLock.withLock { _ in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var line = try encoder.encode(entry)
                line.append(0x0A)
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                // A read-only watcher and the app can run in separate processes during diagnosis.
                let lockURL = directoryURL.appending(path: ".displays.lock")
                let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
                guard descriptor >= 0 else { throw POSIXError(.EIO) }
                defer { Darwin.close(descriptor) }
                guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
                defer { flock(descriptor, LOCK_UN) }
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 && size + line.count > maximumBytes {
                    let previous = directoryURL.appending(path: "displays.previous.jsonl")
                    if FileManager.default.fileExists(atPath: previous.path) {
                        try FileManager.default.removeItem(at: previous)
                    }
                    try FileManager.default.moveItem(at: fileURL, to: previous)
                }
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                logger.debug("Display event: \(event, privacy: .public), correlation: \(correlationID ?? "none", privacy: .public)")
            } catch {
                logger.error("Display diagnostic write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private struct Entry: Encodable {
        let date: Date
        let sessionID: String
        let processID: Int32
        let event: String
        let correlationID: String?
        let displays: [DisplayDescriptor]?
        let operations: [DisplayConfigurationOperation]?
        let details: [String: String]
    }
}
