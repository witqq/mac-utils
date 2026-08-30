import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private actor FakeDisplayDriver: DisplayConfigurationDriver {
    private var current: [DisplayDescriptor]
    private(set) var appliedBatches: [[DisplayConfigurationOperation]] = []
    private var failNextApply = false

    init(displays: [DisplayDescriptor]) {
        current = displays
    }

    func readDisplays() async throws -> [DisplayDescriptor] {
        current
    }

    func failOnNextApply() {
        failNextApply = true
    }

    func apply(_ operations: [DisplayConfigurationOperation]) async throws {
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
                } else {
                    candidate[index].role = .extended
                }
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
    #expect(await driver.appliedBatches[1].count == 2)
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
