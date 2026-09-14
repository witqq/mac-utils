import AppKit
import ColorSync
import CoreGraphics
import IOKit.graphics
import MacUtilsCore

struct CoreGraphicsDisplayDriver: DisplayConfigurationDriver {
    func readDisplays() async throws -> [DisplayDescriptor] {
        let rawDisplays = try onlineDisplayIDs()
        let stableIDs = try stableIDMap(for: rawDisplays)
        let screenNames = await MainActor.run { namesByDisplayID() }

        return rawDisplays.compactMap { rawID in
            guard let stableID = stableIDs[rawID] else { return nil }
            let bounds = CGDisplayBounds(rawID)
            let mirroredRawID = CGDisplayMirrorsDisplay(rawID)
            let role: DisplayRole
            if CGDisplayIsMain(rawID) != 0 {
                role = .main
            } else if mirroredRawID != kCGNullDirectDisplay,
                      let source = stableIDs[mirroredRawID] {
                role = .mirror(source: source)
            } else {
                role = .extended
            }

            return DisplayDescriptor(
                id: stableID,
                name: screenNames[rawID] ?? fallbackName(for: rawID),
                frame: DisplayFrame(
                    x: Int32(bounds.origin.x),
                    y: Int32(bounds.origin.y),
                    width: Int32(bounds.width),
                    height: Int32(bounds.height)
                ),
                role: role,
                isActive: CGDisplayIsActive(rawID) != 0
            )
        }
    }

    func apply(_ operations: [DisplayConfigurationOperation]) async throws {
        guard !operations.isEmpty else { return }
        let rawDisplays = try onlineDisplayIDs()
        let stableIDs = try stableIDMap(for: rawDisplays)
        let rawByStableID = Dictionary(uniqueKeysWithValues: stableIDs.map { ($0.value, $0.key) })
        // Mode catalogs are read before the transaction opens so the transaction only applies
        // decisions that were already made.
        var restoredModes: [DisplayID: CGDisplayMode] = [:]
        for case let .restoreDefaultMode(display) in operations {
            guard let rawID = rawByStableID[display] else {
                throw DisplayManagerError.displayNotFound(display)
            }
            restoredModes[display] = preferredMode(for: rawID)
        }

        var configuration: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&configuration), operation: "begin transaction")
        guard let configuration else {
            throw DisplayManagerError.systemFailure("CoreGraphics returned no configuration transaction")
        }

        var configurationWasCompleted = false
        do {
            for operation in operations {
                switch operation {
                case let .setOrigin(display, x, y):
                    guard let rawID = rawByStableID[display] else {
                        throw DisplayManagerError.displayNotFound(display)
                    }
                    try check(
                        CGConfigureDisplayOrigin(configuration, rawID, x, y),
                        operation: "set origin for \(display)"
                    )
                case let .setMirror(display, source):
                    guard let rawID = rawByStableID[display] else {
                        throw DisplayManagerError.displayNotFound(display)
                    }
                    let sourceRawID: CGDirectDisplayID
                    if let source {
                        guard let resolved = rawByStableID[source] else {
                            throw DisplayManagerError.displayNotFound(source)
                        }
                        sourceRawID = resolved
                    } else {
                        sourceRawID = kCGNullDirectDisplay
                    }
                    try check(
                        CGConfigureDisplayMirrorOfDisplay(configuration, rawID, sourceRawID),
                        operation: "set mirroring for \(display)"
                    )
                case let .restoreDefaultMode(display):
                    guard let rawID = rawByStableID[display] else {
                        throw DisplayManagerError.displayNotFound(display)
                    }
                    // `nil` means the display already runs its preferred mode (or offers none).
                    guard let mode = restoredModes[display] ?? nil else { continue }
                    try check(
                        CGConfigureDisplayWithDisplayMode(configuration, rawID, mode, nil),
                        operation: "restore default mode for \(display)"
                    )
                }
            }

            let completionResult = CGCompleteDisplayConfiguration(configuration, .permanently)
            configurationWasCompleted = true
            try check(completionResult, operation: "commit transaction")
        } catch {
            if !configurationWasCompleted {
                CGCancelDisplayConfiguration(configuration)
            }
            throw error
        }
    }

    private func preferredMode(for display: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
            return nil
        }
        let currentModeID = CGDisplayCopyDisplayMode(display)?.ioDisplayModeID
        let candidates = modes.enumerated().map { index, mode in
            DisplayModeCandidate(
                index: index,
                pixelCount: mode.pixelWidth * mode.pixelHeight,
                isDefault: mode.ioFlags & UInt32(kDisplayModeDefaultFlag) != 0,
                isNative: mode.ioFlags & UInt32(kDisplayModeNativeFlag) != 0,
                isCurrent: mode.ioDisplayModeID == currentModeID
            )
        }
        guard let index = DisplayModeSelection.preferredCandidateIndex(in: candidates) else {
            return nil
        }
        return modes[index]
    }

    private func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(0, nil, &count), operation: "count online displays")
        var displays = Array(repeating: kCGNullDirectDisplay, count: Int(count))
        try check(
            CGGetOnlineDisplayList(count, &displays, &count),
            operation: "read online displays"
        )
        return Array(displays.prefix(Int(count)))
    }

    private func stableIDMap(
        for displays: [CGDirectDisplayID]
    ) throws -> [CGDirectDisplayID: DisplayID] {
        try Dictionary(uniqueKeysWithValues: displays.map { rawID in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(rawID)?.takeRetainedValue(),
                  let value = CFUUIDCreateString(nil, uuid) as String? else {
                throw DisplayManagerError.systemFailure("Could not create a stable UUID for display \(rawID)")
            }
            return (rawID, DisplayID(value.lowercased()))
        })
    }

    @MainActor
    private func namesByDisplayID() -> [CGDirectDisplayID: String] {
        Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        })
    }

    private func fallbackName(for display: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)
        return String(format: "Display %04X:%04X:%08X", vendor, model, serial)
    }

    private func check(_ result: CGError, operation: String) throws {
        guard result == .success else {
            throw DisplayManagerError.systemFailure("\(operation) returned CGError \(result.rawValue)")
        }
    }
}
