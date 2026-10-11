import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private final class FixtureStorageAccess: StorageResourceAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var failTrashNames: Set<String> = []
    private var stale = false
    private var relocations: [String: (URL, Bool)] = [:]
    private var failedBookmarkPaths = Set<String>()
    private var expectedScope: String?
    private var openScopes: [String] = []
    private var mismatchedStops = 0
    private var opened: [URL] = []
    private var revealed: [URL] = []
    let bin: URL
    init(bin: URL) { self.bin = bin }
    var activeScopes: Int { lock.withLock { active } }
    var scopeStopMismatches: Int { lock.withLock { mismatchedStops } }
    var openedDirectories: [URL] { lock.withLock { opened } }
    var revealedItems: [URL] { lock.withLock { revealed } }
    func relocateBookmark(from old: URL, to new: URL, stale: Bool) {
        lock.withLock { relocations[old.path] = (new, stale) }
    }
    func expectScope(_ url: URL?) { lock.withLock { expectedScope = url.map(Self.scopeKey) } }
    func failBookmark(at url: URL) { lock.withLock { _ = failedBookmarkPaths.insert(url.path) } }
    private static func scopeKey(_ url: URL) -> String { url.relativeString + "|" + (url.baseURL?.absoluteString ?? "") }
    func failTrash(named name: String) { lock.withLock { _ = failTrashNames.insert(name) } }
    func markStale() { lock.withLock { stale = true } }
    func bookmark(for url: URL) throws -> Data {
        lock.withLock { stale = false }
        return Data(url.path.utf8)
    }
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        let path = String(decoding: bookmark, as: UTF8.self)
        return try lock.withLock {
            if failedBookmarkPaths.contains(path) { throw StorageServiceError.access("Injected expired bookmark") }
            if let relocated = relocations[path] { return relocated }
            return (URL(fileURLWithPath: path), stale)
        }
    }
    func start(_ url: URL) throws -> Bool {
        try lock.withLock {
            let key = Self.scopeKey(url)
            if let expectedScope, key != expectedScope { throw StorageServiceError.access("The supplied security-scoped URL representation was not used") }
            active += 1
            openScopes.append(key)
            return true
        }
    }
    func stop(_ url: URL) {
        lock.withLock {
            active -= 1
            if let index = openScopes.firstIndex(of: Self.scopeKey(url)) { openScopes.remove(at: index) }
            else { mismatchedStops += 1 }
        }
    }
    func trash(_ url: URL) throws {
        if lock.withLock({ failTrashNames.contains(url.lastPathComponent) }) {
            throw StorageServiceError.access("Injected Trash permission denial")
        }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
    }
    func reveal(_ url: URL) async throws { lock.withLock { revealed.append(url) } }
    func openDirectory(_ url: URL) async throws { lock.withLock { opened.append(url) } }
}

private struct StorageServiceFixture {
    let base: URL
    let root: URL
    let grantsURL: URL
    let cacheURL: URL
    let access: FixtureStorageAccess
    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        base = repository.appending(path: "agent_temp_files_local/storage-service-test-\(UUID())")
        root = base.appending(path: "root")
        grantsURL = base.appending(path: "support/grants.json")
        cacheURL = base.appending(path: "cache/snapshots.json")
        access = FixtureStorageAccess(bin: base.appending(path: "fixture-trash"))
        try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 11).write(to: root.appending(path: "nested/a.dat"))
        try Data(repeating: 2, count: 17).write(to: root.appending(path: "b.dat"))
    }
    func service(maximumCachedRoots: Int = 12) -> StorageService {
        StorageService(grantsURL: grantsURL, cacheURL: cacheURL, resourceAccess: access, maximumCachedRoots: maximumCachedRoots)
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Test func storageCacheReopensWithoutTraversingAndClearingRetainsGrants() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let first = fixture.service()
    let grant = try await first.selectFolder(fixture.root)
    let scanned = try await first.scan(grant) { _ in }
    try FileManager.default.removeItem(at: fixture.root)
    let restarted = fixture.service()
    let cached = try await restarted.cachedSnapshot(for: grant)
    #expect(cached?.id == scanned.id)
    #expect(cached?.root?.logicalBytes == 28)
    try await restarted.clearCache()
    #expect(try await restarted.cachedSnapshot(for: grant) == nil)
    #expect(try await fixture.service().grants() == [grant])
    #expect(fixture.access.activeScopes == 0)
}

@Test func explicitStorageRefreshFindsNestedChangesDespiteUnchangedRootTimestamp() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let old = try await service.scan(grant) { _ in }
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.root.path)
    try Data(repeating: 4, count: 91).write(to: fixture.root.appending(path: "nested/a.dat"))
    try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: fixture.root.path)
    #expect(try await service.cachedSnapshot(for: grant)?.id == old.id)
    let fresh = try await service.scan(grant) { _ in }
    #expect(fresh.root?.logicalBytes == 108)
    #expect(fresh.id != old.id)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageTrashRejectsReplacedItemsAndSymbolicLinkAncestors() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let file = try #require(snapshot.nodes.first { $0.relativePath == "b.dat" })
    let original = fixture.root.appending(path: "b.dat")
    try FileManager.default.moveItem(at: original, to: fixture.base.appending(path: "original-b.dat"))
    try Data("replacement".utf8).write(to: original)
    let nested = try #require(snapshot.largestItems().first { $0.relativePath == "nested/a.dat" })
    let outside = fixture.base.appending(path: "outside")
    try FileManager.default.moveItem(at: fixture.root.appending(path: "nested"), to: outside)
    try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "nested"), withDestinationURL: outside)
    let result = try await service.trash(nodeIDs: [file.id, nested.id, 0], in: snapshot)
    #expect(result.trashedNodeIDs.isEmpty)
    #expect(result.failures.count == 3)
    #expect(try Data(contentsOf: original) == Data("replacement".utf8))
    #expect(FileManager.default.fileExists(atPath: outside.appending(path: "a.dat").path))
    #expect(try await service.cachedSnapshot(for: grant)?.id == snapshot.id)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageTrashReportsPerItemFailuresAndInvalidatesOverlappingRoots() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let rootGrant = try await service.selectFolder(fixture.root)
    let childGrant = try await service.selectFolder(fixture.root.appending(path: "nested"))
    let snapshot = try await service.scan(rootGrant) { _ in }
    _ = try await service.scan(childGrant) { _ in }
    let a = try #require(snapshot.largestItems().first { $0.relativePath == "nested/a.dat" })
    let b = try #require(snapshot.nodes.first { $0.relativePath == "b.dat" })
    fixture.access.failTrash(named: "b.dat")
    let result = try await service.trash(nodeIDs: [a.id, b.id], in: snapshot)
    #expect(result.trashedNodeIDs == [a.id])
    #expect(result.failures.map(\.nodeID) == [b.id])
    #expect(Set(result.invalidatedGrantIDs) == Set([rootGrant.id, childGrant.id]))
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "nested/a.dat").path))
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "b.dat").path))
    #expect(try await service.cachedSnapshot(for: rootGrant) == nil)
    #expect(try await fixture.service().cachedSnapshot(for: childGrant) == nil)
    #expect(fixture.access.activeScopes == 0)
}

@Test func incompleteAndCancelledStorageScansPreserveThePreviousCompleteCache() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let good = try await service.scan(grant) { _ in }
    let incomplete = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        scanOperation: { root, id, progress in
            let snapshot = try await StorageScanner().scan(rootURL: root, grantID: id, progress: progress)
            return StorageSnapshot(grantID: id, rootPath: snapshot.rootPath, rootIdentity: snapshot.rootIdentity,
                nodes: snapshot.nodes, issues: [StorageScanIssue(path: "nested", reason: .permissionDenied, message: "Fixture denial")])
        })
    let partial = try await incomplete.scan(grant) { _ in }
    #expect(!partial.isComplete)
    #expect(try await incomplete.cachedSnapshot(for: grant)?.id == good.id)
    let cancelled = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        scanOperation: { _, _, _ in throw CancellationError() })
    await #expect(throws: CancellationError.self) { try await cancelled.scan(grant) { _ in } }
    #expect(try await cancelled.cachedSnapshot(for: grant)?.id == good.id)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageCacheRetentionEvictsOldestRootAndGrantRemovalPersists() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service(maximumCachedRoots: 1)
    let a = try await service.selectFolder(fixture.root)
    let b = try await service.selectFolder(fixture.root.appending(path: "nested"))
    _ = try await service.scan(a) { _ in }
    _ = try await service.scan(b) { _ in }
    #expect(try await service.cachedSnapshot(for: a) == nil)
    #expect(try await service.cachedSnapshot(for: b) != nil)
    try await service.removeGrant(b)
    #expect(try await fixture.service().grants() == [a])
    #expect(fixture.access.activeScopes == 0)
}

@Test func staleStorageBookmarksRenewAndRevealBalancesScope() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    fixture.access.markStale()
    let snapshot = try await service.scan(grant) { _ in }
    let file = try #require(snapshot.nodes.first { $0.relativePath == "b.dat" })
    try await service.reveal(nodeID: file.id, in: snapshot)
    #expect(fixture.access.activeScopes == 0)
    #expect(try await fixture.service().grants() == [grant])
}

private actor StorageScanGate {
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    private var resumeScan: CheckedContinuation<Void, Never>?
    private var calls = 0
    func isFirstCall() -> Bool { calls += 1; return calls == 1 }
    func pause() async {
        started = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { resumeScan = $0 }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { resumeScan?.resume(); resumeScan = nil }
}

@Test func clearingStorageCacheDuringAnActiveScanDoesNotRepopulateIt() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let gate = StorageScanGate()
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        scanOperation: { root, id, progress in
            let result = try await StorageScanner().scan(rootURL: root, grantID: id, progress: progress)
            await gate.pause()
            return result
        })
    let grant = try await service.selectFolder(fixture.root)
    let running = Task { try await service.scan(grant) { _ in } }
    await gate.waitForStart()
    try await service.clearCache()
    await gate.release()
    let completed = try await running.value
    #expect(completed.root?.logicalBytes == 28)
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(try await fixture.service().cachedSnapshot(for: grant) == nil)
    #expect(fixture.access.activeScopes == 0)
}

@Test func concurrentStorageFolderSelectionsRetainBothPersistedGrants() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    async let root = service.selectFolder(fixture.root)
    async let nested = service.selectFolder(fixture.root.appending(path: "nested"))
    let expected = try await Set([root, nested])
    #expect(try await Set(service.grants()) == expected)
    #expect(try await Set(fixture.service().grants()) == expected)
    #expect(fixture.access.activeScopes == 0)
}

@Test func failedStorageGrantPersistenceDoesNotAdoptTheUnwrittenGrant() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let original = try await service.selectFolder(fixture.root)
    try FileManager.default.removeItem(at: fixture.grantsURL)
    try FileManager.default.createDirectory(at: fixture.grantsURL, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) {
        try await service.selectFolder(fixture.root.appending(path: "nested"))
    }
    #expect(try await service.grants() == [original])
    #expect(fixture.access.activeScopes == 0)
}

private final class NativeFixtureTrashAccess: StorageResourceAccess, @unchecked Sendable {
    let native = NativeStorageResourceAccess()
    private let lock = NSLock()
    private var result: URL?
    var resultingTrashURL: URL? { lock.withLock { result } }
    func bookmark(for url: URL) throws -> Data { try native.bookmark(for: url) }
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) { try native.resolve(bookmark) }
    func start(_ url: URL) throws -> Bool { try native.start(url) }
    func stop(_ url: URL) { native.stop(url) }
    func reveal(_ url: URL) async throws { try await native.reveal(url) }
    func trash(_ url: URL) throws {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        lock.withLock { self.result = result as URL? }
    }
}

@Test func nativeStorageTrashMovesOnlyAnAgentCreatedFixtureToTrash() async throws {
    let fixture = try StorageServiceFixture()
    let access = NativeFixtureTrashAccess()
    defer {
        if let result = access.resultingTrashURL { try? FileManager.default.removeItem(at: result) }
        fixture.cleanup()
    }
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: access)
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let file = try #require(snapshot.nodes.first { $0.relativePath == "b.dat" })
    let result = try await service.trash(nodeIDs: [file.id], in: snapshot)
    #expect(result.trashedNodeIDs == [file.id])
    #expect(result.failures.isEmpty)
    let moved = try #require(access.resultingTrashURL)
    #expect(try Data(contentsOf: moved) == Data(repeating: 2, count: 17))
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "b.dat").path))
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "nested/a.dat").path))
}

@Test func olderStorageScanFinishingLastCannotOverwriteTheNewerSnapshot() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let gate = StorageScanGate()
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        scanOperation: { root, id, progress in
            let first = await gate.isFirstCall()
            let snapshot = try await StorageScanner().scan(rootURL: root, grantID: id, progress: progress)
            if first { await gate.pause() }
            return snapshot
        })
    let grant = try await service.selectFolder(fixture.root)
    let old = Task { try await service.scan(grant) { _ in } }
    await gate.waitForStart()
    try Data(repeating: 8, count: 91).write(to: fixture.root.appending(path: "nested/a.dat"))
    let newer = try await service.scan(grant) { _ in }
    await gate.release()
    let older = try await old.value
    #expect(older.root?.logicalBytes == 28)
    #expect(newer.root?.logicalBytes == 108)
    #expect(try await fixture.service().cachedSnapshot(for: grant)?.id == newer.id)
}

@Test func oversizedStorageSnapshotDoesNotEvictThePreviousUsableCache() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access, maximumCacheBytes: 8_192)
    let grant = try await service.selectFolder(fixture.root)
    let original = try await service.scan(grant) { _ in }
    #expect(try await service.cachedSnapshot(for: grant)?.id == original.id)
    for index in 0..<40 {
        try Data([1]).write(to: fixture.root.appending(path: "longer-fixture-file-name-\(index).dat"))
    }
    let uncached = try await service.scan(grant) { _ in }
    #expect(uncached.nodes.count > original.nodes.count)
    #expect(try await service.cachedSnapshot(for: grant)?.id == original.id)
    #expect(try Data(contentsOf: fixture.cacheURL).count <= 8_192)
}

@Test func corruptStorageCacheReportsAnErrorAndCanBeClearedWithoutRevokingGrants() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    try FileManager.default.createDirectory(at: fixture.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"schemaVersion\":99,\"snapshots\":[]}".utf8).write(to: fixture.cacheURL)
    await #expect(throws: StorageServiceError.self) { try await service.cachedSnapshot(for: grant) }
    try await service.clearCache()
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(try await service.grants() == [grant])
}

@Test func storageTrashStillReportsMovedItemsWhenCacheInvalidationCannotBePersisted() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let file = try #require(snapshot.nodes.first { $0.relativePath == "b.dat" })
    try FileManager.default.removeItem(at: fixture.cacheURL)
    try FileManager.default.createDirectory(at: fixture.cacheURL, withIntermediateDirectories: false)
    let result = try await service.trash(nodeIDs: [file.id], in: snapshot)
    #expect(result.trashedNodeIDs == [file.id])
    #expect(result.failures.isEmpty)
    #expect(result.cacheInvalidationError != nil)
    #expect(result.invalidatedGrantIDs == [grant.id])
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "b.dat").path))
}

@Test(arguments: ["malformed JSON", "{\"schemaVersion\":99,\"entries\":[]}"])
func corruptStorageGrantsCannotBeRecoveredByOrdinaryReselection(archive: String) async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let first = fixture.service()
    let grant = try await first.selectFolder(fixture.root)
    _ = try await first.scan(grant) { _ in }
    let corrupt = Data(archive.utf8)
    try corrupt.write(to: fixture.grantsURL)
    let restarted = fixture.service()
    await #expect(throws: StorageServiceError.self) { try await restarted.selectFolder(fixture.root) }
    #expect(try Data(contentsOf: fixture.grantsURL) == corrupt)
    #expect(try Data(contentsOf: fixture.root.appending(path: "b.dat")) == Data(repeating: 2, count: 17))
}

@Test(arguments: ["malformed JSON", "{\"schemaVersion\":99,\"entries\":[]}"])
func storageResetSavedLocationsRecoversCorruptGrantsAndPreservesScannedFiles(archive: String) async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let first = fixture.service()
    let oldGrant = try await first.selectFolder(fixture.root)
    let oldSnapshot = try await first.scan(oldGrant) { _ in }
    try Data(archive.utf8).write(to: fixture.grantsURL)
    let restarted = fixture.service()
    await #expect(throws: StorageServiceError.self) { try await restarted.grants() }
    try await restarted.resetSavedLocations()
    #expect(try await restarted.grants().isEmpty)
    #expect(try await fixture.service().grants().isEmpty)
    let selected = try await restarted.selectFolder(fixture.root)
    #expect(selected.id != oldGrant.id)
    #expect(try await restarted.cachedSnapshot(for: selected) == nil)
    let fresh = try await restarted.scan(selected) { _ in }
    #expect(fresh.id != oldSnapshot.id)
    #expect(fresh.root?.logicalBytes == 28)
    #expect(try Data(contentsOf: fixture.root.appending(path: "b.dat")) == Data(repeating: 2, count: 17))
    #expect(try Data(contentsOf: fixture.root.appending(path: "nested/a.dat")) == Data(repeating: 1, count: 11))
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageResetSavedLocationsPreservesGrantsWhenTheirReplacementCannotBeSaved() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    _ = try await service.scan(grant) { _ in }
    try FileManager.default.removeItem(at: fixture.grantsURL)
    try FileManager.default.createDirectory(at: fixture.grantsURL, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await service.resetSavedLocations() }
    #expect(try await service.grants() == [grant])
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "b.dat").path))
}

@Test func storageResetSavedLocationsPreservesGrantsAndCacheWhenCacheReplacementFails() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let savedGrants = try Data(contentsOf: fixture.grantsURL)
    try FileManager.default.removeItem(at: fixture.cacheURL)
    try FileManager.default.createDirectory(at: fixture.cacheURL, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await service.resetSavedLocations() }
    #expect(try await service.grants() == [grant])
    #expect(try await service.cachedSnapshot(for: grant)?.id == snapshot.id)
    #expect(try Data(contentsOf: fixture.grantsURL) == savedGrants)
}

@Test func storageResetSavedLocationsPreventsAnActiveScanRestoringForgottenMetadata() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let gate = StorageScanGate()
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        scanOperation: { root, id, progress in
            let result = try await StorageScanner().scan(rootURL: root, grantID: id, progress: progress)
            await gate.pause()
            return result
        })
    let grant = try await service.selectFolder(fixture.root)
    let active = Task { try await service.scan(grant) { _ in } }
    await gate.waitForStart()
    try await service.resetSavedLocations()
    await gate.release()
    _ = try await active.value
    #expect(try await service.grants().isEmpty)
    let newGrant = try await service.selectFolder(fixture.root)
    #expect(try await service.cachedSnapshot(for: newGrant) == nil)
    #expect(try await fixture.service().cachedSnapshot(for: newGrant) == nil)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageTrashProtectsTheAccountHomeWhenFoundationHomeIsTheSandboxContainer() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let accountHome = fixture.root.appending(path: "account-home")
    let applicationHome = accountHome.appending(path: "Library/Containers/test.storage/Data")
    try FileManager.default.createDirectory(at: applicationHome, withIntermediateDirectories: true)
    let original = Data("preserve the home".utf8)
    let userFile = accountHome.appending(path: "personal.dat")
    try original.write(to: userFile)
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        userHomeDirectoryProvider: { accountHome }, applicationHomeDirectoryProvider: { applicationHome })
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let home = try #require(snapshot.nodes.first { $0.relativePath == "account-home" })
    let result = try await service.trash(nodeIDs: [home.id], in: snapshot)
    #expect(result.trashedNodeIDs.isEmpty)
    #expect(result.failures.map(\.nodeID) == [home.id])
    #expect(FileManager.default.fileExists(atPath: userFile.path))
    #expect(try Data(contentsOf: userFile) == original)
    let containerGrant = try await service.selectFolder(applicationHome.deletingLastPathComponent())
    let containerSnapshot = try await service.scan(containerGrant) { _ in }
    let container = try #require(containerSnapshot.nodes.first { $0.relativePath == "Data" })
    let containerResult = try await service.trash(nodeIDs: [container.id], in: containerSnapshot)
    #expect(containerResult.trashedNodeIDs.isEmpty)
    #expect(containerResult.failures.map(\.nodeID) == [container.id])
    #expect(FileManager.default.fileExists(atPath: applicationHome.path))
}

@Test func storageTrashRefusesCleanupWhenTheAccountHomeCannotBeResolved() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        userHomeDirectoryProvider: { nil })
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let selected = try #require(snapshot.nodes.first { $0.relativePath == "b.dat" })
    let result = try await service.trash(nodeIDs: [selected.id], in: snapshot)
    #expect(result.trashedNodeIDs.isEmpty)
    #expect(result.failures.map(\.nodeID) == [selected.id])
    #expect(try Data(contentsOf: fixture.root.appending(path: "b.dat")) == Data(repeating: 2, count: 17))
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageTrashProtectsTheAccountHomePathWhenItIsASymbolicLink() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let target = fixture.base.appending(path: "relocated-account-home")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let contents = Data("keep account files".utf8)
    try contents.write(to: target.appending(path: "personal.dat"))
    let accountHome = fixture.root.appending(path: "account-home-link")
    try FileManager.default.createSymbolicLink(at: accountHome, withDestinationURL: target)
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        userHomeDirectoryProvider: { accountHome })
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let homeLink = try #require(snapshot.nodes.first { $0.relativePath == "account-home-link" })
    let result = try await service.trash(nodeIDs: [homeLink.id], in: snapshot)
    #expect(result.trashedNodeIDs.isEmpty)
    #expect(result.failures.map(\.nodeID) == [homeLink.id])
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: accountHome.path) == target.path)
    #expect(try Data(contentsOf: target.appending(path: "personal.dat")) == contents)
}

@Test(arguments: [true, false])
func storageMovedBookmarkUpdatesRosterAndKeepsOriginalGrantHandlesUsable(stale: Bool) async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let original = try await service.selectFolder(fixture.root)
    let historical = try await service.scan(original) { _ in }
    let moved = fixture.base.appending(path: "renamed-folder")
    try FileManager.default.moveItem(at: fixture.root, to: moved)
    fixture.access.relocateBookmark(from: fixture.root, to: moved, stale: stale)
    let beforeRefresh = try await service.cachedSnapshot(for: original)
    #expect(beforeRefresh?.id == historical.id)
    #expect(beforeRefresh?.rootPath == fixture.root.path)
    let refreshed = try await service.scan(original) { _ in }
    let expected = StorageGrant(id: original.id, path: moved.path, name: moved.lastPathComponent)
    #expect(try await service.grants() == [expected])
    #expect(try await fixture.service().grants() == [expected])
    #expect(refreshed.rootPath == moved.path)
    #expect(try await service.cachedSnapshot(for: original)?.id == refreshed.id)
    #expect(try await service.selectFolder(moved).id == original.id)
    #expect(try await service.grants().count == 1)
    try FileManager.default.removeItem(at: moved)
    #expect(try await fixture.service().cachedSnapshot(for: original)?.id == refreshed.id)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageReselectingMovedFolderBeforeScanningRetainsTheExistingGrantIdentity() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let original = try await service.selectFolder(fixture.root)
    let moved = fixture.base.appending(path: "moved-before-refresh")
    try FileManager.default.moveItem(at: fixture.root, to: moved)
    fixture.access.relocateBookmark(from: fixture.root, to: moved, stale: true)
    let selected = try await service.selectFolder(moved)
    #expect(selected.id == original.id)
    #expect(try await service.grants() == [selected])
    #expect(try await fixture.service().grants() == [selected])
}

@Test func storageScopeLeasesUseTheExactSelectedAndResolvedURLRepresentations() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let directoryBase = URL(fileURLWithPath: fixture.base.path, isDirectory: true)
    let selected = URL(fileURLWithPath: "root", isDirectory: true, relativeTo: directoryBase)
    #expect(selected.baseURL != nil)
    #expect(selected.path == fixture.root.path)
    let service = fixture.service()
    fixture.access.expectScope(selected)
    let grant = try await service.selectFolder(selected)
    let resolved = URL(fileURLWithPath: "root", isDirectory: true, relativeTo: directoryBase)
    fixture.access.relocateBookmark(from: fixture.root, to: resolved, stale: true)
    fixture.access.expectScope(resolved)
    let snapshot = try await service.scan(grant) { _ in }
    #expect(snapshot.root?.logicalBytes == 28)
    #expect(fixture.access.activeScopes == 0)
    #expect(fixture.access.scopeStopMismatches == 0)
}

@Test func storageMovedGrantPersistenceFailureKeepsThePreviousRosterAndHistoricalCache() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let old = try await service.scan(grant) { _ in }
    let moved = fixture.base.appending(path: "moved-save-failure")
    try FileManager.default.moveItem(at: fixture.root, to: moved)
    fixture.access.relocateBookmark(from: fixture.root, to: moved, stale: true)
    try FileManager.default.removeItem(at: fixture.grantsURL)
    try FileManager.default.createDirectory(at: fixture.grantsURL, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await service.scan(grant) { _ in } }
    #expect(try await service.grants() == [grant])
    #expect(try await service.cachedSnapshot(for: grant)?.id == old.id)
    #expect(try Data(contentsOf: moved.appending(path: "b.dat")) == Data(repeating: 2, count: 17))
    #expect(fixture.access.activeScopes == 0)
    #expect(fixture.access.scopeStopMismatches == 0)
}

@Test func storageTrashInvalidatesNestedCachedRootsThatMovedWithTheirParent() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let outer = try await service.selectFolder(fixture.root)
    let oldNested = fixture.root.appending(path: "nested")
    let inner = try await service.selectFolder(oldNested)
    _ = try await service.scan(outer) { _ in }
    let historical = try await service.scan(inner) { _ in }
    let moved = fixture.base.appending(path: "moved-enclosing-folder")
    try FileManager.default.moveItem(at: fixture.root, to: moved)
    fixture.access.relocateBookmark(from: fixture.root, to: moved, stale: true)
    fixture.access.relocateBookmark(from: oldNested, to: moved.appending(path: "nested"), stale: true)
    let fresh = try await service.scan(outer) { _ in }
    #expect(try await service.cachedSnapshot(for: inner)?.id == historical.id)
    let file = try #require(fresh.largestItems().first { $0.relativePath == "nested/a.dat" })
    let result = try await service.trash(nodeIDs: [file.id], in: fresh)
    #expect(result.trashedNodeIDs == [file.id])
    #expect(result.failures.isEmpty)
    #expect(Set(result.invalidatedGrantIDs) == Set([outer.id, inner.id]))
    #expect(try await fixture.service().cachedSnapshot(for: inner) == nil)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageExpiredUnrelatedBookmarksDoNotBlockSelectionAndTheirCachesInvalidateConservatively() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let outer = try await service.selectFolder(fixture.root)
    let oldNested = fixture.root.appending(path: "nested")
    let inner = try await service.selectFolder(oldNested)
    _ = try await service.scan(inner) { _ in }
    fixture.access.failBookmark(at: oldNested)
    let separate = fixture.base.appending(path: "separate-root")
    try FileManager.default.createDirectory(at: separate, withIntermediateDirectories: true)
    let newlyAuthorized = try await service.selectFolder(separate)
    #expect(try await service.grants().contains(newlyAuthorized))
    let snapshot = try await service.scan(outer) { _ in }
    let file = try #require(snapshot.nodes.first { $0.relativePath == "b.dat" })
    let result = try await service.trash(nodeIDs: [file.id], in: snapshot)
    #expect(result.failures.isEmpty)
    #expect(result.trashedNodeIDs == [file.id])
    #expect(result.invalidatedGrantIDs.contains(inner.id))
    #expect(try await service.cachedSnapshot(for: inner) == nil)
}

@Test func storageTrashProtectsAncestorsOfAccountAndContainerHomesButAllowsHomeChildren() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let accountHome = fixture.root.appending(path: "account-wrapper/account-home")
    let applicationHome = fixture.root.appending(path: "container-wrapper/Data")
    try FileManager.default.createDirectory(at: accountHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: applicationHome, withIntermediateDirectories: true)
    let personal = accountHome.appending(path: "personal.dat")
    let containerFile = applicationHome.appending(path: "container.dat")
    try Data("preserve personal files".utf8).write(to: personal)
    try Data("preserve application files".utf8).write(to: containerFile)
    try Data("explicit selected cleanup".utf8).write(to: accountHome.appending(path: "discard.dat"))
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        userHomeDirectoryProvider: { accountHome }, applicationHomeDirectoryProvider: { applicationHome })
    let homeGrant = try await service.selectFolder(accountHome)
    let homeSnapshot = try await service.scan(homeGrant) { _ in }
    let discard = try #require(homeSnapshot.nodes.first { $0.relativePath == "discard.dat" })
    let allowed = try await service.trash(nodeIDs: [discard.id], in: homeSnapshot)
    #expect(allowed.trashedNodeIDs == [discard.id])
    let outerGrant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(outerGrant) { _ in }
    let accountParent = try #require(snapshot.nodes.first { $0.relativePath == "account-wrapper" })
    let containerParent = try #require(snapshot.nodes.first { $0.relativePath == "container-wrapper" })
    let denied = try await service.trash(nodeIDs: [accountParent.id, containerParent.id], in: snapshot)
    #expect(denied.trashedNodeIDs.isEmpty)
    #expect(Set(denied.failures.map(\.nodeID)) == Set([accountParent.id, containerParent.id]))
    #expect(try Data(contentsOf: personal) == Data("preserve personal files".utf8))
    #expect(try Data(contentsOf: containerFile) == Data("preserve application files".utf8))
}

@Test func storageDirectoryDrillUsesOriginalGrantWithoutReplacingItsOverviewCache() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let overview = try await service.scan(grant) { _ in }
    let directory = try #require(overview.nodes.first { $0.relativePath == "nested" })
    let drill = try await service.scanDirectory(nodeID: directory.id, in: overview) { _ in }
    #expect(drill.grantID == grant.id)
    #expect(drill.rootPath == fixture.root.appending(path: "nested").path)
    #expect(drill.authorizationRootPath == overview.rootPath)
    #expect(drill.authorizationRootIdentity == overview.rootIdentity)
    #expect(drill.rootAncestors == [StoragePathIdentity(relativePath: "", identity: overview.rootIdentity)])
    #expect(drill.root?.logicalBytes == 11)
    #expect(try await service.grants() == [grant])
    #expect(try await fixture.service().cachedSnapshot(for: grant)?.id == overview.id)
    let file = try #require(drill.itemReference(id: 1))
    let result = try await service.trash(items: [file], in: drill)
    #expect(result.trashedNodeIDs == [file.id])
    #expect(result.failures.isEmpty)
    #expect(result.invalidatedGrantIDs == [grant.id])
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "nested/a.dat").path))
    #expect(fixture.access.activeScopes == 0)
    #expect(fixture.access.scopeStopMismatches == 0)
}

@Test func storageCatalogActionsRejectAlteredReferencesAndStillAcceptTheirLegacyIDs() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let overview = try await service.scan(grant) { _ in }
    let real = try #require(overview.largestItems().first { $0.relativePath == "nested/a.dat" })
    #expect(overview.node(id: real.id) == nil)
    let forged = StorageItemReference(id: real.id, name: real.name, relativePath: real.relativePath,
        kind: real.kind, identity: real.identity, totals: .zero, ancestors: real.ancestors)
    await #expect(throws: StorageServiceError.self) { try await service.reveal(item: forged, in: overview) }
    let rejected = try await service.trash(items: [forged], in: overview)
    #expect(rejected.trashedNodeIDs.isEmpty)
    #expect(rejected.failures.map(\.nodeID) == [real.id])
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "nested/a.dat").path))
    try await service.reveal(item: real, in: overview)
    let accepted = try await service.trash(nodeIDs: [real.id], in: overview)
    #expect(accepted.trashedNodeIDs == [real.id])
    #expect(accepted.failures.isEmpty)
}

@Test func storageDirectoryDrillAndItsItemsRejectAnAncestorReplacedWithASymbolicLink() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let overview = try await service.scan(grant) { _ in }
    let directory = try #require(overview.nodes.first { $0.relativePath == "nested" })
    let drill = try await service.scanDirectory(nodeID: directory.id, in: overview) { _ in }
    let file = try #require(drill.itemReference(id: 1))
    let outside = fixture.base.appending(path: "outside-nested")
    try FileManager.default.moveItem(at: fixture.root.appending(path: "nested"), to: outside)
    try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "nested"), withDestinationURL: outside)
    await #expect(throws: StorageServiceError.self) {
        try await service.scanDirectory(nodeID: directory.id, in: overview) { _ in }
    }
    let rejected = try await service.trash(items: [file], in: drill)
    #expect(rejected.trashedNodeIDs.isEmpty)
    #expect(rejected.failures.map(\.nodeID) == [file.id])
    #expect(try Data(contentsOf: outside.appending(path: "a.dat")) == Data(repeating: 1, count: 11))
    #expect(try await service.cachedSnapshot(for: grant)?.id == overview.id)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageOpenDirectoryOpensItsContentsAndTheRootWithoutRevealingTheirParent() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let directory = try #require(snapshot.nodes.first { $0.relativePath == "nested" })
    try await service.openDirectory(nodeID: directory.id, in: snapshot)
    try await service.openDirectory(nodeID: 0, in: snapshot)
    #expect(fixture.access.openedDirectories.map(\.path) == [fixture.root.appending(path: "nested").path, fixture.root.path])
    #expect(fixture.access.revealedItems.isEmpty)
    #expect(fixture.access.activeScopes == 0)
    #expect(fixture.access.scopeStopMismatches == 0)
}

@Test func storageOpenDirectoryRejectsFilesPackagesAndAReplacedRootWithoutOpeningAnything() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let package = fixture.root.appending(path: "Example.app")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let file = try #require(snapshot.nodes.first { $0.relativePath == "b.dat" })
    let app = try #require(snapshot.nodes.first { $0.relativePath == "Example.app" })
    #expect(app.kind == .package)
    await #expect(throws: StorageServiceError.self) { try await service.openDirectory(nodeID: file.id, in: snapshot) }
    await #expect(throws: StorageServiceError.self) { try await service.openDirectory(nodeID: app.id, in: snapshot) }
    try FileManager.default.moveItem(at: fixture.root, to: fixture.base.appending(path: "original-root"))
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    await #expect(throws: StorageServiceError.self) { try await service.openDirectory(nodeID: 0, in: snapshot) }
    #expect(fixture.access.openedDirectories.isEmpty)
    #expect(fixture.access.revealedItems.isEmpty)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageOpenDirectoryRejectsSymlinkAncestorsAndKeepsTheExactGrantScopeBalanced() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.root.appending(path: "nested/deeper"), withIntermediateDirectories: true)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let directory = try #require(snapshot.nodes.first { $0.relativePath == "nested" })
    let drill = try await service.scanDirectory(nodeID: directory.id, in: snapshot) { _ in }
    let deeper = try #require(drill.nodes.first { $0.relativePath == "deeper" })
    let base = URL(fileURLWithPath: fixture.base.path, isDirectory: true)
    let originalScopedURL = URL(fileURLWithPath: "root", isDirectory: true, relativeTo: base)
    fixture.access.relocateBookmark(from: fixture.root, to: originalScopedURL, stale: true)
    fixture.access.expectScope(originalScopedURL)
    let outside = fixture.base.appending(path: "outside-directory")
    try FileManager.default.moveItem(at: fixture.root.appending(path: "nested"), to: outside)
    try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "nested"), withDestinationURL: outside)
    await #expect(throws: StorageServiceError.self) { try await service.openDirectory(nodeID: deeper.id, in: drill) }
    #expect(fixture.access.openedDirectories.isEmpty)
    #expect(fixture.access.activeScopes == 0)
    #expect(fixture.access.scopeStopMismatches == 0)
}

private struct ServiceCloudFixtureReader: StorageResourceReading {
    func hints(at url: URL) throws -> StorageResourceHints {
        var hints = try NativeStorageResourceReader().hints(at: url)
        if url.lastPathComponent == "remote" { hints.isCloudPlaceholder = true }
        return hints
    }
}

@Test func storageMixedLocalFoldersRemainDrillableWhenACloudOnlyDescendantWasSkipped() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.root.appending(path: "remote"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fixture.root.appending(path: "nested/remote"), withIntermediateDirectories: true)
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL, resourceAccess: fixture.access,
        scanOperation: { root, id, progress in
            try await StorageScanner(resourceReader: ServiceCloudFixtureReader()).scan(rootURL: root, grantID: id, progress: progress)
        })
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let nested = try #require(snapshot.nodes.first { $0.relativePath == "nested" })
    let cloudOnly = try #require(snapshot.nodes.first { $0.relativePath == "remote" })
    #expect(snapshot.root?.isCloudPlaceholder == false)
    #expect(!nested.isCloudPlaceholder)
    #expect(cloudOnly.isCloudPlaceholder)
    #expect(!snapshot.isComplete)
    #expect(snapshot.issues.contains { $0.reason == .cloudPlaceholderDirectory })
    let nestedDrill = try await service.scanDirectory(nodeID: nested.id, in: snapshot) { _ in }
    #expect(nestedDrill.rootPath == fixture.root.appending(path: "nested").path)
    let refreshedRoot = try await service.scanDirectory(nodeID: 0, in: snapshot) { _ in }
    #expect(refreshedRoot.rootPath == fixture.root.path)
    await #expect(throws: StorageServiceError.self) { try await service.scanDirectory(nodeID: cloudOnly.id, in: snapshot) { _ in } }
    #expect(fixture.access.activeScopes == 0)
}

private func storageServiceDiagnosticRecords(_ log: StorageDiagnostics) throws -> [[String: Any]] {
    try Data(contentsOf: log.fileURL).split(separator: 0x0A).map {
        try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
}

@Test func storageServiceDiagnosticsDistinguishSavedResultsFromCacheWriteFailures() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let log = StorageDiagnostics(directoryURL: fixture.base.appending(path: "logs"))
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL,
        resourceAccess: fixture.access, diagnostics: log)
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let saved = try storageServiceDiagnosticRecords(log)
    let complete = try #require(saved.last)
    #expect(complete["event"] as? String == "scan.complete")
    #expect((complete["details"] as? [String: String])?["cacheDisposition"] == "saved")
    #expect((complete["details"] as? [String: String])?["visitedItems"] == "3")
    #expect((complete["details"] as? [String: String])?["fileCount"] == "2")
    #expect(try await service.cachedSnapshot(for: grant)?.id == snapshot.id)
    try FileManager.default.removeItem(at: fixture.cacheURL)
    try FileManager.default.createDirectory(at: fixture.cacheURL, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await service.scan(grant) { _ in } }
    let failed = try storageServiceDiagnosticRecords(log)
    let failure = try #require(failed.last)
    #expect(failure["event"] as? String == "scan.failed")
    #expect((failure["details"] as? [String: String])?["phase"] == "saveCache")
    #expect(failure["scanID"] as? String != complete["scanID"] as? String)
    #expect(try await service.cachedSnapshot(for: grant)?.id == snapshot.id)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageServiceDiagnosticsRecordCancelledCatalogProgressWithoutChangingTheCache() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let initial = fixture.service()
    let grant = try await initial.selectFolder(fixture.root)
    let snapshot = try await initial.scan(grant) { _ in }
    let log = StorageDiagnostics(directoryURL: fixture.base.appending(path: "logs"))
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL,
        resourceAccess: fixture.access, diagnostics: log, scanOperation: { root, _, progress in
            await progress(StorageScanProgress(visitedItems: 77, currentPath: root.path + "/last", logicalBytes: 10,
                allocatedBytes: 20, phase: .volumeCatalog, estimatedTotalItems: 100))
            throw CancellationError()
        })
    await #expect(throws: CancellationError.self) { try await service.scan(grant) { _ in } }
    let records = try storageServiceDiagnosticRecords(log)
    let terminal = try #require(records.last)
    #expect(terminal["event"] as? String == "scan.cancelled")
    #expect(!records.contains { $0["event"] as? String == "scan.complete" })
    let details = try #require(terminal["details"] as? [String: String])
    #expect(details["phase"] == "volumeCatalog")
    #expect(details["visitedItems"] == "77")
    #expect(details["currentPath"] == fixture.root.path + "/last")
    #expect(try await service.cachedSnapshot(for: grant)?.id == snapshot.id)
    #expect(fixture.access.activeScopes == 0)
}

@Test func storageZeroIssueCatalogScanPreservesThePreviousCompleteTraversalCache() async throws {
    let fixture = try StorageServiceFixture()
    defer { fixture.cleanup() }
    let initial = fixture.service()
    let grant = try await initial.selectFolder(fixture.root)
    let previous = try await initial.scan(grant) { _ in }
    #expect(previous.isComplete)
    let service = StorageService(grantsURL: fixture.grantsURL, cacheURL: fixture.cacheURL,
        resourceAccess: fixture.access, scanOperation: { root, id, progress in
            let snapshot = try await StorageScanner().scan(rootURL: root, grantID: id, progress: progress)
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            object["savedScanMethod"] = StorageScanMethod.volumeCatalog.rawValue
            return try JSONDecoder().decode(StorageSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        })
    let catalog = try await service.scan(grant) { _ in }
    #expect(catalog.issues.isEmpty)
    #expect(catalog.hasUnverifiedCoverage)
    #expect(!catalog.isComplete)
    #expect(catalog.id != previous.id)
    #expect(try await service.cachedSnapshot(for: grant)?.id == previous.id)
    #expect(try await fixture.service().cachedSnapshot(for: grant)?.id == previous.id)
    #expect(fixture.access.activeScopes == 0)
}
