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

public actor ConfigurationStore {
    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "com.witqq.mac-utils", directoryHint: .isDirectory)
            .appending(path: "configuration.json", directoryHint: .notDirectory)
    }

    private let fileStore: AtomicJSONFileStore<AppConfiguration>

    public init(fileURL: URL = ConfigurationStore.defaultFileURL) {
        fileStore = AtomicJSONFileStore(fileURL: fileURL)
    }

    init(fileURL: URL, fileAccess: any ConfigurationFileAccess) {
        fileStore = AtomicJSONFileStore(fileURL: fileURL, fileAccess: fileAccess)
    }

    public func load() async -> ConfigurationLoadResult {
        switch await fileStore.read() {
        case .missing:
            return ConfigurationLoadResult(configuration: .empty, recoveryError: nil)
        case let .value(configuration):
            do {
                try configuration.validate()
                return ConfigurationLoadResult(configuration: configuration, recoveryError: nil)
            } catch let error as ConfigurationValidationError {
                return recovered(error: .invalid(error))
            } catch {
                return recovered(error: .corruptData(String(describing: error)))
            }
        case let .failure(.read(message)):
            return recovered(error: .fileAccess(message))
        case let .failure(.decode(message)):
            return recovered(error: .corruptData(message))
        case let .failure(error):
            return recovered(error: .corruptData(String(describing: error)))
        }
    }

    public func save(_ configuration: AppConfiguration) async throws {
        do {
            try configuration.validate()
        } catch let error as ConfigurationValidationError {
            throw ConfigurationStoreError.invalid(error)
        }

        do {
            try await fileStore.write(configuration)
        } catch let error as AtomicJSONFileError {
            switch error {
            case let .encode(message), let .decode(message):
                throw ConfigurationStoreError.corruptData(message)
            case let .write(message), let .read(message):
                throw ConfigurationStoreError.fileAccess(message)
            }
        }
    }

    private func recovered(error: ConfigurationStoreError) -> ConfigurationLoadResult {
        ConfigurationLoadResult(configuration: .empty, recoveryError: error)
    }
}
