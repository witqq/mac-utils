import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private final class TreeServiceAccess: StorageResourceAccess, @unchecked Sendable {
    let bin: URL
    private let lock = NSLock()
    private var reveals: [URL] = []
    private var failedTrashNames: Set<String> = []
    var revealed: [URL] { lock.withLock { reveals } }
    init(bin: URL) { self.bin = bin }
    func failTrash(named name: String) { lock.withLock { _ = failedTrashNames.insert(name) } }
    func bookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        (URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), false)
    }
    func start(_ url: URL) throws -> Bool { true }
    func stop(_ url: URL) {}
    func reveal(_ url: URL) async throws { lock.withLock { reveals.append(url) } }
    func openDirectory(_ url: URL) async throws {}
    func trash(_ url: URL) throws {
        if lock.withLock({ failedTrashNames.contains(url.lastPathComponent) }) {
            throw StorageServiceError.access("Injected Trash denial")
        }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: bin.appending(path: UUID().uuidString))
    }
}

@Test func storageServiceTrashUpdatesPersistentTreeWithStableSurvivingIDsWithoutScanning() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("removed/deeper/a", bytes: 13)
    for index in 0..<300 { try fixture.file("kept/deeper/file-\(index)", bytes: index + 1) }
    let counter = TreeScanCounter(), service = fixture.service(counter: counter, allowedScans: 1)
    let grant = try await service.selectFolder(fixture.root)
    let original = try await service.scan(grant) { _ in }
    let roots = try await service.treeChildren(parentID: 0, in: original)
    let removed = try #require(roots.rows.first { $0.name == "removed" })
    let kept = try #require(roots.rows.first { $0.name == "kept" })
    let deeper = try #require(try await service.treeChildren(parentID: kept.id, in: original).rows.first)
    let surviving = try #require(try await service.treeChildren(parentID: deeper.id, in: original,
        metric: .logical, descending: false, limit: 1).rows.first)
    let result = try await service.trash(nodeIDs: [removed.id], in: original)
    let updated = try #require(result.updatedSnapshot)
    #expect(result.trashedNodeIDs == [removed.id] && result.failures.isEmpty)
    #expect(result.invalidatedGrantIDs.isEmpty && result.cacheInvalidationError == nil)
    #expect(updated.id != original.id && updated.scannedAt == original.scannedAt)
    #expect(updated.tree?.formatVersion == 2 && updated.tree?.nodeCount == original.tree?.nodeCount)
    #expect(updated.root?.logicalBytes == 45_150 && updated.root?.fileCount == 300)
    #expect(try await service.treeItem(id: removed.id, in: updated) == nil)
    #expect(try await service.treeItem(id: kept.id, in: updated)?.relativePath == "kept")
    #expect(try await service.treeItem(id: surviving.id, in: updated)?.relativePath == "kept/deeper/file-0")
    let page = try await service.treeChildren(parentID: deeper.id, in: updated, offset: 200, limit: 200)
    #expect(page.totalCount == 300 && page.rows.count == 100)
    #expect(counter.value == 1)
    await service.releaseTree(snapshotID: original.id)
    await service.releaseTree(snapshotID: updated.id)
    try FileManager.default.removeItem(at: fixture.root)
    let restarted = fixture.service(counter: counter, allowedScans: 1)
    let saved = try #require(try await restarted.cachedSnapshot(for: grant))
    #expect(saved == updated)
    #expect(try await restarted.treeChildren(parentID: deeper.id, in: saved, limit: 400).rows.count == 300)
    #expect(counter.value == 1)
    await restarted.releaseTree(snapshotID: updated.id)
}

@Test func storageServicePartialTrashKeepsDeniedItemAndInvalidatesOnlyOtherOverlappingRoots() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("nested/moved", bytes: 11)
    try fixture.file("denied", bytes: 17)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let nestedGrant = try await service.selectFolder(fixture.root.appending(path: "nested"))
    let other = try await service.scan(nestedGrant) { _ in }
    let original = try await service.scan(grant) { _ in }
    let roots = try await service.treeChildren(parentID: 0, in: original)
    let nested = try #require(roots.rows.first { $0.name == "nested" })
    let moved = try #require(try await service.treeChildren(parentID: nested.id, in: original).rows.first)
    let denied = try #require(roots.rows.first { $0.name == "denied" })
    fixture.access.failTrash(named: "denied")
    let result = try await service.trash(nodeIDs: [moved.id, denied.id], in: original)
    let updated = try #require(result.updatedSnapshot)
    #expect(result.trashedNodeIDs == [moved.id] && result.failures.map(\.nodeID) == [denied.id])
    #expect(result.invalidatedGrantIDs == [nestedGrant.id])
    #expect(updated.root?.logicalBytes == 17 && updated.root?.fileCount == 1)
    #expect(try await service.treeItem(id: denied.id, in: updated)?.logicalBytes == 17)
    #expect(try await service.treeChildren(parentID: nested.id, in: updated).rows.isEmpty)
    #expect(try await service.cachedSnapshot(for: grant)?.id == updated.id)
    #expect(try await service.cachedSnapshot(for: nestedGrant) == nil)
    for id in [other.id, original.id, updated.id] { await service.releaseTree(snapshotID: id) }
}

@Test func storageServiceTrashCacheWriteFailureReturnsAccurateLeasedTreeAndRejectsOldGeneration() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("moved", bytes: 11)
    try fixture.file("kept", bytes: 17)
    let counter = TreeScanCounter(), service = fixture.service(counter: counter, allowedScans: 1)
    let grant = try await service.selectFolder(fixture.root)
    let original = try await service.scan(grant) { _ in }
    let roots = try await service.treeChildren(parentID: 0, in: original)
    let moved = try #require(roots.rows.first { $0.name == "moved" })
    let kept = try #require(roots.rows.first { $0.name == "kept" })
    try FileManager.default.removeItem(at: fixture.cache)
    try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: false)
    let result = try await service.trash(nodeIDs: [moved.id], in: original)
    let updated = try #require(result.updatedSnapshot)
    #expect(result.cacheInvalidationError != nil && result.trashedNodeIDs == [moved.id])
    #expect(updated.root?.logicalBytes == 17)
    #expect(try await service.cachedSnapshot(for: grant)?.id == updated.id)
    await #expect(throws: StorageServiceError.self) { try await service.trash(nodeIDs: [kept.id], in: original) }
    #expect(try Data(contentsOf: fixture.root.appending(path: "kept")) == Data(repeating: 3, count: 17))
    let second = try await service.trash(nodeIDs: [kept.id], in: updated)
    let empty = try #require(second.updatedSnapshot)
    #expect(empty.root?.logicalBytes == 0 && empty.root?.fileCount == 0)
    #expect(try await service.treeChildren(parentID: 0, in: empty).rows.isEmpty)
    #expect(counter.value == 1)
    for id in [original.id, updated.id, empty.id] { await service.releaseTree(snapshotID: id) }
}

@Test func storageServiceTrashWriteFailureKeepsReadableHistoricalCacheReadOnlyAfterRestart() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("moved", bytes: 11)
    try fixture.file("kept", bytes: 17)
    let counter = TreeScanCounter(), service = fixture.service(counter: counter, allowedScans: 1)
    let grant = try await service.selectFolder(fixture.root)
    let original = try await service.scan(grant) { _ in }
    let roots = try await service.treeChildren(parentID: 0, in: original)
    let moved = try #require(roots.rows.first { $0.name == "moved" })
    let kept = try #require(roots.rows.first { $0.name == "kept" })
    let originalJSON = try Data(contentsOf: fixture.cache)
    let parent = fixture.cache.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
    let treePermissions = try FileManager.default.attributesOfItem(atPath: fixture.trees.path)[.posixPermissions] as? NSNumber
    #expect(treePermissions?.intValue == 0o700)
    let result = try await service.trash(nodeIDs: [moved.id], in: original)
    let updated = try #require(result.updatedSnapshot)
    #expect(result.trashedNodeIDs == [moved.id] && result.cacheInvalidationError != nil)
    #expect(try Data(contentsOf: fixture.cache) == originalJSON)
    #expect(try await service.isSnapshotSuperseded(original))
    #expect(try await !service.isSnapshotSuperseded(updated))
    #expect(try await service.treeChildren(parentID: 0, in: updated).rows.map(\.name) == ["kept"])
    await service.releaseTree(snapshotID: original.id)
    await service.releaseTree(snapshotID: updated.id)
    #expect(FileManager.default.fileExists(atPath: StorageTreeReader.indexURL(directoryURL: fixture.trees, id: original.id).path))
    #expect(try StorageTreeReader.isSuperseded(directoryURL: fixture.trees, id: original.id))
    let restarted = fixture.service(counter: counter, allowedScans: 1)
    let historical = try #require(try await restarted.cachedSnapshot(for: grant))
    #expect(historical == original)
    #expect(try await restarted.isSnapshotSuperseded(historical))
    #expect(try await restarted.treeChildren(parentID: 0, in: historical).rows.count == 2)
    await #expect(throws: StorageServiceError.self) { try await restarted.trash(nodeIDs: [kept.id], in: historical) }
    #expect(try Data(contentsOf: fixture.root.appending(path: "kept")) == Data(repeating: 3, count: 17))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.access.bin.path).count == 1)
    #expect(counter.value == 1)
    await restarted.releaseTree(snapshotID: original.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    try await restarted.clearCache()
    #expect(!FileManager.default.fileExists(atPath: StorageTreeReader.indexURL(directoryURL: fixture.trees, id: original.id).path))
    #expect(try !StorageTreeReader.isSuperseded(directoryURL: fixture.trees, id: original.id))
}

@Test func storageServiceAllFailedTrashRemovesOnlyNewProvisionalMarkers() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 17)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let original = try await service.scan(grant) { _ in }
    let kept = try #require(try await service.treeChildren(parentID: 0, in: original).rows.first)
    fixture.access.failTrash(named: "kept")
    let result = try await service.trash(nodeIDs: [kept.id], in: original)
    #expect(result.trashedNodeIDs.isEmpty && result.failures.count == 1)
    #expect(result.updatedSnapshot == nil && result.cacheInvalidationError == nil)
    #expect(try await !service.isSnapshotSuperseded(original))
    #expect(try await service.cachedSnapshot(for: grant) == original)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "kept").path))
    await service.releaseTree(snapshotID: original.id)
}

@Test func storageServiceUnsafeAffectedMarkerRefusesAllNativeMovesWithoutTouchingForeignData() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("nested/moved", bytes: 11)
    let service = fixture.service()
    let outerGrant = try await service.selectFolder(fixture.root)
    let innerGrant = try await service.selectFolder(fixture.root.appending(path: "nested"))
    let inner = try await service.scan(innerGrant) { _ in }
    let outer = try await service.scan(outerGrant) { _ in }
    let nested = try #require(try await service.treeChildren(parentID: 0, in: outer).rows.first)
    let moved = try #require(try await service.treeChildren(parentID: nested.id, in: outer).rows.first)
    let foreign = fixture.base.appending(path: "foreign-marker-target")
    let sentinel = Data("Foreign contents must remain unchanged".utf8)
    try sentinel.write(to: foreign)
    let marker = fixture.trees.appending(path: inner.id.uuidString + ".superseded")
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: foreign)
    await #expect(throws: StorageServiceError.self) { try await service.trash(nodeIDs: [moved.id], in: outer) }
    #expect(try Data(contentsOf: fixture.root.appending(path: "nested/moved")) == Data(repeating: 3, count: 11))
    #expect(!FileManager.default.fileExists(atPath: fixture.access.bin.path))
    #expect(try Data(contentsOf: foreign) == sentinel)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: marker.path) == foreign.path)
    #expect(try await !service.isSnapshotSuperseded(outer))
    for id in [inner.id, outer.id] { await service.releaseTree(snapshotID: id) }
}

@Test func storageServiceDrilledTrashReturnsUpdatedNarrowTreeWithoutReplacingPrimaryCacheRoot() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("nested/moved", bytes: 11)
    try fixture.file("kept", bytes: 17)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let original = try await service.scan(grant) { _ in }
    let roots = try await service.treeChildren(parentID: 0, in: original)
    let nested = try #require(roots.rows.first { $0.name == "nested" })
    let kept = try #require(roots.rows.first { $0.name == "kept" })
    let drill = try await service.scanDirectory(nodeID: nested.id, in: original) { _ in }
    let moved = try #require(try await service.treeChildren(parentID: 0, in: drill).rows.first)
    let result = try await service.trash(nodeIDs: [moved.id], in: drill)
    let updated = try #require(result.updatedSnapshot)
    #expect(updated.rootPath == fixture.root.appending(path: "nested").path)
    #expect(updated.authorizationRootPath == fixture.root.path && updated.root?.fileCount == 0)
    #expect(result.invalidatedGrantIDs == [grant.id])
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(try await service.treeChildren(parentID: 0, in: updated).rows.isEmpty)
    await #expect(throws: StorageServiceError.self) { try await service.trash(nodeIDs: [kept.id], in: original) }
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "kept").path))
    for id in [original.id, drill.id, updated.id] { await service.releaseTree(snapshotID: id) }
}

@Test func storageServiceActiveUncachedTreeRemainsMutableAfterClearingSavedResults() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("moved", bytes: 11)
    try fixture.file("kept", bytes: 17)
    let counter = TreeScanCounter(), service = fixture.service(counter: counter, allowedScans: 1)
    let grant = try await service.selectFolder(fixture.root)
    let original = try await service.scan(grant) { _ in }
    let moved = try #require(try await service.treeChildren(parentID: 0, in: original).rows.first { $0.name == "moved" })
    try await service.clearCache()
    let result = try await service.trash(nodeIDs: [moved.id], in: original)
    let updated = try #require(result.updatedSnapshot)
    #expect(updated.root?.logicalBytes == 17)
    #expect(try await service.cachedSnapshot(for: grant)?.id == updated.id)
    #expect(counter.value == 1)
    for id in [original.id, updated.id] { await service.releaseTree(snapshotID: id) }
}

@Test func storageServicePostTrashPruneFailureReportsMovesAndRetainsHistoricalBrowser() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("moved", bytes: 11)
    try fixture.file("kept", bytes: 17)
    let counter = TreeScanCounter()
    let service = StorageService(grantsURL: fixture.grants, cacheURL: fixture.cache, resourceAccess: fixture.access,
        treeScansEnabled: true, treePruneOperation: { _, _ in throw StorageTreeIndexError.io("Injected clone failure") },
        scanOperation: { root, id, progress in
            counter.increment()
            guard counter.value == 1 else { throw StorageServiceError.access("Unexpected source scan") }
            return try await StorageScanner(treeDirectory: fixture.trees).scan(rootURL: root, grantID: id, progress: progress)
        })
    let grant = try await service.selectFolder(fixture.root)
    let original = try await service.scan(grant) { _ in }
    let roots = try await service.treeChildren(parentID: 0, in: original)
    let moved = try #require(roots.rows.first { $0.name == "moved" })
    let kept = try #require(roots.rows.first { $0.name == "kept" })
    let result = try await service.trash(nodeIDs: [moved.id], in: original)
    #expect(result.trashedNodeIDs == [moved.id] && result.updatedSnapshot == nil)
    #expect(result.cacheInvalidationError != nil && result.invalidatedGrantIDs == [grant.id])
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(try await service.treeChildren(parentID: 0, in: original).rows.count == 2)
    await #expect(throws: StorageServiceError.self) { try await service.trash(nodeIDs: [kept.id], in: original) }
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "kept").path))
    #expect(counter.value == 1)
    await service.releaseTree(snapshotID: original.id)
}

@Test func storageServiceTrashSupersedesActiveOtherGrantWithoutMovingItsRemainingFiles() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("nested/moved", bytes: 11)
    try fixture.file("nested/kept", bytes: 17)
    let counter = TreeScanCounter(), service = fixture.service(counter: counter, allowedScans: 2)
    let outerGrant = try await service.selectFolder(fixture.root)
    let innerGrant = try await service.selectFolder(fixture.root.appending(path: "nested"))
    let inner = try await service.scan(innerGrant) { _ in }
    let innerKept = try #require(try await service.treeChildren(parentID: 0, in: inner).rows.first { $0.name == "kept" })
    let outer = try await service.scan(outerGrant) { _ in }
    let nested = try #require(try await service.treeChildren(parentID: 0, in: outer).rows.first)
    let moved = try #require(try await service.treeChildren(parentID: nested.id, in: outer).rows.first { $0.name == "moved" })
    let result = try await service.trash(nodeIDs: [moved.id], in: outer)
    let updated = try #require(result.updatedSnapshot)
    #expect(result.invalidatedGrantIDs == [innerGrant.id])
    #expect(try await service.cachedSnapshot(for: innerGrant) == nil)
    await #expect(throws: StorageServiceError.self) { try await service.trash(nodeIDs: [innerKept.id], in: inner) }
    #expect(try Data(contentsOf: fixture.root.appending(path: "nested/kept")) == Data(repeating: 3, count: 17))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.access.bin.path).count == 1)
    #expect(try await service.treeChildren(parentID: nested.id, in: updated).rows.map(\.name) == ["kept"])
    #expect(try await service.cachedSnapshot(for: outerGrant)?.id == updated.id)
    #expect(counter.value == 2)
    for id in [inner.id, outer.id, updated.id] { await service.releaseTree(snapshotID: id) }
}

private final class TreeScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private struct TreeServiceFixture {
    let base: URL
    var root: URL { base.appending(path: "source") }
    var cache: URL { base.appending(path: "saved/snapshots.json") }
    var trees: URL { base.appending(path: "saved/storage-trees") }
    var grants: URL { base.appending(path: "support/grants.json") }
    let access: TreeServiceAccess
    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        base = repository.appending(path: "agent_temp_files_local/tree-service-test-\(UUID())")
        access = TreeServiceAccess(bin: base.appending(path: "trash"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ path: String, bytes: Int) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: bytes).write(to: url)
    }
    func service(counter: TreeScanCounter = TreeScanCounter(), budget: UInt64 = 8 * 1_024 * 1_024 * 1_024,
                 allowedScans: Int? = nil) -> StorageService {
        StorageService(grantsURL: grants, cacheURL: cache, resourceAccess: access,
            maximumTreeBytes: budget, treeScansEnabled: true,
            scanOperation: { root, id, progress in
                counter.increment()
                if let allowedScans, counter.value > allowedScans {
                    throw StorageServiceError.access("Unexpected scanner invocation while reading a saved tree")
                }
                return try await StorageScanner(maximumNodes: 2, largestLimit: 1, treeDirectory: trees)
                    .scan(rootURL: root, grantID: id, progress: progress)
            })
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Test func storageServiceTreePagingAndRestartNeverRescanSource() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    for index in 0..<40 { try fixture.file("outer/deep/file-\(index)", bytes: index + 1) }
    let counter = TreeScanCounter(), service = fixture.service(counter: counter, allowedScans: 1)
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let outer = try #require(try await service.treeChildren(parentID: 0, in: snapshot).rows.first)
    let deep = try #require(try await service.treeChildren(parentID: outer.id, in: snapshot).rows.first)
    var names: [String] = []
    for offset in stride(from: 0, to: 40, by: 7) {
        let page = try await service.treeChildren(parentID: deep.id, in: snapshot, metric: .logical, offset: offset, limit: 7)
        #expect(page.totalCount == 40)
        names += page.rows.map(\.name)
    }
    #expect(Set(names).count == 40)
    #expect(names.first == "file-39")
    let smallest = try #require(try await service.treeChildren(parentID: deep.id, in: snapshot,
        metric: .logical, descending: false, limit: 1).rows.first)
    #expect(try await service.treeItem(id: smallest.id, in: snapshot)?.relativePath == "outer/deep/file-0")
    let hidden = try #require(try await service.treeChildren(parentID: deep.id, in: snapshot, limit: 100)
        .rows.first { snapshot.itemReference(id: $0.id) == nil })
    #expect(try await service.treeItem(id: hidden.id, in: snapshot)?.name == hidden.name)
    #expect(counter.value == 1)
    await service.releaseTree(snapshotID: snapshot.id)
    try FileManager.default.removeItem(at: fixture.root)
    let restarted = fixture.service(counter: counter, allowedScans: 1)
    let cached = try #require(try await restarted.cachedSnapshot(for: grant))
    #expect(cached.id == snapshot.id)
    #expect(try await restarted.treeChildren(parentID: deep.id, in: cached, limit: 100).rows.count == 40)
    #expect(counter.value == 1)
    await restarted.releaseTree(snapshotID: snapshot.id)
}

@Test func storageServiceCacheClearRetainsActiveTreeUntilExplicitRelease() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("deep/kept", bytes: 12)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let path = StorageTreeReader.indexURL(directoryURL: fixture.trees, id: snapshot.id)
    let foreign = fixture.trees.appending(path: UUID().uuidString + ".sqlite")
    try Data("unowned".utf8).write(to: foreign)
    try await service.clearCache()
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(FileManager.default.fileExists(atPath: path.path))
    #expect(try await service.treeChildren(parentID: 0, in: snapshot).rows.first?.name == "deep")
    await service.releaseTree(snapshotID: snapshot.id)
    #expect(!FileManager.default.fileExists(atPath: path.path))
    #expect(try Data(contentsOf: foreign) == Data("unowned".utf8))
}

@Test func storageServiceTreeActionsRequireCanonicalMembershipAndProtectPackageInternals() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("outer/deep/small", bytes: 1)
    try fixture.file("outer/deep/big", bytes: 80)
    try fixture.file("Archive.bundle/Contents/inside", bytes: 11)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    let roots = try await service.treeChildren(parentID: 0, in: snapshot)
    let outer = try #require(roots.rows.first { $0.name == "outer" })
    let deep = try #require(try await service.treeChildren(parentID: outer.id, in: snapshot).rows.first)
    let small = try #require(try await service.treeChildren(parentID: deep.id, in: snapshot,
        metric: .logical, descending: false, limit: 1).rows.first)
    let ref = try #require(try await service.treeItem(id: small.id, in: snapshot))
    #expect(snapshot.itemReference(id: ref.id) == nil)
    try await service.reveal(item: ref, in: snapshot)
    #expect(fixture.access.revealed == [fixture.root.appending(path: "outer/deep/small")])
    let forged = StorageItemReference(id: ref.id, name: ref.name, relativePath: ref.relativePath,
        kind: ref.kind, identity: ref.identity, totals: .zero, ancestors: ref.ancestors)
    #expect(try await service.trash(items: [forged], in: snapshot).trashedNodeIDs.isEmpty)
    let package = try #require(roots.rows.first { $0.kind == .package })
    let contents = try #require(try await service.treeChildren(parentID: package.id, in: snapshot).rows.first)
    let inside = try #require(try await service.treeChildren(parentID: contents.id, in: snapshot).rows.first)
    let innerRef = try #require(try await service.treeItem(id: inside.id, in: snapshot))
    #expect(innerRef.isInsidePackage)
    #expect(try await service.trash(items: [innerRef], in: snapshot).trashedNodeIDs.isEmpty)
    let packageRef = try #require(try await service.treeItem(id: package.id, in: snapshot))
    #expect(try await service.trash(items: [packageRef], in: snapshot).trashedNodeIDs == [package.id])
    #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "outer/deep/small").path))
    await service.releaseTree(snapshotID: snapshot.id)
}

@Test func storageServiceCompactLegacyTreeNeedsExplicitRefresh() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("deep/kept", bytes: 12)
    let counter = TreeScanCounter()
    let service = StorageService(grantsURL: fixture.grants, cacheURL: fixture.cache, resourceAccess: fixture.access,
        scanOperation: { root, id, progress in
            counter.increment()
            return try await StorageScanner().scan(rootURL: root, grantID: id, progress: progress)
        })
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await service.scan(grant) { _ in }
    #expect(snapshot.schemaVersion == 2)
    do {
        _ = try await service.treeChildren(parentID: 0, in: snapshot)
        Issue.record("Compact legacy overview unexpectedly supplied a full tree")
    } catch StorageServiceError.treeUnavailable {}
    do {
        _ = try await service.treeItem(id: 0, in: snapshot)
        Issue.record("Compact legacy overview unexpectedly supplied a canonical tree item")
    } catch StorageServiceError.treeUnavailable {}
    #expect(counter.value == 1)
}

@Test func storageServiceFullLegacyTreePagesStoredNodesWithoutDiskAccess() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    let identity = try StorageFileMetadata.identity(at: fixture.root)
    let snapshot = StorageSnapshot(grantID: UUID(), rootPath: fixture.root.path, rootIdentity: identity,
        nodes: [
            StorageNode(id: 0, parentID: nil, name: "source", relativePath: "", kind: .directory,
                identity: identity, logicalBytes: 13, allocatedBytes: 0, apparentBytes: 13, fileCount: 2),
            StorageNode(id: 1, parentID: 0, name: "small", relativePath: "small", kind: .file,
                identity: identity, logicalBytes: 2, allocatedBytes: 0, apparentBytes: 2, fileCount: 1),
            StorageNode(id: 2, parentID: 0, name: "big", relativePath: "big", kind: .file,
                identity: identity, logicalBytes: 11, allocatedBytes: 0, apparentBytes: 11, fileCount: 1)
        ], issues: [])
    try FileManager.default.removeItem(at: fixture.root)
    let service = fixture.service()
    let page = try await service.treeChildren(parentID: 0, in: snapshot, metric: .logical, offset: 1, limit: 1)
    #expect(page.totalCount == 2 && page.rows.map(\.name) == ["small"])
    #expect(try await service.treeItem(id: 2, in: snapshot)?.relativePath == "big")
}

@Test func storageServiceTreeRejectsTrashOfOwnCacheAncestor() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 12)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.base)
    let snapshot = try await service.scan(grant) { _ in }
    let cacheParent = try #require(try await service.treeChildren(parentID: 0, in: snapshot).rows.first { $0.name == "saved" })
    #expect(snapshot.issues.contains { $0.reason == .analysisCache })
    let item = try #require(try await service.treeItem(id: cacheParent.id, in: snapshot))
    let result = try await service.trash(items: [item], in: snapshot)
    #expect(result.trashedNodeIDs.isEmpty && result.failures.count == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.trees.path))
    await service.releaseTree(snapshotID: snapshot.id)
}

@Test func storageServiceTreeBudgetEvictsWholeInactiveGenerationAndKeepsNewest() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("deep/kept", bytes: 12)
    let service = fixture.service(budget: 1)
    let rootGrant = try await service.selectFolder(fixture.root)
    let nestedGrant = try await service.selectFolder(fixture.root.appending(path: "deep"))
    let old = try await service.scan(rootGrant) { _ in }
    await service.releaseTree(snapshotID: old.id)
    let newest = try await service.scan(nestedGrant) { _ in }
    #expect(try await service.cachedSnapshot(for: rootGrant) == nil)
    #expect(try await service.cachedSnapshot(for: nestedGrant)?.id == newest.id)
    #expect(!FileManager.default.fileExists(atPath: StorageTreeReader.indexURL(directoryURL: fixture.trees, id: old.id).path))
    #expect(FileManager.default.fileExists(atPath: StorageTreeReader.indexURL(directoryURL: fixture.trees, id: newest.id).path))
    await service.releaseTree(snapshotID: newest.id)
}

@Test func storageServiceSweepsOnlyPositivelyOwnedAbandonedBuildingIndex() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 12)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    let abandoned = try await StorageScanner(treeDirectory: fixture.trees).scan(rootURL: fixture.root, grantID: grant.id)
    let building = StorageTreeReader.indexURL(directoryURL: fixture.trees, id: abandoned.id, building: true)
    try FileManager.default.moveItem(at: StorageTreeReader.indexURL(directoryURL: fixture.trees, id: abandoned.id), to: building)
    let foreign = StorageTreeReader.indexURL(directoryURL: fixture.trees, id: UUID(), building: true)
    try Data("not an owned database".utf8).write(to: foreign)
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(!FileManager.default.fileExists(atPath: building.path))
    #expect(try Data(contentsOf: foreign) == Data("not an owned database".utf8))
}

@Test func storageServiceFailedManifestWriteKeepsPriorTreeAndRemovesUnreturnedGeneration() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 12)
    let counter = TreeScanCounter(), service = fixture.service(counter: counter)
    let grant = try await service.selectFolder(fixture.root)
    let first = try await service.scan(grant) { _ in }
    try FileManager.default.removeItem(at: fixture.cache)
    try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await service.scan(grant) { _ in } }
    #expect(counter.value == 2)
    #expect(try await service.cachedSnapshot(for: grant)?.id == first.id)
    let files = try FileManager.default.contentsOfDirectory(atPath: fixture.trees.path).filter { $0.hasSuffix(".sqlite") }
    #expect(files == [first.id.uuidString + ".sqlite"])
    #expect(try await service.treeChildren(parentID: 0, in: first).rows.first?.name == "kept")
    await service.releaseTree(snapshotID: first.id)
}

@Test func storageServiceFailedCacheReadRemovesNewUnreturnedTreeWithoutChangingCorruptManifest() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 12)
    let service = fixture.service()
    let grant = try await service.selectFolder(fixture.root)
    try FileManager.default.createDirectory(at: fixture.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    let corrupt = Data("invalid saved manifest".utf8)
    try corrupt.write(to: fixture.cache)
    await #expect(throws: (any Error).self) { try await service.scan(grant) { _ in } }
    #expect(try Data(contentsOf: fixture.cache) == corrupt)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trees.path).filter { $0.hasSuffix(".sqlite") }.isEmpty)
}

private actor TreeHandoffGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        started = true
        observers.forEach { $0.resume() }; observers.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForHandoff() async {
        if !started { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Test func storageServiceClearDuringTreeHandoffReturnsAnUncachedLeasedResult() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 12)
    let gate = TreeHandoffGate()
    let service = StorageService(grantsURL: fixture.grants, cacheURL: fixture.cache, resourceAccess: fixture.access,
        treeScansEnabled: true, scanOperation: { root, id, progress in
            let snapshot = try await StorageScanner(treeDirectory: fixture.trees).scan(rootURL: root, grantID: id, progress: progress)
            await gate.hold()
            return snapshot
        })
    let grant = try await service.selectFolder(fixture.root)
    let task = Task { try await service.scan(grant) { _ in } }
    await gate.waitForHandoff()
    try await service.clearCache()
    await gate.release()
    let snapshot = try await task.value
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    #expect(try await service.treeChildren(parentID: 0, in: snapshot).rows.first?.name == "kept")
    let path = StorageTreeReader.indexURL(directoryURL: fixture.trees, id: snapshot.id)
    #expect(FileManager.default.fileExists(atPath: path.path))
    await service.releaseTree(snapshotID: snapshot.id)
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test func storageServiceUnverifiedFullCatalogTreeBecomesLatestAndKeepsCompleteBackup() async throws {
    let fixture = try TreeServiceFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 12)
    let original = fixture.service()
    let grant = try await original.selectFolder(fixture.root)
    let complete = try await original.scan(grant) { _ in }
    #expect(complete.isComplete)
    await original.releaseTree(snapshotID: complete.id)
    let service = StorageService(grantsURL: fixture.grants, cacheURL: fixture.cache, resourceAccess: fixture.access,
        treeScansEnabled: true, scanOperation: { root, grantID, _ in
            let identity = try StorageFileMetadata.identity(at: root)
            let writer = try StorageTreeWriter(directoryURL: fixture.trees, snapshotID: UUID(), grantID: grantID,
                rootURL: root, rootIdentity: identity)
            defer { writer.abort() }
            let totals = StorageTotals(logicalBytes: 12, allocatedBytes: 0, apparentBytes: 12, fileCount: 1)
            _ = try writer.appendLeaf(name: "kept", parentID: 0, kind: .file,
                identity: StorageFileMetadata.identity(at: root.appending(path: "kept")), totals: totals,
                isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false, isInsidePackage: false)
            let item = ScanItem(name: root.lastPathComponent, relativePath: "", kind: .directory, identity: identity, ancestors: [])
            try item.add(totals)
            let snapshot = try StorageSnapshotBuilder.build(rootURL: root, grantID: grantID, root: item,
                overview: [], largest: [], issues: [], omittedIssues: 0, scanMethod: .volumeCatalog,
                treeWriter: writer, maximumNodes: 2, largestLimit: 1)
            writer.completeHandoff()
            return snapshot
        })
    let fresh = try await service.scan(grant) { _ in }
    #expect(fresh.hasUnverifiedCoverage && !fresh.isComplete && fresh.issues.isEmpty)
    #expect(try await service.cachedSnapshot(for: grant)?.id == fresh.id)
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
    let backups = try #require(json["savedCompleteSnapshots"] as? [[String: Any]])
    #expect(backups.count == 1)
    #expect(backups.first?["id"] as? String == complete.id.uuidString)
    #expect(FileManager.default.fileExists(atPath: StorageTreeReader.indexURL(directoryURL: fixture.trees, id: complete.id).path))
    await service.releaseTree(snapshotID: fresh.id)
}
