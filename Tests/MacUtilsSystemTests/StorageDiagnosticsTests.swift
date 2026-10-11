import Darwin
import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private func storageLogFixture() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return repository.appending(path: "agent_temp_files_local/storage-diagnostic-test-\(UUID())")
}

@Test func storageDiagnosticsBoundOversizedRecordsRotateAndKeepLogsPrivate() throws {
    let directory = try storageLogFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = StorageDiagnostics(directoryURL: directory, maximumBytes: 1_024)
    log.record("scan.start", scanID: "test", details: ["error": String(repeating: "large", count: 1_000)])
    let oversized = try Data(contentsOf: log.fileURL)
    #expect(oversized.count <= 1_024)
    let truncated = try #require(JSONSerialization.jsonObject(with: oversized) as? [String: Any])
    #expect((truncated["details"] as? [String: String])?["truncated"] == "true")
    let escaped = String(repeating: "\u{0001}", count: 200)
    log.record(escaped, scanID: escaped, details: ["error": String(repeating: "large", count: 1_000)])
    for index in 0..<20 { log.record("scan.progress", scanID: "test", details: ["visitedItems": String(index)]) }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(Set(files.map(\.lastPathComponent)) == ["storage.jsonl", "storage.previous.jsonl", ".storage.lock"])
    #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    for file in files {
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        guard file.pathExtension == "jsonl" else { continue }
        let data = try Data(contentsOf: file)
        #expect(data.count <= 1_024)
        for line in data.split(separator: 0x0A) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
    }
}

@Test func storageDiagnosticsSeparateWritersKeepCompleteCorrelatedRecords() async throws {
    let directory = try storageLogFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writers = [StorageDiagnostics(directoryURL: directory), StorageDiagnostics(directoryURL: directory)]
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<80 {
            group.addTask { writers[index % 2].record("scan.progress", scanID: "scan-\(index)", details: ["visitedItems": String(index)]) }
        }
    }
    let entries = try Data(contentsOf: writers[0].fileURL).split(separator: 0x0A).map {
        try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
    #expect(entries.count == 80)
    #expect(Set(entries.compactMap { $0["scanID"] as? String }) == Set((0..<80).map { "scan-\($0)" }))
}

@Test func storageDiagnosticSessionKeepsPhaseAndLastProgressAndStopsAtItsTerminalEvent() throws {
    let directory = try storageLogFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = StorageDiagnostics(directoryURL: directory)
    let session = StorageScanDiagnosticSession(rootPath: "/test-root", operation: "scan", diagnostics: log)
    session.progress(StorageScanProgress(visitedItems: 123, currentPath: "/test-root/last", logicalBytes: 55,
        allocatedBytes: 66, phase: .volumeCatalog, estimatedTotalItems: 1_000))
    session.finish("scan.cancelled")
    session.phase("saveCache")
    session.finish("scan.complete")
    let entries = try Data(contentsOf: log.fileURL).split(separator: 0x0A).map {
        try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
    #expect(entries.compactMap { $0["event"] as? String } == ["scan.start", "scan.cancelled"])
    #expect(entries[0]["scanID"] as? String == entries[1]["scanID"] as? String)
    let details = try #require(entries[1]["details"] as? [String: String])
    #expect(details["phase"] == "volumeCatalog")
    #expect(details["visitedItems"] == "123")
    #expect(details["currentPath"] == "/test-root/last")
    #expect(details["estimatedTotalItems"] == "1000")
    #expect(Double(try #require(details["elapsedSeconds"])) != nil)
    #expect(Double(try #require(details["itemsPerSecond"])) != nil)
}
