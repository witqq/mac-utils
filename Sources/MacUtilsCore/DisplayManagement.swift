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

    public func translated(byX offsetX: Int64, byY offsetY: Int64) throws -> DisplayFrame {
        guard let translatedX = Int32(exactly: Int64(x) + offsetX),
              let translatedY = Int32(exactly: Int64(y) + offsetY) else {
            throw DisplayManagerError.systemFailure("Display coordinates exceed the supported range")
        }
        return DisplayFrame(x: translatedX, y: translatedY, width: width, height: height)
    }
}

public enum DisplayRole: Hashable, Codable, Sendable {
    case main
    case extended
    case mirror(source: DisplayID)
}

/// Portable mode metadata; catalog indices and raw display IDs are not persistent identities.
public struct DisplayMode: Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let ioModeID: Int32

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, ioModeID: Int32) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.ioModeID = ioModeID
    }

    public var isValid: Bool {
        width > 0 && height > 0 && pixelWidth > 0 && pixelHeight > 0
            && refreshRate.isFinite && refreshRate >= 0
    }
}

public struct DisplayDescriptor: Hashable, Codable, Sendable {
    public let id: DisplayID
    public let name: String
    public var frame: DisplayFrame
    public var role: DisplayRole
    public let isActive: Bool
    public var mode: DisplayMode?
    public var rotation: Double?
    public let isInMirrorSet: Bool?

    public init(id: DisplayID, name: String, frame: DisplayFrame, role: DisplayRole, isActive: Bool = true,
                mode: DisplayMode? = nil, rotation: Double? = nil, isInMirrorSet: Bool? = nil) {
        self.id = id
        self.name = name
        self.frame = frame
        self.role = role
        self.isActive = isActive
        self.mode = mode
        self.rotation = rotation
        self.isInMirrorSet = isInMirrorSet
    }
}

public enum DisplayConfigurationOperation: Hashable, Codable, Sendable {
    case setOrigin(display: DisplayID, x: Int32, y: Int32)
    case setMirror(display: DisplayID, source: DisplayID?)
    /// Returns a display that just left mirroring to its own default mode instead of the
    /// mode macOS chose for the mirror pair.
    case restoreDefaultMode(display: DisplayID)
    case restoreMode(display: DisplayID, mode: DisplayMode, rotation: Double?)
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
    /// Complete mirror membership includes sources, whose current mode/bounds are shared too.
    public static func mirrorMembers(in displays: [DisplayDescriptor]) -> Set<DisplayID> {
        var members = Set(displays.filter { $0.isInMirrorSet == true }.map(\.id))
        for display in displays {
            if case let .mirror(source) = display.role { members.insert(display.id); members.insert(source) }
        }
        return members
    }

    public static func preservingIndependentState(
        _ operations: [DisplayConfigurationOperation], displays: [DisplayDescriptor],
        remembered: [DisplayID: DisplayDescriptor]
    ) throws -> [DisplayConfigurationOperation] {
        guard !operations.isEmpty else { return [] }
        var roles = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.role) })
        var mainID = displays.first { $0.role == .main }?.id
        for operation in operations {
            switch operation {
            case let .setMirror(display, source):
                roles[display] = source.map { .mirror(source: $0) } ?? .extended
                if mainID == display, let source { mainID = source }
            case let .setOrigin(display, x, y):
                if x == 0, y == 0 { mainID = display }
            default: break
            }
        }
        let independent = displays.filter { if case .mirror = roles[$0.id] { false } else { true } }
        let oldMembers = mirrorMembers(in: displays)
        let finalSources = Set(roles.values.compactMap { role -> DisplayID? in
            if case let .mirror(source) = role { source } else { nil }
        })
        let restoreIDs = Set(independent.filter { display in
            guard oldMembers.contains(display.id) else { return false }
            if case .mirror = display.role { return true }
            return !finalSources.contains(display.id)
        }.map(\.id))
        var frames = Dictionary(uniqueKeysWithValues: independent.map { ($0.id, $0.frame) })
        // The legacy planner supplies deterministic placement when there is no known history.
        for case let .setOrigin(display, x, y) in operations {
            frames[display]?.x = x; frames[display]?.y = y
        }
        let currentMain = displays.first { $0.role == .main }
        let canonicalOffset = currentMain.flatMap { remembered[$0.id]?.frame }
        let plannedMainFrame = currentMain.flatMap { frames[$0.id] }
        for display in independent {
            // A saved layout needs the current main's canonical anchor. Without it, retain the
            // deterministic planned geometry instead of mixing unrelated coordinate systems.
            guard let canonicalOffset else { continue }
            if restoreIDs.contains(display.id) {
                if let saved = remembered[display.id] {
                    frames[display.id] = saved.frame
                } else if let planned = frames[display.id] {
                    // Legacy main promotion already normalizes its planned origins. Lift that
                    // fallback into the same canonical frame as the known source before anchoring.
                    frames[display.id] = try planned.translated(
                        byX: Int64(canonicalOffset.x) - Int64(plannedMainFrame?.x ?? currentMain?.frame.x ?? 0),
                        byY: Int64(canonicalOffset.y) - Int64(plannedMainFrame?.y ?? currentMain?.frame.y ?? 0))
                }
            } else {
                frames[display.id] = try display.frame.translated(
                    byX: Int64(canonicalOffset.x), byY: Int64(canonicalOffset.y))
            }
        }
        // An explicit main change must anchor the target, not the old main's live origin.
        let anchor = mainID.flatMap { frames[$0] } ?? DisplayFrame(x: 0, y: 0, width: 0, height: 0)
        var result = operations.filter { if case .setMirror = $0 { true } else { false } }
        let defaults = Set(operations.compactMap { operation -> DisplayID? in
            if case let .restoreDefaultMode(display) = operation { display } else { nil }
        })
        for display in independent where restoreIDs.contains(display.id) || defaults.contains(display.id) {
            if let saved = remembered[display.id], let mode = saved.mode {
                result.append(.restoreMode(display: display.id, mode: mode, rotation: saved.rotation))
            } else { result.append(.restoreDefaultMode(display: display.id)) }
        }
        for display in independent {
            guard let frame = frames[display.id] else { continue }
            let translated = try frame.translated(byX: -Int64(anchor.x), byY: -Int64(anchor.y))
            result.append(.setOrigin(display: display.id, x: translated.x, y: translated.y))
        }
        return result
    }

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
            operations.append(.restoreDefaultMode(display: target))
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
            .restoreDefaultMode(display: target),
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
            operations.append(.restoreDefaultMode(display: source))
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

        // Redirect followers too: a display cannot remain a mirror source after becoming a follower.
        for display in displays where display.id != source {
            if display.role == .mirror(source: target) {
                operations.append(.setMirror(display: display.id, source: source))
            }
        }
        operations.append(.setMirror(display: target, source: source))
        return operations
    }
}
