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
                isActive: CGDisplayIsActive(rawID) != 0,
                mode: CGDisplayCopyDisplayMode(rawID).map(portableMode),
                rotation: CGDisplayRotation(rawID),
                isInMirrorSet: CGDisplayIsInMirrorSet(rawID) != 0
            )
        }
    }

    func apply(_ operations: [DisplayConfigurationOperation]) async throws {
        guard !operations.isEmpty else { return }
        let rawDisplays = try onlineDisplayIDs()
        let stableIDs = try stableIDMap(for: rawDisplays)
        let rawByStableID = Dictionary(uniqueKeysWithValues: stableIDs.map { ($0.value, $0.key) })
        DisplayDiagnostics.shared.record("native.mapping", operations: operations,
            details: Dictionary(uniqueKeysWithValues: rawByStableID.map { ($0.key.rawValue, String($0.value)) }))
        // Mode catalogs are read before the transaction opens so the transaction only applies
        // decisions that were already made.
        var restoredModes: [DisplayID: CGDisplayMode] = [:]
        for operation in operations {
            let display: DisplayID
            let saved: DisplayMode?
            switch operation {
            case let .restoreDefaultMode(id): display = id; saved = nil
            case let .restoreMode(id, mode, rotation):
                display = id
                saved = mode
                if let rotation, let rawID = rawByStableID[id], CGDisplayRotation(rawID) != rotation {
                    throw DisplayManagerError.systemFailure("Rotation changed for \(id); restore it in macOS Displays settings")
                }
            default: continue
            }
            guard let rawID = rawByStableID[display] else {
                throw DisplayManagerError.displayNotFound(display)
            }
            let catalog = (CGDisplayCopyAllDisplayModes(rawID,
                [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode]) ?? []
            let catalogDetails = catalog.map { mode in
                "\(portableMode(mode)); flags=\(mode.ioFlags); desktopGUI=\(mode.isUsableForDesktopGUI())"
            }.joined(separator: "\n")
            DisplayDiagnostics.shared.record("native.mode-catalog", details: [
                "display": display.rawValue, "rawID": String(rawID), "catalog": catalogDetails,
            ])
            let matched = saved.flatMap { matchingMode($0, in: catalog) }
            let chosen = matched ?? preferredMode(for: rawID, modes: catalog)
            restoredModes[display] = chosen
            DisplayDiagnostics.shared.record("native.mode-selection", details: [
                "display": display.rawValue, "rawID": String(rawID),
                "rotation": String(CGDisplayRotation(rawID)),
                "saved": String(describing: saved), "chosen": String(describing: chosen.map(portableMode)),
                "reason": matched != nil ? "saved-mode-matched" : saved == nil ? "no-saved-mode-default-fallback" : "saved-mode-unavailable-default-fallback",
            ])
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
                case let .restoreDefaultMode(display), let .restoreMode(display, _, _):
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
                let result = CGCancelDisplayConfiguration(configuration)
                DisplayDiagnostics.shared.record("native.cancel", details: ["cgError": String(result.rawValue)])
            }
            throw error
        }
    }

    private func portableMode(_ mode: CGDisplayMode) -> DisplayMode {
        DisplayMode(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                    pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate,
                    ioModeID: mode.ioDisplayModeID)
    }

    private func matchingMode(_ saved: DisplayMode, in modes: [CGDisplayMode]) -> CGDisplayMode? {
        guard saved.isValid else { return nil }
        let usable = modes.filter { $0.isUsableForDesktopGUI() }
        guard let index = DisplayModeSelection.matchingCandidateIndex(for: saved, in: usable.map(portableMode)) else { return nil }
        return usable[index]
    }

    private func preferredMode(for display: CGDirectDisplayID, modes: [CGDisplayMode]) -> CGDisplayMode? {
        let currentModeID = CGDisplayCopyDisplayMode(display)?.ioDisplayModeID
        let rotation = CGDisplayRotation(display)
        let isPortrait = rotation == 90 || rotation == 270
        let candidates = modes.enumerated().filter { _, mode in
            mode.isUsableForDesktopGUI() && (mode.width == mode.height || (mode.height > mode.width) == isPortrait)
        }.map { index, mode in
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
        DisplayDiagnostics.shared.record("native.result", details: ["operation": operation, "cgError": String(result.rawValue)])
        guard result == .success else {
            throw DisplayManagerError.systemFailure("\(operation) returned CGError \(result.rawValue)")
        }
    }
}
