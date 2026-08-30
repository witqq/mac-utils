import Foundation
import MacUtilsCore
import MacUtilsSystem

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case russian

    static let defaultsKey = "appLanguage"

    var id: Self { self }

    var resourceCode: String {
        switch self {
        case .english: "en"
        case .russian: "ru"
        case .system:
            Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true ? "ru" : "en"
        }
    }
}

struct AppText: Sendable {
    let language: AppLanguage

    private static let resourceBundle: Bundle = {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle(for: BundleMarker.self)
        #endif
    }()

    private var bundle: Bundle {
        guard let path = Self.resourceBundle.path(forResource: language.resourceCode, ofType: "lproj"),
              let localized = Bundle(path: path) else { return Self.resourceBundle }
        return localized
    }

    static func localizationCatalog(for language: AppLanguage) throws -> [String: String] {
        guard let localizationPath = resourceBundle.path(forResource: language.resourceCode, ofType: "lproj"),
              let localizationBundle = Bundle(path: localizationPath),
              let url = localizationBundle.url(forResource: "Localizable", withExtension: "strings") else {
            throw LocalizationCatalogError.missing(language.resourceCode)
        }
        let data = try Data(contentsOf: url)
        guard let catalog = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: String] else {
            throw LocalizationCatalogError.invalid(language.resourceCode)
        }
        return catalog
    }

    func callAsFunction(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: self(key), locale: Locale(identifier: language.resourceCode), arguments: arguments)
    }

    func languageName(_ language: AppLanguage) -> String {
        self("language.\(language.rawValue)")
    }

    func actionName(_ metadata: ActionMetadata) -> String {
        localizedMetadata("action.\(metadata.id.rawValue).name", fallback: metadata.name)
    }

    func actionDescription(_ metadata: ActionMetadata) -> String {
        localizedMetadata("action.\(metadata.id.rawValue).description", fallback: metadata.description)
    }

    func providerName(_ metadata: StateProviderMetadata) -> String {
        localizedMetadata("provider.\(metadata.id.rawValue).name", fallback: metadata.name)
    }

    func providerDescription(_ metadata: StateProviderMetadata) -> String {
        localizedMetadata("provider.\(metadata.id.rawValue).description", fallback: metadata.description)
    }

    func parameterLabel(ownerID: String, parameter: ActionParameter) -> String {
        localizedMetadata(
            "metadata.\(ownerID).parameter.\(parameter.name).label",
            fallback: parameter.name.replacingOccurrences(of: "-", with: " ").capitalized
        )
    }

    func parameterHelp(ownerID: String, parameter: ActionParameter) -> String {
        localizedMetadata(
            "metadata.\(ownerID).parameter.\(parameter.name).help",
            fallback: parameter.description
        )
    }

    func optionLabel(providerID: StateProviderID, option: StateOption) -> String {
        let rawValue = switch option.value {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .number(value): String(value)
        case let .boolean(value): String(value)
        }
        return localizedMetadata(
            "provider.\(providerID.rawValue).option.\(rawValue)",
            fallback: option.label
        )
    }

    func role(_ role: DisplayRole) -> String {
        switch role {
        case .main: self("display.role.main")
        case .extended: self("display.role.extended")
        case let .mirror(source): format("display.role.mirror", String(source.rawValue.prefix(8)))
        }
    }

    func shortcut(_ shortcut: GlobalShortcut) -> String {
        var label = ""
        if shortcut.modifiers.contains(.control) { label += "⌃" }
        if shortcut.modifiers.contains(.option) { label += "⌥" }
        if shortcut.modifiers.contains(.shift) { label += "⇧" }
        if shortcut.modifiers.contains(.command) { label += "⌘" }
        label += keyLabel(shortcut.keyCode)
        return label
    }

    func error(_ error: any Error) -> String {
        switch error {
        case let error as ShortcutCoordinatorError:
            switch error {
            case let .scriptNotFound(id): format("error.shortcut.scriptMissing", id.uuidString)
            case .shortcutConflict: self("error.shortcut.conflict")
            }
        case let error as GlobalHotKeyError:
            switch error {
            case let .unavailable(shortcut, status):
                format("error.shortcut.unavailable", self.shortcut(shortcut), status)
            }
        case let error as DisplayActionError:
            switch error {
            case let .invalidIdentifier(parameter): format("error.display.invalidIdentifier", parameter)
            case let .displayUnavailable(id): format("error.display.unavailable", id.rawValue)
            }
        case let error as DisplayManagerError:
            switch error {
            case let .displayNotFound(id): format("error.display.unavailable", id.rawValue)
            case let .cannotMirrorDisplayToItself(id): format("error.display.selfMirror", id.rawValue)
            case let .cannotExtendMainDisplay(id): format("error.display.extendMain", id.rawValue)
            case .noMainDisplay: self("error.display.noMain")
            case let .systemFailure(message): format("error.display.system", message)
            }
        case let error as ConfigurationStoreError:
            switch error {
            case let .invalid(validation): self.error(validation)
            case let .corruptData(message): format("error.config.corrupt", message)
            case let .fileAccess(message): format("error.config.fileAccess", message)
            }
        case let error as ConfigurationValidationError:
            format("error.config.invalid", String(describing: error))
        case let error as LoginItemManagementError:
            switch error {
            case let .registrationFailed(message): format("error.loginItem.enable", message)
            case let .unregistrationFailed(message): format("error.loginItem.disable", message)
            }
        case let diagnostic as ScriptDiagnostic:
            format("error.script.diagnostic", diagnostic.line, diagnostic.column, scriptReason(diagnostic.reason))
        case let error as ScenarioBuilderError:
            builderError(error)
        case let error as ActionExecutionError:
            actionError(error)
        case let error as ScenarioValidationError:
            scenarioValidationError(error)
        case let error as ScenarioExecutionError:
            switch error {
            case let .stateReadFailed(providerID, message):
                format("error.scenario.stateRead", providerID.rawValue, message)
            }
        default:
            format("error.generic", String(describing: error))
        }
    }

    private func scriptReason(_ reason: ScriptDiagnosticReason) -> String {
        switch reason {
        case let .raw(message): message
        case let .invalidActionIdentifier(value): format("error.dsl.invalidActionID", value)
        case .expectedParameterName: self("error.dsl.parameterName")
        case let .duplicateParameter(name): format("error.dsl.duplicateParameter", name)
        case let .expectedEquals(name): format("error.dsl.expectedEquals", name)
        case .expectedWhitespaceOrComment: self("error.dsl.whitespace")
        case let .actionExecution(error): actionError(error)
        case let .parameterType(name, type): format("error.dsl.parameterType", name, valueType(type))
        case .expectedQuotedString: self("error.dsl.quoted")
        case .unterminatedEscape: self("error.dsl.unterminatedEscape")
        case let .unsupportedEscape(value): format("error.dsl.unsupportedEscape", String(value))
        case .unterminatedQuotedString: self("error.dsl.unterminatedString")
        case let .unexpectedMarker(marker): format("error.dsl.unexpectedMarker", marker)
        case .toggleProviderRequired: self("error.dsl.toggleProvider")
        case let .invalidProviderIdentifier(value): format("error.dsl.invalidProviderID", value)
        case let .unknownProvider(id): format("error.dsl.unknownProvider", id.rawValue)
        case .toggleEqualsRequired: self("error.dsl.toggleEquals")
        case let .toggleComparisonType(type): format("error.dsl.toggleType", valueType(type))
        case let .providerParameterType(name, type): format("error.dsl.providerParameterType", name, valueType(type))
        case .expectedOneAction: self("error.dsl.oneAction")
        case let .toggleMarkerRequired(marker): format("error.dsl.toggleMarker", marker)
        }
    }

    private func builderError(_ error: ScenarioBuilderError) -> String {
        switch error {
        case let .unknownAction(id): format("error.builder.unknownAction", id.rawValue)
        case let .unknownProvider(id): format("error.builder.unknownProvider", id.rawValue)
        case let .stepNotFound(id): format("error.builder.stepMissing", id.uuidString)
        case .locationNotFound: self("error.builder.branchMissing")
        case let .expectedAction(id): format("error.builder.expectedAction", id.uuidString)
        case let .expectedToggle(id): format("error.builder.expectedToggle", id.uuidString)
        case let .parameterNotFound(name): format("error.builder.parameterMissing", name)
        case let .wrongParameterType(name, expected, actual):
            format("error.builder.parameterType", name, valueType(expected), valueType(actual))
        case .invalidExpectedValue: self("error.builder.toggleValue")
        }
    }

    private func actionError(_ error: ActionExecutionError) -> String {
        switch error {
        case let .unknownAction(index, actionID):
            format("error.action.unknown", index + 1, actionID.rawValue)
        case let .missingParameter(index, actionID, name):
            format("error.action.missingParameter", index + 1, actionID.rawValue, name)
        case let .unexpectedParameter(index, actionID, name):
            format("error.action.unexpectedParameter", index + 1, actionID.rawValue, name)
        case let .wrongParameterType(index, actionID, name, expected, actual):
            format(
                "error.action.parameterType",
                index + 1,
                actionID.rawValue,
                name,
                valueType(expected),
                valueType(actual)
            )
        case let .actionFailed(index, actionID, message):
            format("error.action.failed", index + 1, actionID.rawValue, message)
        }
    }

    private func scenarioValidationError(_ error: ScenarioValidationError) -> String {
        switch error {
        case let .action(error): actionError(error)
        case let .unknownProvider(id): format("error.dsl.unknownProvider", id.rawValue)
        case let .providerParameter(providerID, violation):
            format("error.scenario.providerParameter", providerID.rawValue, String(describing: violation))
        case let .expectedValueType(providerID, expected, actual):
            format("error.scenario.expectedType", providerID.rawValue, valueType(expected), valueType(actual))
        case let .unsupportedExpectedValue(providerID, value):
            format("error.scenario.unsupportedValue", providerID.rawValue, String(describing: value))
        }
    }

    private func valueType(_ type: ActionValueType) -> String {
        self("valueType.\(type.rawValue)")
    }

    private func localizedMetadata(_ key: String, fallback: String) -> String {
        let value = self(key)
        return value == key ? fallback : value
    }

    private func keyLabel(_ keyCode: UInt32) -> String {
        let labels: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M", 49: self("key.space"), 53: self("key.escape"), 79: "F18", 80: "F19",
        ]
        return labels[keyCode] ?? format("key.unknown", keyCode)
    }
}

private final class BundleMarker {}

private enum LocalizationCatalogError: Error {
    case missing(String)
    case invalid(String)
}
