import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private actor FakeDisplayDriver: DisplayConfigurationDriver {
    private var current: [DisplayDescriptor]
    private(set) var appliedBatches: [[DisplayConfigurationOperation]] = []
    private var failNextApply = false
    private let initial: [DisplayDescriptor]
    private var activeApplies = 0
    private(set) var maximumConcurrentApplies = 0

    init(displays: [DisplayDescriptor]) {
        current = displays
        initial = displays
    }

    func readDisplays() async throws -> [DisplayDescriptor] {
        current
    }

    func failOnNextApply() {
        failNextApply = true
    }
    func replaceDisplays(_ displays: [DisplayDescriptor]) { current = displays }

    func apply(_ operations: [DisplayConfigurationOperation]) async throws {
        activeApplies += 1
        maximumConcurrentApplies = max(maximumConcurrentApplies, activeApplies)
        defer { activeApplies -= 1 }
        for _ in 0..<8 { await Task.yield() }
        var candidate = current
        for operation in operations {
            switch operation {
            case let .setOrigin(display, x, y):
                guard let index = candidate.firstIndex(where: { $0.id == display }) else {
                    throw DisplayManagerError.displayNotFound(display)
                }
                candidate[index].frame.x = x
                candidate[index].frame.y = y
                if x == 0, y == 0 {
                    for other in candidate.indices where candidate[other].role == .main {
                        candidate[other].role = .extended
                    }
                    candidate[index].role = .main
                }
            case let .setMirror(display, source):
                guard let index = candidate.firstIndex(where: { $0.id == display }) else {
                    throw DisplayManagerError.displayNotFound(display)
                }
                if let source {
                    if candidate[index].role == .main,
                       let sourceIndex = candidate.firstIndex(where: { $0.id == source }) {
                        candidate[sourceIndex].role = .main
                    }
                    candidate[index].role = .mirror(source: source)
                    if let sourceIndex = candidate.firstIndex(where: { $0.id == source }),
                       let shared = candidate[index].mode {
                        candidate[sourceIndex].mode = shared
                        candidate[sourceIndex].frame.width = Int32(shared.width)
                        candidate[sourceIndex].frame.height = Int32(shared.height)
                        candidate[index].frame = candidate[sourceIndex].frame
                    }
                } else {
                    candidate[index].role = .extended
                }
            case let .restoreDefaultMode(display):
                guard candidate.contains(where: { $0.id == display }) else {
                    throw DisplayManagerError.displayNotFound(display)
                }
                if let index = candidate.firstIndex(where: { $0.id == display }),
                   let original = initial.first(where: { $0.id == display }), let mode = original.mode {
                    candidate[index].mode = mode
                    candidate[index].frame.width = Int32(mode.width)
                    candidate[index].frame.height = Int32(mode.height)
                }
            case let .restoreMode(display, mode, _):
                let index = try #require(candidate.firstIndex(where: { $0.id == display }))
                candidate[index].mode = mode
                candidate[index].frame.width = Int32(mode.width)
                candidate[index].frame.height = Int32(mode.height)
            }
        }

        if failNextApply {
            failNextApply = false
            throw DisplayManagerError.systemFailure("injected transaction failure")
        }
        current = candidate
        appliedBatches.append(operations)
    }
}

private func portraitPair() -> [DisplayDescriptor] {
    [
        DisplayDescriptor(id: mainID, name: "Horizontal", frame: DisplayFrame(x: 0, y: 0, width: 1920, height: 1080),
            role: .main, mode: DisplayMode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60, ioModeID: 11), rotation: 0),
        DisplayDescriptor(id: rightID, name: "Portrait", frame: DisplayFrame(x: 1920, y: -400, width: 1440, height: 2560),
            role: .extended, mode: DisplayMode(width: 1440, height: 2560, pixelWidth: 1440, pixelHeight: 2560, refreshRate: 144, ioModeID: 44), rotation: 270),
    ]
}

@Test
func horizontalMainMirroredToPortraitRestoresBothModesAndPairwiseOffset() async throws {
    let initial = portraitPair()
    let driver = FakeDisplayDriver(displays: initial)
    let controller = DisplayController(driver: driver)
    try await controller.setMirrorDisplay(mainID, source: rightID)
    try await controller.setExtendedDisplay(mainID)
    let result = try await controller.displays()
    let horizontal = try #require(result.first { $0.id == mainID })
    let portrait = try #require(result.first { $0.id == rightID })
    #expect(horizontal.mode == initial[0].mode)
    #expect(portrait.mode == initial[1].mode)
    #expect(portrait.frame.x - horizontal.frame.x == 1920)
    #expect(portrait.frame.y - horizontal.frame.y == -400)
}

private let mainID = DisplayID("main")
private let leftID = DisplayID("left")
private let rightID = DisplayID("right")

private func threeDisplays() -> [DisplayDescriptor] {
    [
        DisplayDescriptor(
            id: mainID,
            name: "Built-in",
            frame: DisplayFrame(x: 0, y: 0, width: 1920, height: 1080),
            role: .main
        ),
        DisplayDescriptor(
            id: leftID,
            name: "Left",
            frame: DisplayFrame(x: -2560, y: 0, width: 2560, height: 1440),
            role: .extended
        ),
        DisplayDescriptor(
            id: rightID,
            name: "Right",
            frame: DisplayFrame(x: 1920, y: 0, width: 2560, height: 1440),
            role: .extended
        ),
    ]
}

@Test
func listsEveryDisplayFromTheDriver() async throws {
    let driver = FakeDisplayDriver(displays: threeDisplays())
    let controller = DisplayController(driver: driver)

    let displays = try await controller.displays()

    #expect(displays.map(\.id) == [mainID, leftID, rightID])
    #expect(displays.map(\.name) == ["Built-in", "Left", "Right"])
}

@Test
func makingDisplayMainTranslatesTheWholeIndependentLayout() async throws {
    let driver = FakeDisplayDriver(displays: threeDisplays())
    let controller = DisplayController(driver: driver)

    try await controller.setMainDisplay(rightID)

    let displays = try await controller.displays()
    #expect(displays.first(where: { $0.id == rightID })?.role == .main)
    #expect(displays.first(where: { $0.id == rightID })?.frame.x == 0)
    #expect(displays.first(where: { $0.id == mainID })?.frame.x == -1920)
    #expect(displays.first(where: { $0.id == leftID })?.frame.x == -4480)
}

@Test
func mirrorAndExtendUseOneAtomicBatchEach() async throws {
    let driver = FakeDisplayDriver(displays: threeDisplays())
    let controller = DisplayController(driver: driver)

    try await controller.setMirrorDisplay(rightID, source: mainID)
    #expect(try await controller.displays().first(where: { $0.id == rightID })?.role == .mirror(source: mainID))

    try await controller.setExtendedDisplay(rightID)
    let extended = try await controller.displays().first(where: { $0.id == rightID })
    #expect(extended?.role == .extended)
    #expect(extended?.frame.x == 1920)
    #expect(await driver.appliedBatches.count == 2)
    #expect(try await controller.displays().first(where: { $0.id == mainID })?.frame.x == 0)
}

@Test
func extendingAMirroredDisplayRestoresItsIndependentModeAndVerticalOffset() async throws {
    let initial = portraitPair()
    let driver = FakeDisplayDriver(displays: initial)
    let controller = DisplayController(driver: driver)
    try await controller.setMirrorDisplay(rightID, source: mainID)

    try await controller.setExtendedDisplay(rightID)

    let result = try await controller.displays()
    #expect(result.first { $0.id == rightID }?.mode == initial[1].mode)
    #expect(result.first { $0.id == rightID }?.frame == initial[1].frame)
    #expect(result.first { $0.id == mainID }?.mode == initial[0].mode)
}

@Test
func makingAMirroredDisplayMainRestoresBothModesAndTranslatesTheIndependentLayout() async throws {
    let initial = portraitPair()
    let driver = FakeDisplayDriver(displays: initial)
    let controller = DisplayController(driver: driver)
    try await controller.setMirrorDisplay(rightID, source: mainID)

    try await controller.setMainDisplay(rightID)

    let result = try await controller.displays()
    let horizontal = try #require(result.first { $0.id == mainID })
    let portrait = try #require(result.first { $0.id == rightID })
    #expect(portrait.role == .main)
    #expect(portrait.frame.x == 0 && portrait.frame.y == 0)
    #expect(portrait.mode == initial[1].mode)
    #expect(horizontal.mode == initial[0].mode)
    #expect(portrait.frame.x - horizontal.frame.x == 1920)
    #expect(portrait.frame.y - horizontal.frame.y == -400)
}

@Test
func mirroringOntoAMirroredSourceRestoresItsModeAndLeavesTheTargetMirrored() async throws {
    var initial = portraitPair()
    initial.append(threeDisplays()[1])
    let driver = FakeDisplayDriver(displays: initial)
    let controller = DisplayController(driver: driver)
    try await controller.setMirrorDisplay(rightID, source: mainID)

    try await controller.setMirrorDisplay(leftID, source: rightID)

    let result = try await controller.displays()
    #expect(result.first { $0.id == leftID }?.role == .mirror(source: rightID))
    #expect(result.first { $0.id == rightID }?.role == .extended)
    #expect(result.first { $0.id == rightID }?.mode == initial[1].mode)
    #expect(result.first { $0.id == mainID }?.mode == initial[0].mode)
}

@Test
func extendingAnAlreadyIndependentDisplayLeavesTheCurrentConfigurationUntouched() async throws {
    let driver = FakeDisplayDriver(displays: threeDisplays())
    let controller = DisplayController(driver: driver)

    try await controller.setMainDisplay(rightID)
    try await controller.setMirrorDisplay(leftID, source: rightID)
    let before = try await controller.displays()
    try await controller.setExtendedDisplay(mainID)

    #expect(try await controller.displays() == before)
    #expect(await driver.appliedBatches.count == 2)
}

@Test
func rejectsMissingDisplaysSelfMirroringAndExtendingMain() async throws {
    let controller = DisplayController(driver: FakeDisplayDriver(displays: threeDisplays()))
    let missing = DisplayID("missing")

    await #expect(throws: DisplayManagerError.displayNotFound(missing)) {
        try await controller.setMainDisplay(missing)
    }
    await #expect(throws: DisplayManagerError.cannotMirrorDisplayToItself(leftID)) {
        try await controller.setMirrorDisplay(leftID, source: leftID)
    }
    await #expect(throws: DisplayManagerError.cannotExtendMainDisplay(mainID)) {
        try await controller.setExtendedDisplay(mainID)
    }
}

@Test
func failedBatchLeavesTheOriginalConfigurationUntouched() async throws {
    let initial = threeDisplays()
    let driver = FakeDisplayDriver(displays: initial)
    let controller = DisplayController(driver: driver)
    await driver.failOnNextApply()

    await #expect(throws: DisplayManagerError.systemFailure("injected transaction failure")) {
        try await controller.setMainDisplay(rightID)
    }

    #expect(try await controller.displays() == initial)
    #expect(await driver.appliedBatches.isEmpty)
}

@Test
func portraitFollowerAndRepeatedMainChangesKeepIndependentModesAndOffsets() async throws {
    let initial = portraitPair()
    let driver = FakeDisplayDriver(displays: initial)
    let controller = DisplayController(driver: driver)
    for _ in 0..<3 {
        try await controller.setMirrorDisplay(rightID, source: mainID)
        try await controller.setMainDisplay(rightID)
        try await controller.setMirrorDisplay(mainID, source: rightID)
        try await controller.setExtendedDisplay(mainID)
        try await controller.setMainDisplay(mainID)
        let result = try await controller.displays()
        for expected in initial {
            let actual = try #require(result.first { $0.id == expected.id })
            #expect(actual.mode == expected.mode)
            #expect(actual.frame == expected.frame)
            #expect(actual.rotation == expected.rotation)
        }
    }
}

@Test
func rememberedLeftPositionAndThirdDisplayOffsetSurviveMainMirroring() async throws {
    var initial = portraitPair()
    initial[1].frame.x = -1440
    initial.append(DisplayDescriptor(id: leftID, name: "Above", frame: DisplayFrame(x: 200, y: -900, width: 1600, height: 900), role: .extended))
    let controller = DisplayController(driver: FakeDisplayDriver(displays: initial))
    try await controller.setMirrorDisplay(mainID, source: rightID)
    try await controller.setExtendedDisplay(mainID)
    try await controller.setMainDisplay(mainID)
    let result = try await controller.displays()
    for expected in initial { #expect(result.first { $0.id == expected.id }?.frame == expected.frame) }
}

@Test
func sourceWithRemainingFollowersKeepsItsSharedModeUntilLastFollowerLeaves() async throws {
    var initial = portraitPair()
    initial.append(DisplayDescriptor(id: leftID, name: "Third", frame: DisplayFrame(x: -1280, y: 0, width: 1280, height: 720), role: .extended,
        mode: DisplayMode(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60, ioModeID: 70)))
    let controller = DisplayController(driver: FakeDisplayDriver(displays: initial))
    try await controller.setMirrorDisplay(rightID, source: mainID)
    try await controller.setMirrorDisplay(leftID, source: mainID)
    let shared = try await controller.displays().first { $0.id == mainID }?.mode
    try await controller.setExtendedDisplay(rightID)
    #expect(try await controller.displays().first { $0.id == mainID }?.mode == shared)
    #expect(try await controller.displays().first { $0.id == rightID }?.mode == initial[1].mode)
    try await controller.setExtendedDisplay(leftID)
    #expect(try await controller.displays().first { $0.id == mainID }?.mode == initial[0].mode)
}

private actor MemoryDisplayHistoryStore: DisplayHistoryStoring {
    var value = DisplayHistory()
    var failsSaving = false
    func load() async throws -> DisplayHistory { value }
    func save(_ history: DisplayHistory) async throws {
        if failsSaving { throw DisplayManagerError.systemFailure("injected persistence failure") }
        value = history
    }
    func failSaves() { failsSaving = true }
}

@Test
func restartIntoMirroringRestoresDurableIndependentModesWithoutAdoptingSharedState() async throws {
    let initial = portraitPair()
    let driver = FakeDisplayDriver(displays: initial)
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "agent_temp_files_local")
        .appending(path: "display-history-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "history.json")
    let first = DisplayController(driver: driver, historyStore: DisplayHistoryStore(fileURL: file))
    try await first.setMirrorDisplay(mainID, source: rightID)
    let restarted = DisplayController(driver: driver, historyStore: DisplayHistoryStore(fileURL: file))
    try await restarted.setExtendedDisplay(mainID)
    let result = try await restarted.displays()
    #expect(result.first { $0.id == rightID }?.mode == initial[1].mode)
    let horizontal = try #require(result.first { $0.id == mainID })
    let portrait = try #require(result.first { $0.id == rightID })
    #expect(portrait.frame.x - horizontal.frame.x == 1920)
    #expect(portrait.frame.y - horizontal.frame.y == -400)
}

@Test
func failedNativeTransactionNeverSavesCandidateHistoryAndNoopsDoNotReplaceHistory() async throws {
    let driver = FakeDisplayDriver(displays: portraitPair())
    let store = MemoryDisplayHistoryStore()
    let controller = DisplayController(driver: driver, historyStore: store)
    await driver.failOnNextApply()
    await #expect(throws: DisplayManagerError.self) { try await controller.setMirrorDisplay(mainID, source: rightID) }
    #expect(await store.value.displays.isEmpty)
    try await controller.setMirrorDisplay(mainID, source: rightID)
    let saved = await store.value.displays
    try await controller.setMirrorDisplay(mainID, source: rightID)
    #expect(await store.value.displays == saved)
}

@Test
func persistenceFailureReportsAppliedConfigurationInsteadOfCertifyingDurability() async throws {
    let driver = FakeDisplayDriver(displays: portraitPair())
    let store = MemoryDisplayHistoryStore()
    await store.failSaves()
    let controller = DisplayController(driver: driver, historyStore: store)
    await #expect(throws: DisplayManagerError.self) { try await controller.setMirrorDisplay(mainID, source: rightID) }
    #expect(try await controller.displays().first { $0.id == mainID }?.role == .mirror(source: rightID))
    #expect(await store.value.displays.isEmpty)
}

@Test
func concurrentDisplayCommandsSerializeTheirReadPlanAndNativeTransaction() async throws {
    let driver = FakeDisplayDriver(displays: portraitPair())
    let controller = DisplayController(driver: driver)
    async let main: Void = controller.setMainDisplay(rightID)
    async let mirror: Void = controller.setMirrorDisplay(mainID, source: rightID)
    _ = try await (main, mirror)
    #expect(await driver.maximumConcurrentApplies == 1)
    #expect(try await controller.displays().first { $0.id == mainID }?.role == .mirror(source: rightID))
    try await controller.setExtendedDisplay(mainID)
    let result = try await controller.displays()
    let horizontal = try #require(result.first { $0.id == mainID })
    let portrait = try #require(result.first { $0.id == rightID })
    #expect(portrait.frame.x - horizontal.frame.x == 1920)
    #expect(portrait.mode == portraitPair()[1].mode)
}

@Test
func reconnectKeepsStableMonitorHistoryAndNeverReassignsItToANewMonitor() async throws {
    let initial = portraitPair()
    let driver = FakeDisplayDriver(displays: initial)
    let store = MemoryDisplayHistoryStore()
    let controller = DisplayController(driver: driver, historyStore: store)
    try await controller.setMirrorDisplay(mainID, source: rightID)
    let mirrored = try await controller.displays()
    await driver.replaceDisplays([initial[1]])
    await #expect(throws: DisplayManagerError.self) { try await controller.setExtendedDisplay(mainID) }
    let saved = await store.value.displays
    #expect(saved[mainID]?.mode == initial[0].mode)
    await driver.replaceDisplays(mirrored)
    try await controller.setExtendedDisplay(mainID)
    #expect(try await controller.displays().first { $0.id == rightID }?.mode == initial[1].mode)
    let newID = DisplayID("unrelated-monitor")
    let stranger = DisplayDescriptor(id: newID, name: "New", frame: DisplayFrame(x: 0, y: 0, width: 800, height: 600), role: .main)
    await driver.replaceDisplays([stranger])
    try await controller.setMainDisplay(newID)
    #expect(try await controller.displays() == [stranger])
    #expect(await store.value.displays[newID]?.mode == nil)
    #expect(await store.value.displays[newID]?.frame == stranger.frame)
}

@Test
func freshLaunchIntoMirroringUsesDeterministicFallbackWithoutInventingIndependentHistory() async throws {
    var initial = threeDisplays()
    initial[2].role = .mirror(source: mainID)
    initial[2].frame = initial[0].frame
    let store = MemoryDisplayHistoryStore()
    let controller = DisplayController(driver: FakeDisplayDriver(displays: initial), historyStore: store)
    try await controller.setExtendedDisplay(rightID)
    #expect(await store.value.displays[rightID] == nil)
    #expect(await store.value.displays[mainID] == nil)
    let result = try await controller.displays()
    #expect(result.first { $0.id == rightID }?.frame.x == 1920)
}

@Test
func normalRefreshRetainsIndependentStateForASubsequentExternalMirrorTransition() async throws {
    let initial = portraitPair()
    let driver = FakeDisplayDriver(displays: initial)
    let store = MemoryDisplayHistoryStore()
    let controller = DisplayController(driver: driver, historyStore: store)
    _ = try await controller.displays()
    var external = initial
    external[0].role = .mirror(source: rightID)
    external[1].role = .main
    external[1].mode = initial[0].mode
    external[1].frame = initial[0].frame
    external[0].frame = external[1].frame
    await driver.replaceDisplays(external)
    _ = try await controller.displays()
    #expect(await store.value.displays[rightID]?.mode == initial[1].mode)
    try await controller.setExtendedDisplay(mainID)
    let result = try await controller.displays()
    let horizontal = try #require(result.first { $0.id == mainID })
    let portrait = try #require(result.first { $0.id == rightID })
    #expect(portrait.mode == initial[1].mode)
    #expect(portrait.frame.x - horizontal.frame.x == 1920)
    #expect(portrait.frame.y - horizontal.frame.y == -400)
}

@Test
func mirroringAnExistingSourceRedirectsItsFollowersWithoutCreatingAMirrorChain() async throws {
    var initial = portraitPair()
    initial.append(DisplayDescriptor(id: leftID, name: "Third", frame: DisplayFrame(x: -1280, y: 0, width: 1280, height: 720), role: .extended))
    let controller = DisplayController(driver: FakeDisplayDriver(displays: initial))
    try await controller.setMirrorDisplay(leftID, source: mainID)
    try await controller.setMirrorDisplay(mainID, source: rightID)
    let result = try await controller.displays()
    #expect(result.first { $0.id == leftID }?.role == .mirror(source: rightID))
    #expect(result.first { $0.id == mainID }?.role == .mirror(source: rightID))
    #expect(result.first { $0.id == rightID }?.role == .main)
}

@Test(arguments: [false, true], [false, true])
func partialMirrorHistoryKeepsDeterministicPlacement(makeMain: Bool, remembersSource: Bool) async throws {
    let source = portraitPair()[0]
    var follower = portraitPair()[1]
    follower.role = .mirror(source: mainID)
    follower.frame = source.frame
    follower.mode = source.mode
    let store = MemoryDisplayHistoryStore()
    var savedFollower = portraitPair()[1]
    savedFollower.frame.x = 0
    savedFollower.frame.y = 0
    savedFollower.role = .main
    try await store.save(DisplayHistory(displays: remembersSource ? [mainID: source] : [rightID: savedFollower]))
    let controller = DisplayController(driver: FakeDisplayDriver(displays: [source, follower]), historyStore: store)
    if makeMain { try await controller.setMainDisplay(rightID) }
    else { try await controller.setExtendedDisplay(rightID) }
    let actual = try await controller.displays()
    let returnedSource = try #require(actual.first { $0.id == mainID })
    let returnedFollower = try #require(actual.first { $0.id == rightID })
    #expect(returnedFollower.frame.x - returnedSource.frame.x == source.frame.width)
    #expect(returnedFollower.frame.y == returnedSource.frame.y)
    #expect(returnedSource.role == (makeMain ? .extended : .main))
    #expect(returnedFollower.role == (makeMain ? .main : .extended))
}

@Test
func injectedControllerDiagnosticsKeepReadableCorrelatedEventsInTheirFixture() async throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "agent_temp_files_local")
        .appending(path: "display-diagnostics-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = DisplayDiagnostics(directoryURL: directory)
    let controller = DisplayController(driver: FakeDisplayDriver(displays: portraitPair()), diagnostics: diagnostics)
    try await controller.setMirrorDisplay(mainID, source: rightID)
    try await controller.setExtendedDisplay(mainID)
    let lines = try Data(contentsOf: diagnostics.fileURL).split(separator: 0x0A)
    let records = try lines.map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    let transitions = records.filter { ($0["event"] as? String)?.hasPrefix("transition.") == true }
    #expect(transitions.allSatisfy { $0["correlationID"] as? String != nil })
    #expect(Set(transitions.compactMap { $0["correlationID"] as? String }).count == 2)
    #expect(transitions.contains { $0["event"] as? String == "transition.plan" })
    #expect(transitions.filter { $0["event"] as? String == "transition.before" }.count == 2)
    #expect(transitions.filter { $0["event"] as? String == "transition.after" }.count == 2)
}
