import Darwin
import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import SQLite3
import Testing

private struct TreeFixture {
    let directory: URL
    var root: URL { directory.appending(path: "source") }
    var cache: URL { directory.appending(path: "indexes") }
    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = repository.appending(path: "agent_temp_files_local/tree-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ path: String, bytes: Int) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@Test func storageTreeScanRetainsDeepAndWideHierarchyAndReopensWithoutSource() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    for index in 0..<40 { try fixture.file("outer/deep/file-\(index)", bytes: index + 1) }
    try fixture.file("Archive.bundle/Contents/inside", bytes: 23)
    let snapshot = try await StorageScanner(maximumNodes: 2, largestLimit: 2, treeDirectory: fixture.cache)
        .scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.schemaVersion == 3)
    #expect(snapshot.nodes.count == 2)
    #expect(snapshot.tree?.nodeCount == 46)
    #expect(snapshot.root?.logicalBytes == 843)
    let reader = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    let roots = try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 20)
    let outer = try #require(roots.rows.first { $0.name == "outer" })
    #expect(roots.rows.map(\.name) == ["outer", "Archive.bundle"])
    let inner = try await reader.children(parentID: outer.id, metric: .logical, offset: 0, limit: 20)
    let deep = try #require(inner.rows.first)
    var names: [String] = []
    for offset in stride(from: 0, to: 40, by: 7) {
        let page = try await reader.children(parentID: deep.id, metric: .logical, offset: offset, limit: 7)
        #expect(page.totalCount == 40)
        names += page.rows.map(\.name)
    }
    #expect(names.count == 40)
    #expect(Set(names).count == 40)
    #expect(names.first == "file-39")
    let ascending = try await reader.children(parentID: deep.id, metric: .logical, descending: false, offset: 0, limit: 1)
    let selected = try #require(ascending.rows.first)
    let reference = try #require(try await reader.item(id: selected.id))
    #expect(reference.relativePath == "outer/deep/file-0")
    #expect(reference.ancestors.map(\.relativePath) == ["", "outer", "outer/deep"])
    #expect(!reference.isInsidePackage)
    let package = try #require(roots.rows.first { $0.kind == .package })
    let contents = try await reader.children(parentID: package.id, metric: .logical, offset: 0, limit: 20)
    #expect(contents.rows.first?.isInsidePackage == true)
    #expect(try await reader.item(id: package.id)?.isInsidePackage == false)
    #expect(try StorageTreeReader.removeIfUnused(directoryURL: fixture.cache, id: snapshot.id) == false)
    await reader.close()
    try FileManager.default.removeItem(at: fixture.root)
    let reopened = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    #expect(try await reopened.item(id: selected.id) == reference)
    #expect(try await reopened.children(parentID: deep.id, metric: .logical, offset: 0, limit: 100).rows.count == 40)
    await reopened.close()
    #expect(try StorageTreeReader.removeIfUnused(directoryURL: fixture.cache, id: snapshot.id))
}

@Test func storageTreePreservesUnsignedIdentitiesAndExactMaximumTotalsWithoutLeafPaths() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    let identity = try StorageFileMetadata.identity(at: fixture.root)
    let grant = UUID(), id = UUID()
    let writer = try StorageTreeWriter(directoryURL: fixture.cache, snapshotID: id, grantID: grant,
        rootURL: fixture.root, rootIdentity: identity)
    defer { writer.abort() }
    let largeIdentity = StorageFileIdentity(device: UInt64.max, inode: UInt64.max - 1, birthSeconds: 7, birthNanoseconds: 999_999_999)
    _ = try writer.appendLeaf(name: "large", parentID: 0, kind: .file, identity: largeIdentity,
        totals: StorageTotals(logicalBytes: UInt64.max - 7, allocatedBytes: UInt64.max - 7, apparentBytes: UInt64.max - 7, fileCount: 1),
        isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false, isInsidePackage: false)
    _ = try writer.appendLeaf(name: "small", parentID: 0, kind: .file, identity: largeIdentity,
        totals: StorageTotals(logicalBytes: 7, allocatedBytes: 7, apparentBytes: 7, fileCount: 1),
        isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false, isInsidePackage: false)
    let totals = StorageTotals(logicalBytes: UInt64.max, allocatedBytes: UInt64.max, apparentBytes: UInt64.max, fileCount: 2)
    let summary = try writer.finish(expectedRootTotals: totals, maximumNodes: 1, largestLimit: 0)
    let snapshot = StorageSnapshot(id: id, grantID: grant, rootPath: fixture.root.path, rootIdentity: identity,
        nodes: [StorageNode(id: 0, parentID: nil, name: "source", relativePath: "", kind: .directory,
            identity: identity, logicalBytes: UInt64.max, allocatedBytes: UInt64.max, apparentBytes: UInt64.max, fileCount: 2,
            unlistedChildren: totals, unlistedChildCount: 2)], issues: [], schemaVersion: 3, tree: summary.descriptor)
    try writer.publish(snapshot: snapshot); writer.completeHandoff()
    let reader = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    let page = try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 10)
    #expect(page.rows.map(\.name) == ["large", "small"])
    #expect(try await reader.item(id: page.rows[0].id)?.identity == largeIdentity)
    await reader.close()
    var database: OpaquePointer?
    #expect(sqlite3_open_v2(StorageTreeReader.indexURL(directoryURL: fixture.cache, id: id).path,
        &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { if let database { sqlite3_close(database) } }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM nodes WHERE kind='file' AND path IS NOT NULL", -1, &statement, nil) == SQLITE_OK)
    defer { if let statement { sqlite3_finalize(statement) } }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int64(statement, 0) == 0)
}

@Test func storageTreeRejectsOverflowAndRemovesFailedBuild() throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    let identity = try StorageFileMetadata.identity(at: fixture.root), id = UUID()
    let writer = try StorageTreeWriter(directoryURL: fixture.cache, snapshotID: id, grantID: UUID(), rootURL: fixture.root, rootIdentity: identity)
    for name in ["a", "b"] {
        _ = try writer.appendLeaf(name: name, parentID: 0, kind: .file, identity: identity,
            totals: StorageTotals(logicalBytes: UInt64.max, allocatedBytes: 0, apparentBytes: 0, fileCount: 1),
            isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false, isInsidePackage: false)
    }
    #expect(throws: StorageScannerError.self) { try writer.finish(expectedRootTotals: .zero, maximumNodes: 2, largestLimit: 2) }
    writer.abort()
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.appending(path: id.uuidString + ".building.sqlite").path))
    #expect(!FileManager.default.fileExists(atPath: StorageTreeReader.indexURL(directoryURL: fixture.cache, id: id).path))
}

@Test func storageTreeNameCollisionIdentifiesExactPathAndBothHistoricalObjects() throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    let identity = try StorageFileMetadata.identity(at: fixture.root)
    let writer = try StorageTreeWriter(directoryURL: fixture.cache, snapshotID: UUID(), grantID: UUID(),
        rootURL: fixture.root, rootIdentity: identity)
    defer { writer.abort() }
    let parent = try writer.ensureDirectory(name: "nested", relativePath: "nested", parentID: 0,
        identity: identity, kind: .directory, isCloudPlaceholder: false, isIncomplete: false)
    let totals = StorageTotals(logicalBytes: 7, allocatedBytes: 512, apparentBytes: 7, fileCount: 1)
    _ = try writer.appendLeaf(name: "same-name", parentID: parent, kind: .file, identity: identity,
        totals: totals, isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false, isInsidePackage: false)
    let replacement = StorageFileIdentity(device: identity.device, inode: identity.inode + 1,
        birthSeconds: identity.birthSeconds, birthNanoseconds: identity.birthNanoseconds)
    let failure = #expect(throws: StorageTreeIndexError.self) {
        try writer.appendLeaf(name: "same-name", parentID: parent, kind: .symbolicLink, identity: replacement,
            totals: .zero, isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false, isInsidePackage: false)
    }
    if case let .collision(path, existing, incoming)? = failure {
        #expect(path == "nested/same-name")
        #expect(existing.contains("kind=file"))
        #expect(existing.contains("inode=\(identity.inode),"))
        #expect(existing.contains("logical=7,"))
        #expect(incoming.contains("kind=symbolicLink"))
        #expect(incoming.contains("inode=\(replacement.inode),"))
    } else { Issue.record("Expected a contextual name conflict instead of an opaque SQLite constraint") }
    let summary = try writer.finish(expectedRootTotals: totals, maximumNodes: 2, largestLimit: 1)
    #expect(summary.descriptor.nodeCount == 3)
}

@Test func storageTreeExactRepeatNeverMasksAnUnrelatedSQLiteTriggerFailure() throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    let identity = try StorageFileMetadata.identity(at: fixture.root), id = UUID()
    let writer = try StorageTreeWriter(directoryURL: fixture.cache, snapshotID: id, grantID: UUID(),
        rootURL: fixture.root, rootIdentity: identity)
    defer { writer.abort() }
    let signature = Data(repeating: 7, count: 80)
    for index in 0..<4_095 {
        _ = try writer.appendLeaf(name: "file-\(index)", parentID: 0, kind: .file, identity: identity,
            totals: .zero, isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false,
            isInsidePackage: false, catalogRecord: signature)
    }
    // The ordinary 4,096-write transaction boundary (including root) released the
    // writer's SQLite transaction lock. Alter only this disposable private fixture.
    try alterTreeDatabase(StorageTreeReader.indexURL(directoryURL: fixture.cache, id: id, building: true),
        sql: "CREATE TRIGGER forced_failure BEFORE INSERT ON nodes BEGIN SELECT RAISE(ABORT,'forced unrelated failure'); END")
    let failure = #expect(throws: StorageTreeIndexError.self) {
        try writer.appendLeaf(name: "file-0", parentID: 0, kind: .file, identity: identity,
            totals: .zero, isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false,
            isInsidePackage: false, catalogRecord: signature)
    }
    if case let .io(message)? = failure { #expect(message.contains("forced unrelated failure")) }
    else { Issue.record("Trigger failure must propagate even when an exact catalog row exists") }
}

@Test(arguments: [true, false])
func storageTreeCatalogLeafIdentityChangeRequiresMatchingNativeParentScope(sameParent: Bool) throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try fixture.file("same-name", bytes: 7)
    try fixture.file("replacement", bytes: 11)
    let root = try StorageFileMetadata.identity(at: fixture.root)
    let first = try StorageFileMetadata.read(at: fixture.root.appending(path: "same-name"))
    let next = try StorageFileMetadata.read(at: fixture.root.appending(path: "replacement"))
    func entry(_ metadata: stat, parent: UInt64) -> StorageCatalogEntry {
        StorageCatalogEntry(name: "same-name", inode: metadata.st_ino, parentInode: parent,
            device: UInt64(UInt32(bitPattern: metadata.st_dev)), type: UInt32(VREG.rawValue),
            birthSeconds: Int64(metadata.st_birthtimespec.tv_sec), birthNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec),
            flags: metadata.st_flags, logicalBytes: UInt64(metadata.st_size), allocatedBytes: UInt64(metadata.st_blocks) * 512,
            linkCount: UInt32(metadata.st_nlink))
    }
    let previous = entry(first, parent: root.inode), incoming = entry(next, parent: sameParent ? root.inode : root.inode + 1)
    let writer = try StorageTreeWriter(directoryURL: fixture.cache, snapshotID: UUID(), grantID: UUID(), rootURL: fixture.root, rootIdentity: root)
    defer { writer.abort() }
    let totals = StorageTotals(logicalBytes: 7, allocatedBytes: previous.allocatedBytes, apparentBytes: 7, fileCount: 1)
    _ = try writer.appendLeaf(name: "same-name", parentID: 0, kind: .file, identity: StorageFileMetadata.identity(first),
        totals: totals, isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false,
        isInsidePackage: false, catalogRecord: previous.indexSignature)
    do {
        _ = try writer.appendLeaf(name: "same-name", parentID: 0, kind: .file, identity: StorageFileMetadata.identity(next),
            totals: StorageTotals(logicalBytes: 11, allocatedBytes: incoming.allocatedBytes, apparentBytes: 11, fileCount: 1),
            isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false,
            isInsidePackage: false, catalogRecord: incoming.indexSignature)
        Issue.record("Expected a classified historical name conflict")
    } catch let replacement as StorageTreeCatalogLeafReplacement {
        #expect(sameParent)
        #expect(replacement.existingIdentity == StorageFileMetadata.identity(first))
        #expect(replacement.incomingIdentity == StorageFileMetadata.identity(next))
        if sameParent {
            try writer.markKnownLeafReplacement(replacement)
            #expect(try writer.appendLeaf(name: "same-name", parentID: 0, kind: .file,
                identity: StorageFileMetadata.identity(first), totals: totals, isCloudPlaceholder: false,
                isHardLinkDuplicate: false, isIncomplete: false, isInsidePackage: false,
                catalogRecord: previous.indexSignature) == false)
        }
    } catch let failure as StorageTreeIndexError {
        #expect(!sameParent)
        if case .collision = failure {} else { Issue.record("Scope conflict must remain fatal") }
    }
    let summary = try writer.finish(expectedRootTotals: totals, maximumNodes: 2, largestLimit: 1)
    #expect(summary.descriptor.nodeCount == 2)
    #expect(summary.largest.first?.identity == StorageFileMetadata.identity(first))
}

@Test func storageTreeScannerExcludesEntireOwnCacheAndRejectsCacheRoot() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    let cache = fixture.root.appending(path: "indexes")
    try fixture.file("indexes/older-generation", bytes: 10_000)
    try fixture.file("kept", bytes: 31)
    let snapshot = try await StorageScanner(treeDirectory: cache).scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.root?.logicalBytes == 31)
    #expect(snapshot.issues.contains { $0.reason == .analysisCache })
    let reader = try StorageTreeReader(directoryURL: cache, snapshot: snapshot)
    #expect(try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 10).rows.map(\.name) == ["kept"])
    await reader.close()
    await #expect(throws: StorageTreeIndexError.self) {
        try await StorageScanner(treeDirectory: cache).scan(rootURL: cache, grantID: UUID())
    }
}

@Test func storageTreeCancellationAndGenerationLeasePreserveOtherIndexes() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 31)
    let snapshot = try await StorageScanner(treeDirectory: fixture.cache).scan(rootURL: fixture.root, grantID: UUID())
    let lease = try StorageTreeScanLease(directoryURL: fixture.cache)
    #expect(try StorageTreeReader.removeIfUnused(directoryURL: fixture.cache, id: snapshot.id) == false)
    lease.close()
    let task = Task {
        try await StorageScanner(treeDirectory: fixture.cache).scan(rootURL: fixture.root, grantID: UUID(),
            progress: { _ in withUnsafeCurrentTask { $0?.cancel() } })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path)
    #expect(names.filter { $0.hasSuffix(".sqlite") } == [snapshot.id.uuidString + ".sqlite"])
    #expect(!names.contains { $0.hasSuffix(".building.sqlite") })
    #expect(try StorageTreeReader.removeIfUnused(directoryURL: fixture.cache, id: snapshot.id))
}

@Test func storageTreeNativeCatalogContinuesWhilePrecreatedOwnDatabaseGrows() throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    let identity = try StorageFileMetadata.identity(at: fixture.root)
    let writer = try StorageTreeWriter(directoryURL: fixture.cache, snapshotID: UUID(), grantID: UUID(), rootURL: fixture.root, rootIdentity: identity)
    defer { writer.abort() }
    var volume = statfs(), cacheVolume = statfs()
    #expect(statfs("/System/Volumes/Data", &volume) == 0)
    #expect(statfs(fixture.cache.path, &cacheVolume) == 0)
    #expect(volume.f_fsid.val == cacheVolume.f_fsid.val)
    try StorageDatalessPolicy.withMaterializationDisabled { enabled in
        guard enabled else { throw StorageDatalessPolicyError.unavailable }
        let catalog = try StorageCatalogReader(volumeURL: URL(fileURLWithPath: "/System/Volumes/Data"), maximumMatches: 128)
        var returned = 0
        for batch in 0..<8 {
            for file in 0..<1_000 {
                _ = try writer.appendLeaf(name: "synthetic-\(batch)-\(file)", parentID: 0, kind: .file,
                    identity: identity, totals: StorageTotals(logicalBytes: 1, allocatedBytes: 1, apparentBytes: 1, fileCount: 1),
                    isCloudPlaceholder: false, isHardLinkDuplicate: false, isIncomplete: false, isInsidePackage: false)
            }
            let result = try catalog.nextBatch()
            returned += result.entries.count
            if result.isComplete { break }
        }
        #expect(returned > 0)
    }
    // This bounded native probe tests continuation while a precreated SQLite file grows;
    // it does not claim to prove generation stability for an entire live disk scan.
}

@Test func storageTreeRejectsCorruptPackageFlagsAndEmbeddedNulNames() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try fixture.file("Archive.bundle/Contents/child", bytes: 31)
    let snapshot = try await StorageScanner(treeDirectory: fixture.cache).scan(rootURL: fixture.root, grantID: UUID())
    let reader = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    let packages = try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 10)
    let package = try #require(packages.rows.first)
    let contents = try await reader.children(parentID: package.id, metric: .logical, offset: 0, limit: 10)
    let parent = try #require(contents.rows.first)
    let files = try await reader.children(parentID: parent.id, metric: .logical, offset: 0, limit: 10)
    let leaf = try #require(files.rows.first)
    await reader.close()
    let url = StorageTreeReader.indexURL(directoryURL: fixture.cache, id: snapshot.id)
    try alterTreeDatabase(url, sql: "UPDATE nodes SET inside=0 WHERE id=\(leaf.id)")
    let corrupted = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    await #expect(throws: StorageTreeIndexError.self) { try await corrupted.item(id: leaf.id) }
    await #expect(throws: StorageTreeIndexError.self) {
        try await corrupted.children(parentID: parent.id, metric: .logical, offset: 0, limit: 10)
    }
    await corrupted.close()
    try alterTreeDatabase(url, sql: "UPDATE nodes SET inside=1,name=CAST(X'6368696c64006576696c' AS TEXT) WHERE id=\(leaf.id)")
    let nulName = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    await #expect(throws: StorageTreeIndexError.self) { try await nulName.item(id: leaf.id) }
    await nulName.close()
}

private func alterTreeDatabase(_ url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
          let database else { throw StorageTreeIndexError.io("Test database open failed") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw StorageTreeIndexError.io(String(cString: sqlite3_errmsg(database)))
    }
}

@Test func storageTreeConstructorFailureCleansOnlyNewFilesAndNeverFollowsCacheSymlinkParents() throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let id = UUID(), identity = try StorageFileMetadata.identity(at: fixture.root)
    let lease = fixture.cache.appending(path: id.uuidString + ".lease")
    try Data([1, 2, 3]).write(to: lease)
    #expect(chmod(lease.path, 0o600) == 0)
    #expect(throws: StorageTreeIndexError.self) {
        try StorageTreeWriter(directoryURL: fixture.cache, snapshotID: id, grantID: UUID(), rootURL: fixture.root, rootIdentity: identity)
    }
    #expect(!FileManager.default.fileExists(atPath: StorageTreeReader.indexURL(directoryURL: fixture.cache, id: id, building: true).path))
    #expect(try Data(contentsOf: lease) == Data([1, 2, 3]))
    let outside = fixture.directory.appending(path: "outside"), alias = fixture.directory.appending(path: "alias")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
    let before = try StorageFileMetadata.read(at: outside).st_mode
    #expect(throws: StorageTreeIndexError.self) {
        try StorageTreeWriter(directoryURL: alias.appending(path: "indexes"), snapshotID: UUID(),
            grantID: UUID(), rootURL: fixture.root, rootIdentity: identity)
    }
    #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "indexes").path))
    #expect(try StorageFileMetadata.read(at: outside).st_mode == before)
}

@Test func storageTreeRejectsSelectedRootReplacementBeforePublishingAnEmptySummary() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try fixture.file("original", bytes: 7)
    let moved = fixture.directory.appending(path: "moved")
    let error = await #expect(throws: StorageCatalogScanError.self) {
        try await StorageScanner(maximumNodes: 1, largestLimit: 0, treeDirectory: fixture.cache)
            .scan(rootURL: fixture.root, grantID: UUID(), progress: { value in
                if value.phase == .validatingResults {
                    do {
                        try FileManager.default.moveItem(at: fixture.root, to: moved)
                        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
                    } catch { Issue.record("Own replacement fixture could not be prepared: \(error)") }
                }
            })
    }
    if case let .changedItem(_, reason)? = error { #expect(reason.contains("tree finalization")) }
    else { Issue.record("Expected final selected-root identity rejection") }
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path)
    #expect(!names.contains { $0.hasSuffix(".sqlite") || $0.hasSuffix(".lease") })
    #expect(FileManager.default.fileExists(atPath: moved.appending(path: "original").path))
}

@Test func storageTreePruningPreservesIDsReopensAndPromotesSurvivingHardLinkWithoutSourceReads() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try fixture.file("a/owned", bytes: 19)
    #expect(link(fixture.root.appending(path: "a/owned").path, fixture.root.appending(path: "alias").path) == 0)
    try fixture.file("keep", bytes: 23)
    try fixture.file("drop/deep/child", bytes: 11)
    try fixture.file("Archive.bundle/Contents/inside", bytes: 7)
    let snapshot = try await StorageScanner(treeDirectory: fixture.cache).scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.tree?.formatVersion == 2)
    let original = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    let roots = try await original.children(parentID: 0, metric: .logical, offset: 0, limit: 20)
    let a = try #require(roots.rows.first { $0.name == "a" })
    let owned = try #require(try await original.children(parentID: a.id, metric: .logical, offset: 0, limit: 10).rows.first)
    let alias = try #require(roots.rows.first { $0.name == "alias" })
    let owner = owned.isHardLinkDuplicate ? alias : owned
    let survivor = owned.isHardLinkDuplicate ? owned : alias
    let ownerReference = try #require(try await original.item(id: owner.id))
    let keep = try #require(roots.rows.first { $0.name == "keep" })
    let drop = try #require(roots.rows.first { $0.name == "drop" })
    let deep = try #require(try await original.children(parentID: drop.id, metric: .logical, offset: 0, limit: 10).rows.first)
    let child = try #require(try await original.children(parentID: deep.id, metric: .logical, offset: 0, limit: 10).rows.first)
    // Remove only disposable test data, then remove the whole source tree to prove
    // pruning/reopening do not invoke a fresh scan or surviving-file metadata proof.
    try FileManager.default.removeItem(at: fixture.root.appending(path: ownerReference.relativePath))
    try FileManager.default.removeItem(at: fixture.root.appending(path: "drop"))
    try FileManager.default.removeItem(at: fixture.root)
    let revised = try await original.prunedSnapshot(removing: [owner.id, drop.id, child.id], largestLimit: 10)
    #expect(revised.id != snapshot.id)
    #expect(revised.scannedAt == snapshot.scannedAt)
    #expect(revised.root?.logicalBytes == 49)
    #expect(revised.root?.apparentBytes == 49)
    #expect(revised.root?.fileCount == 3)
    #expect(revised.tree?.nodeCount == snapshot.tree?.nodeCount)
    #expect(try await original.item(id: owner.id) != nil)
    let reader = try StorageTreeReader(directoryURL: fixture.cache, snapshot: revised)
    #expect(try await reader.item(id: owner.id) == nil)
    #expect(try await reader.item(id: drop.id) == nil)
    #expect(try await reader.item(id: child.id) == nil)
    let retained = try #require(try await reader.item(id: survivor.id))
    #expect(!retained.isHardLinkDuplicate)
    #expect(retained.logicalBytes == 19)
    #expect(retained.allocatedBytes == ownerReference.allocatedBytes)
    #expect(try await reader.item(id: keep.id)?.logicalBytes == 23)
    #expect(revised.largestCatalog.contains { $0.id == survivor.id })
    let again = try await reader.prunedSnapshot(removing: [survivor.id])
    #expect(again.root?.logicalBytes == 30)
    #expect(again.root?.fileCount == 2)
    await reader.close(); await original.close()
    let reopened = try StorageTreeReader(directoryURL: fixture.cache, snapshot: again)
    #expect(try await reopened.item(id: keep.id)?.id == keep.id)
    #expect(try await reopened.item(id: survivor.id) == nil)
    #expect(try await reopened.children(parentID: 0, metric: .logical, offset: 0, limit: 20).rows.allSatisfy { $0.id != drop.id })
    await reopened.close()
}

@Test func storageTreePruningRejectsRootAndMissingIDsWithoutCreatingNewGenerations() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 7)
    let snapshot = try await StorageScanner(treeDirectory: fixture.cache).scan(rootURL: fixture.root, grantID: UUID())
    let reader = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    let before = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).sorted()
    await #expect(throws: StorageTreeIndexError.self) { try await reader.prunedSnapshot(removing: [0]) }
    await #expect(throws: StorageTreeIndexError.self) { try await reader.prunedSnapshot(removing: [Int.max]) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).sorted() == before)
    #expect(try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 10).rows.count == 1)
    await reader.close()
}

@Test func storageTreePruningSQLiteFailureCleansOnlyCloneAndPreservesOriginalGeneration() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 7)
    let snapshot = try await StorageScanner(treeDirectory: fixture.cache).scan(rootURL: fixture.root, grantID: UUID())
    let reader = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    let leaf = try #require(try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 10).rows.first)
    try alterTreeDatabase(StorageTreeReader.indexURL(directoryURL: fixture.cache, id: snapshot.id),
        sql: "CREATE TRIGGER forced_update_failure BEFORE UPDATE ON nodes BEGIN SELECT RAISE(ABORT,'forced prune failure'); END")
    let before = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).sorted()
    let failure = await #expect(throws: StorageTreeIndexError.self) { try await reader.prunedSnapshot(removing: [leaf.id]) }
    if case let .io(message)? = failure { #expect(message.contains("forced prune failure")) }
    else { Issue.record("Expected a propagated clone update error") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).sorted() == before)
    #expect(try await reader.item(id: leaf.id)?.logicalBytes == 7)
    #expect(try Data(contentsOf: fixture.root.appending(path: "kept")) == Data(repeating: 7, count: 7))
    await reader.close()
}

@Test func storageTreePruningMigratesFormatOneIndexWithoutRenumberingSurvivors() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try fixture.file("remove", bytes: 11)
    try fixture.file("keep", bytes: 19)
    let current = try await StorageScanner(treeDirectory: fixture.cache).scan(rootURL: fixture.root, grantID: UUID())
    let descriptor = try #require(current.tree)
    let old = StorageSnapshot(id: current.id, grantID: current.grantID, rootPath: current.rootPath,
        rootIdentity: current.rootIdentity, scannedAt: current.scannedAt, nodes: current.nodes,
        issues: current.issues, omittedIssueCount: current.omittedIssueCount, volume: current.volume, schemaVersion: 3,
        largestCatalog: current.largestCatalog, authorizationRootPath: current.authorizationRootPath,
        authorizationRootIdentity: current.authorizationRootIdentity, rootAncestors: current.rootAncestors,
        scanMethod: current.scanMethod, tree: StorageTreeDescriptor(id: descriptor.id, formatVersion: 1,
            nodeCount: descriptor.nodeCount, rootChildCount: descriptor.rootChildCount))
    let encoded = try JSONEncoder().encode(old).map { String(format: "%02x", $0) }.joined()
    try alterTreeDatabase(StorageTreeReader.indexURL(directoryURL: fixture.cache, id: current.id),
        sql: "DROP TABLE tombstones; DROP INDEX duplicate_identity; DROP INDEX largest_logical; DROP INDEX largest_allocated; UPDATE metadata SET value=X'\(encoded)' WHERE key='manifest'")
    let reader = try StorageTreeReader(directoryURL: fixture.cache, snapshot: old)
    let children = try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 10)
    let removed = try #require(children.rows.first { $0.name == "remove" })
    let kept = try #require(children.rows.first { $0.name == "keep" })
    let revised = try await reader.prunedSnapshot(removing: [removed.id])
    #expect(revised.tree?.formatVersion == 2)
    #expect(revised.tree?.nodeCount == old.tree?.nodeCount)
    #expect(revised.root?.logicalBytes == 19)
    let migrated = try StorageTreeReader(directoryURL: fixture.cache, snapshot: revised)
    #expect(try await migrated.item(id: kept.id)?.id == kept.id)
    #expect(try await migrated.item(id: removed.id) == nil)
    #expect(try await reader.item(id: removed.id) != nil)
    await migrated.close(); await reader.close()
}

@Test func storageTreeSupersededMarkersPersistAndPreserveExistingInvalidations() async throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    try fixture.file("kept", bytes: 7)
    let snapshot = try await StorageScanner(treeDirectory: fixture.cache).scan(rootURL: fixture.root, grantID: UUID())
    #expect(try !StorageTreeReader.isSuperseded(directoryURL: fixture.cache, id: snapshot.id))
    #expect(try StorageTreeReader.markSuperseded(directoryURL: fixture.cache, id: snapshot.id))
    #expect(try !StorageTreeReader.markSuperseded(directoryURL: fixture.cache, id: snapshot.id))
    #expect(try StorageTreeReader.isSuperseded(directoryURL: fixture.cache, id: snapshot.id))
    let marker = fixture.cache.appending(path: snapshot.id.uuidString + ".superseded")
    let metadata = try StorageFileMetadata.read(at: marker)
    #expect(metadata.st_size == 0)
    #expect(metadata.st_mode & 0o777 == 0o600)
    let reader = try StorageTreeReader(directoryURL: fixture.cache, snapshot: snapshot)
    // Invalidations are action authority in Service, not destructive changes to the
    // historical read-only index itself. Existing readers/restarts retain its rows.
    #expect(try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 10).rows.count == 1)
    #expect(try !StorageTreeReader.removeIfUnused(directoryURL: fixture.cache, id: snapshot.id))
    #expect(try StorageTreeReader.isSuperseded(directoryURL: fixture.cache, id: snapshot.id))
    await reader.close()
    #expect(try StorageTreeReader.removeIfUnused(directoryURL: fixture.cache, id: snapshot.id))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func storageTreeSupersededMarkerRollbackAndUnsafeNamesNeverTouchForeignFiles() throws {
    let fixture = try TreeFixture()
    defer { fixture.cleanup() }
    let provisional = UUID()
    #expect(try !StorageTreeReader.isSuperseded(directoryURL: fixture.cache, id: provisional))
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
    #expect(try StorageTreeReader.markSuperseded(directoryURL: fixture.cache, id: provisional))
    try StorageTreeReader.unmarkSuperseded(directoryURL: fixture.cache, id: provisional)
    #expect(try !StorageTreeReader.isSuperseded(directoryURL: fixture.cache, id: provisional))
    let id = UUID(), outside = fixture.directory.appending(path: "foreign")
    try Data([1, 2, 3]).write(to: outside)
    let marker = fixture.cache.appending(path: id.uuidString + ".superseded")
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)
    #expect(throws: StorageTreeIndexError.self) { try StorageTreeReader.isSuperseded(directoryURL: fixture.cache, id: id) }
    #expect(throws: StorageTreeIndexError.self) { try StorageTreeReader.markSuperseded(directoryURL: fixture.cache, id: id) }
    #expect(throws: StorageTreeIndexError.self) { try StorageTreeReader.unmarkSuperseded(directoryURL: fixture.cache, id: id) }
    #expect(try Data(contentsOf: outside) == Data([1, 2, 3]))
    #expect(try StorageFileMetadata.read(at: marker).st_mode & S_IFMT == S_IFLNK)
    try FileManager.default.removeItem(at: marker)
    try Data([9]).write(to: marker)
    #expect(chmod(marker.path, 0o600) == 0)
    #expect(throws: StorageTreeIndexError.self) { try StorageTreeReader.markSuperseded(directoryURL: fixture.cache, id: id) }
    #expect(try Data(contentsOf: marker) == Data([9]))
}
