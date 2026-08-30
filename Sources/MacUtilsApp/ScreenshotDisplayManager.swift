import MacUtilsCore

/// Deterministic display data used only by the explicit screenshot launch mode.
actor ScreenshotDisplayManager: DisplayManaging {
    static let mainID = DisplayID("screenshot-main")
    static let deskID = DisplayID("screenshot-desk")

    private var snapshot: [DisplayDescriptor] = [
        DisplayDescriptor(
            id: mainID,
            name: "Built-in Display",
            frame: DisplayFrame(x: 0, y: 0, width: 1_728, height: 1_117),
            role: .main
        ),
        DisplayDescriptor(
            id: deskID,
            name: "Desk Display",
            frame: DisplayFrame(x: 1_728, y: 0, width: 2_560, height: 1_440),
            role: .extended
        ),
    ]

    func displays() async throws -> [DisplayDescriptor] { snapshot }

    func setMainDisplay(_ display: DisplayID) async throws {
        for index in snapshot.indices {
            if snapshot[index].id == display {
                snapshot[index].role = .main
                snapshot[index].frame.x = 0
            } else if snapshot[index].role == .main {
                snapshot[index].role = .extended
            }
        }
    }

    func setExtendedDisplay(_ display: DisplayID) async throws {
        guard let index = snapshot.firstIndex(where: { $0.id == display }) else { return }
        snapshot[index].role = .extended
        snapshot[index].frame.x = display == Self.mainID ? -1_728 : 1_728
    }

    func setMirrorDisplay(_ display: DisplayID, source: DisplayID) async throws {
        guard let index = snapshot.firstIndex(where: { $0.id == display }) else { return }
        snapshot[index].role = .mirror(source: source)
        snapshot[index].frame.x = 0
    }
}
