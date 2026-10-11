import Darwin
import Foundation
import MacUtilsCore
import OSLog
import Synchronization

/// Private, bounded scan evidence. Diagnostic failures never change scan results.
public final class StorageDiagnostics: Sendable {
    public static let shared = StorageDiagnostics()
    public let directoryURL: URL
    public var fileURL: URL { directoryURL.appending(path: "storage.jsonl") }
    private let sessionID = UUID().uuidString
    private let maximumBytes: Int
    private let writeLock = Mutex(())
    private let logger = Logger(subsystem: "com.witqq.mac-utils", category: "Storage")

    public init(directoryURL: URL = DisplayDiagnostics.defaultDirectoryURL, maximumBytes: Int = 2_000_000) {
        self.directoryURL = directoryURL; self.maximumBytes = max(1_024, maximumBytes)
    }

    public func record(_ event: String, scanID: String, details: [String: String] = [:]) {
        writeLock.withLock { _ in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var entry = Entry(date: Date(), sessionID: sessionID, processID: ProcessInfo.processInfo.processIdentifier,
                    event: String(event.prefix(40)), scanID: String(scanID.prefix(40)), details: details)
                var line = try encoder.encode(entry)
                if line.count + 1 > maximumBytes {
                    entry.details = ["truncated": "true"]
                    line = try encoder.encode(entry)
                }
                line.append(0x0A)
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
                let descriptor = Darwin.open(directoryURL.appending(path: ".storage.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
                guard descriptor >= 0 else { throw POSIXError(.EIO) }
                defer { Darwin.close(descriptor) }
                guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
                defer { flock(descriptor, LOCK_UN) }
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 && size + line.count > maximumBytes {
                    let previous = directoryURL.appending(path: "storage.previous.jsonl")
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: fileURL, to: previous)
                }
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                        attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: line)
                logger.debug("Storage event: \(event, privacy: .public), scan: \(scanID, privacy: .public)")
            } catch {
                logger.error("Storage diagnostic write failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private struct Entry: Encodable {
        let date: Date
        let sessionID: String
        let processID: Int32
        let event: String
        let scanID: String
        var details: [String: String]
    }
}

/// A heartbeat keeps the last visited path available even while a native metadata call stalls.
final class StorageScanDiagnosticSession: Sendable {
    private struct State: Sendable {
        var phase = "resolveGrant"
        var progress: StorageScanProgress?
        var finished = false
    }
    private let state = Mutex(State())
    private let diagnostics: StorageDiagnostics?
    private let started = ContinuousClock().now
    private let scanID = UUID().uuidString
    private let rootPath: String
    private let operation: String

    init(rootPath: String, operation: String, diagnostics: StorageDiagnostics?) {
        self.rootPath = rootPath; self.operation = operation; self.diagnostics = diagnostics
        record("scan.start")
    }

    func heartbeat() -> Task<Void, Never> {
        Task {
            guard diagnostics != nil else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                record("scan.progress")
            }
        }
    }

    func phase(_ phase: String) { state.withLock { $0.phase = phase }; record("scan.phase") }
    func progress(_ progress: StorageScanProgress) {
        state.withLock { $0.progress = progress; $0.phase = progress.phase.rawValue }
    }
    func finish(_ event: String, details: [String: String] = [:]) {
        record(event, details: details, finishes: true)
    }

    private func record(_ event: String, details: [String: String] = [:], finishes: Bool = false) {
        state.withLock { state in
            guard !state.finished else { return }
            let elapsed = started.duration(to: ContinuousClock().now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            var values = details
            values["operation"] = operation
            values["rootPath"] = rootPath
            values["phase"] = state.phase
            values["elapsedSeconds"] = String(format: "%.3f", seconds)
            if let progress = state.progress {
                values["visitedItems"] = String(progress.visitedItems)
                values["currentPath"] = progress.currentPath
                values["logicalBytes"] = String(progress.logicalBytes)
                values["allocatedBytes"] = String(progress.allocatedBytes)
                values["itemsPerSecond"] = String(format: "%.1f", Double(progress.visitedItems) / max(seconds, 0.001))
                if let total = progress.estimatedTotalItems { values["estimatedTotalItems"] = String(total) }
            }
            diagnostics?.record(event, scanID: scanID, details: values)
            if finishes { state.finished = true }
        }
    }
}
