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
