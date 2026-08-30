public struct DisplayID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty, "Display IDs cannot be empty")
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct DisplayFrame: Hashable, Codable, Sendable {
    public var x: Int32
    public var y: Int32
    public var width: Int32
    public var height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int32 { x + width }
    public var maxY: Int32 { y + height }
}

public enum DisplayRole: Hashable, Codable, Sendable {
    case main
    case extended
    case mirror(source: DisplayID)
}

public struct DisplayDescriptor: Hashable, Codable, Sendable {
    public let id: DisplayID
    public let name: String
    public var frame: DisplayFrame
    public var role: DisplayRole
    public let isActive: Bool

    public init(id: DisplayID, name: String, frame: DisplayFrame, role: DisplayRole, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.frame = frame
        self.role = role
        self.isActive = isActive
    }
}

public enum DisplayConfigurationOperation: Hashable, Codable, Sendable {
    case setOrigin(display: DisplayID, x: Int32, y: Int32)
    case setMirror(display: DisplayID, source: DisplayID?)
}

public enum DisplayManagerError: Error, Equatable, Sendable, CustomStringConvertible {
    case displayNotFound(DisplayID)
    case cannotMirrorDisplayToItself(DisplayID)
    case cannotExtendMainDisplay(DisplayID)
    case noMainDisplay
    case systemFailure(String)

    public var description: String {
        switch self {
        case let .displayNotFound(id):
            "Display '\(id)' is not connected."
        case let .cannotMirrorDisplayToItself(id):
            "Display '\(id)' cannot mirror itself."
        case let .cannotExtendMainDisplay(id):
            "Display '\(id)' is the main display; make another display main before extending it."
        case .noMainDisplay:
            "The current configuration has no main display."
        case let .systemFailure(message):
            "Display configuration failed: \(message)"
        }
    }
}

public protocol DisplayManaging: Sendable {
    func displays() async throws -> [DisplayDescriptor]
    func setMainDisplay(_ display: DisplayID) async throws
    func setExtendedDisplay(_ display: DisplayID) async throws
    func setMirrorDisplay(_ display: DisplayID, source: DisplayID) async throws
}

public enum DisplayLayoutPlanner {
    public static func setMain(
        _ target: DisplayID,
        displays: [DisplayDescriptor]
    ) throws -> [DisplayConfigurationOperation] {
        guard let targetDisplay = displays.first(where: { $0.id == target }) else {
            throw DisplayManagerError.displayNotFound(target)
        }

        var independent = displays.filter {
            if case .mirror = $0.role { return $0.id == target }
            return true
        }
        var targetFrame = targetDisplay.frame
        var operations: [DisplayConfigurationOperation] = []

        if case .mirror = targetDisplay.role {
            operations.append(.setMirror(display: target, source: nil))
            let rightEdge = displays
                .filter { if case .mirror = $0.role { return false }; return true }
                .map(\.frame.maxX)
                .max() ?? 0
            targetFrame.x = rightEdge
            if let index = independent.firstIndex(where: { $0.id == target }) {
                independent[index].frame = targetFrame
            }
        }

        let offsetX = targetFrame.x
        let offsetY = targetFrame.y
        operations.append(contentsOf: independent.map {
            .setOrigin(display: $0.id, x: $0.frame.x - offsetX, y: $0.frame.y - offsetY)
        })
        return operations
    }

    public static func setExtended(
        _ target: DisplayID,
        displays: [DisplayDescriptor]
    ) throws -> [DisplayConfigurationOperation] {
        guard let targetDisplay = displays.first(where: { $0.id == target }) else {
            throw DisplayManagerError.displayNotFound(target)
        }
        if case .main = targetDisplay.role {
            throw DisplayManagerError.cannotExtendMainDisplay(target)
        }
        guard case .mirror = targetDisplay.role else {
            return []
        }
        guard let main = displays.first(where: { $0.role == .main }) else {
            throw DisplayManagerError.noMainDisplay
        }

        let rightEdge = displays
            .filter { if case .mirror = $0.role { return false }; return true }
            .map(\.frame.maxX)
            .max() ?? main.frame.maxX

        return [
            .setMirror(display: target, source: nil),
            .setOrigin(display: target, x: rightEdge, y: main.frame.y),
        ]
    }

    public static func setMirror(
        _ target: DisplayID,
        source: DisplayID,
        displays: [DisplayDescriptor]
    ) throws -> [DisplayConfigurationOperation] {
        guard target != source else {
            throw DisplayManagerError.cannotMirrorDisplayToItself(target)
        }
        guard let targetDisplay = displays.first(where: { $0.id == target }) else {
            throw DisplayManagerError.displayNotFound(target)
        }
        guard let sourceDisplay = displays.first(where: { $0.id == source }) else {
            throw DisplayManagerError.displayNotFound(source)
        }

        var operations: [DisplayConfigurationOperation] = []
        if case .mirror = sourceDisplay.role {
            operations.append(.setMirror(display: source, source: nil))
        }

        if targetDisplay.role == .main {
            let sourceFrame = sourceDisplay.frame
            let independent = displays.filter { display in
                guard display.id != target else { return false }
                if case .mirror = display.role {
                    return display.id == source
                }
                return true
            }
            operations.append(contentsOf: independent.map {
                .setOrigin(
                    display: $0.id,
                    x: $0.frame.x - sourceFrame.x,
                    y: $0.frame.y - sourceFrame.y
                )
            })
        }

        operations.append(.setMirror(display: target, source: source))
        return operations
    }
}
