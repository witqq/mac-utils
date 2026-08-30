import Foundation

public struct AppConfiguration: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var scripts: [UserScript]
    public var bindings: [ShortcutBinding]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        scripts: [UserScript] = [],
        bindings: [ShortcutBinding] = []
    ) {
        self.schemaVersion = schemaVersion
        self.scripts = scripts
        self.bindings = bindings
    }

    public static let empty = AppConfiguration()

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ConfigurationValidationError.unsupportedSchemaVersion(schemaVersion)
        }

        var scriptIDs: Set<UUID> = []
        for script in scripts {
            guard scriptIDs.insert(script.id).inserted else {
                throw ConfigurationValidationError.duplicateScriptID(script.id)
            }
            guard !script.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationValidationError.emptyScriptName(script.id)
            }
        }

        var bindingIDs: Set<UUID> = []
        var shortcutOwners: [GlobalShortcut: UUID] = [:]
        for binding in bindings {
            guard bindingIDs.insert(binding.id).inserted else {
                throw ConfigurationValidationError.duplicateBindingID(binding.id)
            }
            guard scriptIDs.contains(binding.scriptID) else {
                throw ConfigurationValidationError.missingScript(
                    bindingID: binding.id,
                    scriptID: binding.scriptID
                )
            }
            if let existingID = shortcutOwners[binding.shortcut] {
                throw ConfigurationValidationError.shortcutConflict(
                    firstBindingID: existingID,
                    secondBindingID: binding.id
                )
            }
            shortcutOwners[binding.shortcut] = binding.id
        }
    }
}

public enum ConfigurationValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case duplicateScriptID(UUID)
    case emptyScriptName(UUID)
    case duplicateBindingID(UUID)
    case missingScript(bindingID: UUID, scriptID: UUID)
    case shortcutConflict(firstBindingID: UUID, secondBindingID: UUID)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Configuration schema \(version) is unsupported; this pre-release build only accepts schema \(AppConfiguration.currentSchemaVersion)."
        case let .duplicateScriptID(id):
            "Script ID '\(id)' occurs more than once."
        case let .emptyScriptName(id):
            "Script '\(id)' has an empty name."
        case let .duplicateBindingID(id):
            "Shortcut binding ID '\(id)' occurs more than once."
        case let .missingScript(bindingID, scriptID):
            "Shortcut binding '\(bindingID)' references missing script '\(scriptID)'."
        case let .shortcutConflict(firstBindingID, secondBindingID):
            "Shortcut bindings '\(firstBindingID)' and '\(secondBindingID)' use the same key combination."
        }
    }
}
