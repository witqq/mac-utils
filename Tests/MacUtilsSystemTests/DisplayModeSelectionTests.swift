import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private func candidate(
    _ index: Int,
    pixels: Int,
    isDefault: Bool = false,
    isNative: Bool = false,
    isCurrent: Bool = false
) -> DisplayModeCandidate {
    DisplayModeCandidate(
        index: index,
        pixelCount: pixels,
        isDefault: isDefault,
        isNative: isNative,
        isCurrent: isCurrent
    )
}

@Test
func mirrorPairModeIsReplacedByThePanelDefaultMode() {
    let catalog = [
        candidate(0, pixels: 1920 * 1080, isCurrent: true),
        candidate(1, pixels: 1440 * 2560, isNative: true),
        candidate(2, pixels: 1440 * 2560, isDefault: true, isNative: true),
    ]

    #expect(DisplayModeSelection.preferredCandidateIndex(in: catalog) == 2)
}

@Test
func nativeModeIsUsedWhenNoDefaultModeExists() {
    let catalog = [
        candidate(0, pixels: 1920 * 1080, isCurrent: true),
        candidate(1, pixels: 720 * 1280, isNative: true),
        candidate(2, pixels: 1440 * 2560, isNative: true),
    ]

    #expect(DisplayModeSelection.preferredCandidateIndex(in: catalog) == 2)
}

@Test
func currentDefaultModeAndEmptyCatalogSelectNothing() {
    let alreadyDefault = [
        candidate(0, pixels: 1920 * 1080),
        candidate(1, pixels: 1440 * 2560, isDefault: true, isCurrent: true),
    ]
    let noFlags = [
        candidate(0, pixels: 1920 * 1080, isCurrent: true),
        candidate(1, pixels: 2560 * 1440),
    ]

    #expect(DisplayModeSelection.preferredCandidateIndex(in: alreadyDefault) == nil)
    #expect(DisplayModeSelection.preferredCandidateIndex(in: noFlags) == nil)
    #expect(DisplayModeSelection.preferredCandidateIndex(in: []) == nil)
}

@Test
func equalDefaultModesResolveToTheFirstCatalogEntry() {
    let catalog = [
        candidate(0, pixels: 1440 * 2560, isDefault: true),
        candidate(1, pixels: 1440 * 2560, isDefault: true),
        candidate(2, pixels: 1920 * 1080, isCurrent: true),
    ]

    #expect(DisplayModeSelection.preferredCandidateIndex(in: catalog) == 0)
}

@Test
func savedModeMatchingPreservesScalingRefreshAndOrientationAcrossCatalogIdentifierChanges() {
    let saved = DisplayMode(width: 1440, height: 2560, pixelWidth: 1440, pixelHeight: 2560, refreshRate: 144, ioModeID: 44)
    let changedID = DisplayMode(width: 1440, height: 2560, pixelWidth: 1440, pixelHeight: 2560, refreshRate: 144, ioModeID: 99)
    let landscape = DisplayMode(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 144, ioModeID: 44)
    let scaled = DisplayMode(width: 1440, height: 2560, pixelWidth: 2880, pixelHeight: 5120, refreshRate: 144, ioModeID: 44)
    let slower = DisplayMode(width: 1440, height: 2560, pixelWidth: 1440, pixelHeight: 2560, refreshRate: 60, ioModeID: 44)
    #expect(DisplayModeSelection.matchingCandidateIndex(for: saved, in: [landscape, scaled, slower, changedID]) == 3)
    #expect(DisplayModeSelection.matchingCandidateIndex(for: saved, in: [changedID, saved]) == 1)
    #expect(DisplayModeSelection.matchingCandidateIndex(for: saved, in: [landscape, scaled, slower]) == nil)
}
