import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

@Test
func displayDiagnosticLogPreservesCorrelatedPortraitEvidence() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "display-log-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DisplayDiagnostics(directoryURL: directory)
    let display = DisplayDescriptor(
        id: DisplayID("portrait"), name: "Portrait", frame: .init(x: 1920, y: -400, width: 1440, height: 2560),
        role: .extended, mode: .init(width: 1440, height: 2560, pixelWidth: 1440, pixelHeight: 2560,
                                     refreshRate: 60, ioModeID: 44), rotation: 270, isInMirrorSet: false
    )
    log.record("before", correlationID: "transition", displays: [display])
    log.record("failed", correlationID: "transition", details: ["CGError": "1000"])
    let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")
    let records = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0["correlationID"] as? String == "transition" })
    let snapshot = try #require((records[0]["displays"] as? [[String: Any]])?.first)
    #expect(snapshot["rotation"] as? Double == 270)
    #expect((snapshot["mode"] as? [String: Any])?["ioModeID"] as? Int == 44)
    #expect((snapshot["frame"] as? [String: Any])?["y"] as? Int == -400)
    #expect((records[1]["details"] as? [String: String])?["CGError"] == "1000")
}

@Test
func displayDiagnosticsRotateAndSerializeConcurrentEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "display-log-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DisplayDiagnostics(directoryURL: directory, maximumBytes: 1_024)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<40 {
            group.addTask { log.record("event", details: ["index": String(index)]) }
        }
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(Set(files.map(\.lastPathComponent)) == ["displays.jsonl", "displays.previous.jsonl", ".displays.lock"])
    for file in files where file.pathExtension == "jsonl" {
        let data = try Data(contentsOf: file)
        #expect(data.count <= 1_024)
        for line in data.split(separator: 0x0A) {
            let entry = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
            #expect(entry["event"] as? String == "event")
        }
    }
}

@Test
func separateDiagnosticWritersPreserveEveryCompleteRecord() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "display-log-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writers = [DisplayDiagnostics(directoryURL: directory), DisplayDiagnostics(directoryURL: directory)]
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask { writers[index % 2].record("event", details: ["index": String(index)]) }
        }
    }
    let lines = try Data(contentsOf: writers[0].fileURL).split(separator: 0x0A)
    let indices = try lines.map { line -> String in
        let entry = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
        return try #require((entry["details"] as? [String: String])?["index"])
    }
    #expect(Set(indices) == Set((0..<100).map(String.init)))
    #expect(lines.count == 100)
}
