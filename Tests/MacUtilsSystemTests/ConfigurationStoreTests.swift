import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private actor FakeConfigurationFileAccess: ConfigurationFileAccess {
    var data: Data?
    var failNextWrite = false

    func read(from url: URL) async throws -> Data? {
        data
    }

    func writeAtomically(_ data: Data, to url: URL) async throws {
        if failNextWrite {
            failNextWrite = false
            throw FakeFileError.injectedWriteFailure
        }
        self.data = data
    }

    func injectWriteFailure() {
        failNextWrite = true
    }

    func seed(_ data: Data) {
        self.data = data
    }
}

private enum FakeFileError: Error {
    case injectedWriteFailure
}

private func configurationFixture() -> AppConfiguration {
    let script = UserScript(
        id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        name: "Mirror desk display",
        source: "mirror-display display=\"right\" source=\"main\""
    )
    return AppConfiguration(
        scripts: [script],
        bindings: [
            ShortcutBinding(
                id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                shortcut: GlobalShortcut(keyCode: 40, modifiers: [.command, .option, .control]),
                scriptID: script.id
            ),
        ]
    )
}

@Test
func savesAndLoadsScriptsAndBindingsAcrossStoreInstances() async throws {
    let file = FakeConfigurationFileAccess()
    let url = URL(fileURLWithPath: "/configuration.json")
    let firstProcessStore = ConfigurationStore(fileURL: url, fileAccess: file)
    let expected = configurationFixture()

    try await firstProcessStore.save(expected)
    let restartedProcessStore = ConfigurationStore(fileURL: url, fileAccess: file)
    let loaded = await restartedProcessStore.load()

    #expect(loaded.configuration == expected)
    #expect(loaded.recoveryError == nil)
}

@Test
func failedAtomicReplacementPreservesThePreviousConfiguration() async throws {
    let file = FakeConfigurationFileAccess()
    let url = URL(fileURLWithPath: "/configuration.json")
    let store = ConfigurationStore(fileURL: url, fileAccess: file)
    let original = configurationFixture()
    try await store.save(original)
    await file.injectWriteFailure()
    var replacement = original
    replacement.scripts[0].name = "Replacement"

    await #expect(throws: ConfigurationStoreError.self) {
        try await store.save(replacement)
    }

    #expect(await store.load().configuration == original)
}

@Test
func invalidConfigurationIsRejectedBeforeItReplacesStoredData() async throws {
    let file = FakeConfigurationFileAccess()
    let store = ConfigurationStore(
        fileURL: URL(fileURLWithPath: "/configuration.json"),
        fileAccess: file
    )
    let original = configurationFixture()
    try await store.save(original)
    let invalid = AppConfiguration(
        scripts: original.scripts,
        bindings: [
            ShortcutBinding(shortcut: GlobalShortcut(keyCode: 1, modifiers: .command), scriptID: UUID()),
        ]
    )

    await #expect(throws: ConfigurationStoreError.self) {
        try await store.save(invalid)
    }

    #expect(await store.load().configuration == original)
}

@Test
func corruptJSONRecoversToEmptyAndReturnsAUserVisibleError() async {
    let file = FakeConfigurationFileAccess()
    await file.seed(Data("not-json".utf8))
    let store = ConfigurationStore(
        fileURL: URL(fileURLWithPath: "/configuration.json"),
        fileAccess: file
    )

    let result = await store.load()

    #expect(result.configuration == .empty)
    guard case .corruptData = result.recoveryError else {
        Issue.record("Expected a corrupt-data recovery error")
        return
    }
}

@Test
func unsupportedSchemaIsNotMigratedAndRecoversSafely() async throws {
    let file = FakeConfigurationFileAccess()
    let future = AppConfiguration(schemaVersion: 99)
    await file.seed(try JSONEncoder().encode(future))
    let store = ConfigurationStore(
        fileURL: URL(fileURLWithPath: "/configuration.json"),
        fileAccess: file
    )

    let result = await store.load()

    #expect(result.configuration == .empty)
    #expect(result.recoveryError == .invalid(.unsupportedSchemaVersion(99)))
}
