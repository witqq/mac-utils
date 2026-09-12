import Foundation

protocol AtomicFileAccess: Sendable {
    func read(from url: URL) async throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) async throws
}

typealias ConfigurationFileAccess = AtomicFileAccess

struct LocalAtomicFileAccess: AtomicFileAccess {
    func read(from url: URL) async throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeAtomically(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

enum AtomicJSONFileError: Error, Equatable, Sendable {
    case read(String)
    case decode(String)
    case encode(String)
    case write(String)
}

enum AtomicJSONReadResult<Value: Sendable>: Sendable {
    case missing
    case value(Value)
    case failure(AtomicJSONFileError)
}

actor AtomicJSONFileStore<Value: Codable & Sendable> {
    private let fileURL: URL
    private let fileAccess: any AtomicFileAccess
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init(fileURL: URL, fileAccess: any AtomicFileAccess = LocalAtomicFileAccess()) {
        self.fileURL = fileURL
        self.fileAccess = fileAccess
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    func read() async -> AtomicJSONReadResult<Value> {
        let data: Data
        do {
            guard let stored = try await fileAccess.read(from: fileURL) else {
                return .missing
            }
            data = stored
        } catch {
            return .failure(.read(String(describing: error)))
        }

        do {
            return .value(try decoder.decode(Value.self, from: data))
        } catch {
            return .failure(.decode(String(describing: error)))
        }
    }

    func write(_ value: Value) async throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw AtomicJSONFileError.encode(String(describing: error))
        }

        do {
            try await fileAccess.writeAtomically(data, to: fileURL)
        } catch {
            throw AtomicJSONFileError.write(String(describing: error))
        }
    }
}
