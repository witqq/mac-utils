import Foundation
import MacUtilsCore

public enum ConfigurationStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(ConfigurationValidationError)
    case corruptData(String)
    case fileAccess(String)

    public var description: String {
        switch self {
        case let .invalid(error):
            error.description
        case let .corruptData(message):
            "The saved configuration is damaged and was not loaded: \(message)"
        case let .fileAccess(message):
            "The configuration file could not be accessed: \(message)"
        }
    }
}

public struct ConfigurationLoadResult: Sendable {
    public let configuration: AppConfiguration
    public let recoveryError: ConfigurationStoreError?

    public init(configuration: AppConfiguration, recoveryError: ConfigurationStoreError?) {
        self.configuration = configuration
        self.recoveryError = recoveryError
    }
}

protocol ConfigurationFileAccess: Sendable {
    func read(from url: URL) async throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) async throws
}

private struct LocalConfigurationFileAccess: ConfigurationFileAccess {
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

public actor ConfigurationStore {
    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "com.witqq.mac-utils", directoryHint: .isDirectory)
            .appending(path: "configuration.json", directoryHint: .notDirectory)
    }

    private let fileURL: URL
    private let fileAccess: any ConfigurationFileAccess
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = ConfigurationStore.defaultFileURL) {
        self.fileURL = fileURL
        fileAccess = LocalConfigurationFileAccess()
        encoder = Self.makeEncoder()
        decoder = JSONDecoder()
    }

    init(fileURL: URL, fileAccess: any ConfigurationFileAccess) {
        self.fileURL = fileURL
        self.fileAccess = fileAccess
        encoder = Self.makeEncoder()
        decoder = JSONDecoder()
    }

    public func load() async -> ConfigurationLoadResult {
        let data: Data
        do {
            guard let stored = try await fileAccess.read(from: fileURL) else {
                return ConfigurationLoadResult(configuration: .empty, recoveryError: nil)
            }
            data = stored
        } catch {
            return recovered(error: .fileAccess(String(describing: error)))
        }

        do {
            let configuration = try decoder.decode(AppConfiguration.self, from: data)
            do {
                try configuration.validate()
            } catch let error as ConfigurationValidationError {
                return recovered(error: .invalid(error))
            }
            return ConfigurationLoadResult(configuration: configuration, recoveryError: nil)
        } catch {
            return recovered(error: .corruptData(String(describing: error)))
        }
    }

    public func save(_ configuration: AppConfiguration) async throws {
        do {
            try configuration.validate()
        } catch let error as ConfigurationValidationError {
            throw ConfigurationStoreError.invalid(error)
        }

        let data: Data
        do {
            data = try encoder.encode(configuration)
        } catch {
            throw ConfigurationStoreError.corruptData(String(describing: error))
        }

        do {
            try await fileAccess.writeAtomically(data, to: fileURL)
        } catch {
            throw ConfigurationStoreError.fileAccess(String(describing: error))
        }
    }

    private func recovered(error: ConfigurationStoreError) -> ConfigurationLoadResult {
        ConfigurationLoadResult(configuration: .empty, recoveryError: error)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
