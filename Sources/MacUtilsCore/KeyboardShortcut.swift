import Foundation

public struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let control = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)
}

public struct GlobalShortcut: Hashable, Codable, Sendable {
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers

    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct UserScript: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var source: String

    public init(id: UUID = UUID(), name: String, source: String) {
        self.id = id
        self.name = name
        self.source = source
    }
}

public struct ShortcutBinding: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID
    public var shortcut: GlobalShortcut
    public var scriptID: UUID

    public init(id: UUID = UUID(), shortcut: GlobalShortcut, scriptID: UUID) {
        self.id = id
        self.shortcut = shortcut
        self.scriptID = scriptID
    }
}
