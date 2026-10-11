import Darwin
import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private final class FixtureCatalog: StorageCatalogReading {
    let entries: [StorageCatalogEntry]
    private let beforeBatch: (() throws -> Void)?
    private var returned = false
    init(_ entries: [StorageCatalogEntry], beforeBatch: (() throws -> Void)? = nil) {
        self.entries = entries; self.beforeBatch = beforeBatch
    }
    func nextBatch() throws -> StorageCatalogBatch {
        if !returned { try beforeBatch?() }
        defer { returned = true }
        return StorageCatalogBatch(entries: returned ? [] : entries, isComplete: true)
    }
}
private final class ReplacingFixtureCatalog: StorageCatalogReading {
    private let first: [StorageCatalogEntry]
    private let replacement: () throws -> [StorageCatalogEntry]
    private var returned = false
    init(first: [StorageCatalogEntry], replacement: @escaping () throws -> [StorageCatalogEntry]) {
        self.first = first; self.replacement = replacement
    }
    func nextBatch() throws -> StorageCatalogBatch {
        if !returned { returned = true; return StorageCatalogBatch(entries: first, isComplete: false) }
        return StorageCatalogBatch(entries: try replacement(), isComplete: true)
    }
}
private struct CatalogFixtureHints: StorageResourceReading {
    func hints(at url: URL) throws -> StorageResourceHints {
        StorageResourceHints(isPackage: url.lastPathComponent == "Archive.bundle", isCloudPlaceholder: url.lastPathComponent == "remote")
    }
}
private final class CatalogHintSpy: StorageResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func hints(at url: URL) throws -> StorageResourceHints {
        lock.withLock { paths.append(url.path) }
        return StorageResourceHints()
    }
    var observedPaths: [String] { lock.withLock { paths } }
}
private final class CatalogActionProbe: StorageResourceAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var trashCalls: Int { lock.withLock { calls } }
    func bookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        (URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), false)
    }
    func start(_ url: URL) throws -> Bool { true }
    func stop(_ url: URL) {}
    func trash(_ url: URL) throws { lock.withLock { calls += 1 } }
    func reveal(_ url: URL) async throws {}
}
private struct CatalogFixture {
    let root: URL
    init(shortName: Bool = false) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let name = shortName ? "cs-" + UUID().uuidString.prefix(8) : "catalog-fixture-\(UUID())"
        root = repository.appending(path: "agent_temp_files_local/\(name)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func plan() throws -> StorageCatalogVolumePlan {
        try StorageCatalogVolumePlan(mountPath: URL(fileURLWithPath: "/System/Volumes/Data"), rootURL: root,
            mappings: [StorageCatalogPathMapping(nativePrefix: root.path, visiblePrefix: root.path)])
    }
    func entries() throws -> [StorageCatalogEntry] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try enumerator.compactMap { value -> StorageCatalogEntry? in
            guard let url = value as? URL else { return nil }
            let metadata = try StorageFileMetadata.read(at: url)
            let parent = try StorageFileMetadata.read(at: url.deletingLastPathComponent())
            let type = metadata.st_mode & S_IFMT
            return StorageCatalogEntry(name: url.lastPathComponent, inode: metadata.st_ino, parentInode: parent.st_ino,
                device: UInt64(UInt32(bitPattern: metadata.st_dev)),
                type: UInt32(type == S_IFDIR ? VDIR.rawValue : type == S_IFLNK ? VLNK.rawValue : VREG.rawValue),
                birthSeconds: Int64(metadata.st_birthtimespec.tv_sec), birthNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec),
                flags: metadata.st_flags, logicalBytes: UInt64(max(0, metadata.st_size)),
                allocatedBytes: UInt64(max(0, metadata.st_blocks)) * 512, linkCount: UInt32(metadata.st_nlink))
        }
    }
}

@Test func storageCatalogNativeHintModePreservesPackageAndVolumeClassification() throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("ordinary/a", bytes: 1)
    _ = try fixture.file("Sample.app/Contents/a", bytes: 1)
    let reader = NativeStorageResourceReader()
    let urls = [URL(fileURLWithPath: "/"), fixture.root.appending(path: "ordinary"), fixture.root.appending(path: "Sample.app")]
    var observedPackages = 0, observedVolumes = 0
    for url in urls {
        let traversal = try reader.hints(at: url, isDirectory: true, mode: .directoryTraversal)
        let catalog = try reader.hints(at: url, isDirectory: true, mode: .volumeCatalog)
        #expect(catalog.isPackage == traversal.isPackage)
        #expect(catalog.isVolumeRoot == traversal.isVolumeRoot)
        #expect(!catalog.isCloudPlaceholder)
        observedPackages += catalog.isPackage ? 1 : 0
        observedVolumes += catalog.isVolumeRoot ? 1 : 0
    }
    #expect(observedPackages == 1)
    #expect(observedVolumes == 1)
    // Readers supplying explicit legacy cloud information retain that behavior through
    // the protocol default; the native optimization must not discard injected hints.
    let injected = try CatalogFixtureHints().hints(at: fixture.root.appending(path: "remote"),
        isDirectory: true, mode: .volumeCatalog)
    #expect(injected.isCloudPlaceholder)
}

@Test func storageCatalogScannerUsesNativeKindsWhenCatalogReportsAllLeavesAsRegularFiles() async throws {
    let fixture = try CatalogFixture(shortName: true)
    defer { fixture.cleanup() }
    _ = try fixture.file("directory/a", bytes: 19)
    try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "directory-link"), withDestinationURL: fixture.root.appending(path: "directory"))
    try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "loop"), withDestinationURL: fixture.root)
    #expect(mkfifo(fixture.root.appending(path: "named-pipe").path, 0o600) == 0)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    defer { if descriptor >= 0 { close(descriptor) } }
    let socketPath = fixture.root.appending(path: "native.socket").path
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    #expect(socketPath.utf8.count < pathCapacity)
    withUnsafeMutablePointer(to: &address.sun_path) { path in
        path.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
            socketPath.withCString { source in _ = strncpy(destination, source, pathCapacity) }
        }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(bound == 0)
    let entries = try fixture.entries().map { entry in
        StorageCatalogEntry(name: entry.name, inode: entry.inode, parentInode: entry.parentInode, device: entry.device,
            type: entry.type == UInt32(VDIR.rawValue) ? entry.type : UInt32(VREG.rawValue),
            birthSeconds: entry.birthSeconds, birthNanoseconds: entry.birthNanoseconds,
            flags: entry.flags, logicalBytes: entry.logicalBytes, allocatedBytes: entry.allocatedBytes, linkCount: entry.linkCount)
    }
    let catalog = try await StorageCatalogScanner().scan(rootURL: fixture.root, grantID: UUID(), plans: [fixture.plan()],
        makeReader: { _ in FixtureCatalog(entries) })
    let traversal = try await StorageScanner().scan(rootURL: fixture.root, grantID: UUID())
    #expect(catalog.root?.fileCount == 1)
    #expect(catalog.root?.fileCount == traversal.root?.fileCount)
    #expect(catalog.root?.logicalBytes == traversal.root?.logicalBytes)
    #expect(catalog.root?.allocatedBytes == traversal.root?.allocatedBytes)
    #expect(catalog.nodes.first { $0.relativePath == "directory-link" }?.kind == .symbolicLink)
    #expect(catalog.nodes.first { $0.relativePath == "loop" }?.kind == .symbolicLink)
    #expect(catalog.nodes.first { $0.relativePath == "named-pipe" }?.kind == .other)
    #expect(catalog.nodes.first { $0.relativePath == "native.socket" }?.kind == .other)
    #expect(!catalog.largestCatalog.contains { ["directory-link", "loop", "named-pipe", "native.socket"].contains($0.relativePath) })
    #expect(catalog.hasUnverifiedCoverage)
    #expect(!catalog.isComplete)
    #expect(catalog.issues.isEmpty)
    #expect(catalog.root?.isIncomplete == false)
    try catalog.validate()
}

@Test func storageCatalogScannerMatchesTraversalTotalsAndOpaqueCloudRules() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    let original = try fixture.file("local/a", bytes: 19)
    #expect(link(original.path, fixture.root.appending(path: "linked").path) == 0)
    _ = try fixture.file("Archive.bundle/nested/b", bytes: 23)
    _ = try fixture.file("local/remote/must-not-count", bytes: 9_999)
    _ = try fixture.file("deep/inside/c", bytes: 31)
    try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "loop"), withDestinationURL: fixture.root)
    let entries = try fixture.entries().reversed()
    let catalog = try await StorageCatalogScanner(resourceReader: CatalogFixtureHints()).scan(rootURL: fixture.root,
        grantID: UUID(), plans: [fixture.plan()], makeReader: { _ in FixtureCatalog(Array(entries)) })
    let traversal = try await StorageScanner(resourceReader: CatalogFixtureHints()).scan(rootURL: fixture.root, grantID: UUID())
    #expect(catalog.root?.logicalBytes == traversal.root?.logicalBytes)
    #expect(catalog.root?.allocatedBytes == traversal.root?.allocatedBytes)
    #expect(catalog.root?.apparentBytes == traversal.root?.apparentBytes)
    #expect(catalog.root?.fileCount == traversal.root?.fileCount)
    #expect(!catalog.isComplete)
    #expect(catalog.issues.contains { $0.reason == .cloudPlaceholderDirectory })
    #expect(!catalog.largestCatalog.contains { $0.relativePath.contains("must-not-count") || $0.relativePath.hasPrefix("Archive.bundle/") })
    #expect(catalog.nodes.first { $0.relativePath == "Archive.bundle" }?.logicalBytes == 23)
    #expect(catalog.largestCatalog.first { $0.relativePath == "Archive.bundle" }?.logicalBytes == 23)
    #expect(catalog.nodes.first { $0.relativePath == "local" }?.unlistedChildCount == 2)
    try catalog.validate()
}

@Test(arguments: [false, true])
func storageCatalogRepeatedHardLinkRecordDoesNotAddBytesOrAnotherFile(fullTree: Bool) async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    let original = try fixture.file("folder/original", bytes: 19)
    #expect(link(original.path, fixture.root.appending(path: "folder/alias").path) == 0)
    _ = try fixture.file("ordinary", bytes: 23)
    let entries = try fixture.entries()
    let repeated = try #require(entries.first { $0.name == "original" })
    let traversal = try await StorageScanner().scan(rootURL: fixture.root, grantID: UUID())
    let catalog = try await StorageCatalogScanner(treeDirectory: fullTree ? fixture.root.appending(path: "indexes") : nil)
        .scan(rootURL: fixture.root, grantID: UUID(), plans: [fixture.plan()],
            makeReader: { _ in FixtureCatalog(entries + [repeated, repeated]) })
    #expect(catalog.root?.fileCount == 3)
    #expect(catalog.root?.logicalBytes == traversal.root?.logicalBytes)
    #expect(catalog.root?.allocatedBytes == traversal.root?.allocatedBytes)
    #expect(catalog.root?.apparentBytes == traversal.root?.apparentBytes)
    #expect(catalog.issues.isEmpty)
    if fullTree {
        #expect(catalog.tree?.nodeCount == 5)
        let reader = try StorageTreeReader(directoryURL: fixture.root.appending(path: "indexes"), snapshot: catalog)
        let roots = try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 10)
        let folder = try #require(roots.rows.first { $0.name == "folder" })
        let files = try await reader.children(parentID: folder.id, metric: .logical, offset: 0, limit: 10)
        #expect(Set(files.rows.map(\.name)) == ["original", "alias"])
        #expect(files.rows.filter(\.isHardLinkDuplicate).count == 1)
        await reader.close()
    }
}

@Test func storageCatalogFullTreeRepeatsOrdinaryLeafButRejectsChangedHistoricalSizes() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("ordinary", bytes: 23)
    let entries = try fixture.entries(), record = try #require(entries.first)
    let cache = fixture.root.appending(path: "indexes")
    let snapshot = try await StorageCatalogScanner(treeDirectory: cache).scan(rootURL: fixture.root,
        grantID: UUID(), plans: [fixture.plan()], makeReader: { _ in FixtureCatalog(entries + entries) })
    #expect(snapshot.root?.fileCount == 1)
    #expect(snapshot.root?.logicalBytes == 23)
    #expect(snapshot.root?.apparentBytes == 23)
    #expect(snapshot.tree?.nodeCount == 2)
    let changed = StorageCatalogEntry(name: record.name, inode: record.inode, parentInode: record.parentInode,
        device: record.device, type: record.type, birthSeconds: record.birthSeconds, birthNanoseconds: record.birthNanoseconds,
        flags: record.flags, logicalBytes: record.logicalBytes + 1, allocatedBytes: record.allocatedBytes, linkCount: record.linkCount)
    let failure = await #expect(throws: StorageTreeIndexError.self) {
        try await StorageCatalogScanner(treeDirectory: cache).scan(rootURL: fixture.root, grantID: UUID(),
            plans: [fixture.plan()], makeReader: { _ in FixtureCatalog(entries + [changed]) })
    }
    if case let .collision(path, _, incoming)? = failure {
        #expect(path == "ordinary")
        #expect(incoming.contains("logical=24,"))
    } else { Issue.record("Changed catalog bytes must remain an identified conflict") }
    let reader = try StorageTreeReader(directoryURL: cache, snapshot: snapshot)
    #expect(try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 10).rows.count == 1)
    await reader.close()
}

@Test func storageCatalogOmitsSecondIdentityAtAcceptedLeafNameWithoutDoubleCountingOrAdoptingReplacement() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    let changing = try fixture.file("changing/file", bytes: 17)
    for index in 0..<65 { _ = try fixture.file("filler-\(index)/file", bytes: 3) }
    let originalEntries = try fixture.entries()
    let original = try #require(originalEntries.first { $0.name == "file" && $0.logicalBytes == 17 })
    let fillers = originalEntries.filter { $0.type != UInt32(VDIR.rawValue) && $0.inode != original.inode }
    #expect(fillers.count == 65)
    let cache = fixture.root.appending(path: "storage-trees")
    let action = CatalogActionProbe()
    let service = StorageService(grantsURL: fixture.root.appending(path: "grants.json"),
        cacheURL: fixture.root.appending(path: "snapshots.json"), resourceAccess: action)
    let grant = try await service.selectFolder(fixture.root)
    let snapshot = try await StorageCatalogScanner(maximumNodes: 100, largestLimit: 100, treeDirectory: cache)
        .scan(rootURL: fixture.root, grantID: grant.id, plans: [fixture.plan()], makeReader: { _ in
            // More than 64 parent maps evict the first parent. The second batch must
            // validate current native metadata, not merely hit a stale bulk cache.
            ReplacingFixtureCatalog(first: [original] + fillers, replacement: {
                let previous = fixture.root.appending(path: "previous-source")
                try FileManager.default.moveItem(at: changing, to: previous)
                try Data(repeating: 9, count: 999).write(to: changing)
                let peer = fixture.root.appending(path: "changing/peer")
                #expect(link(changing.path, peer.path) == 0)
                let entries = try fixture.entries()
                let replacement = try #require(entries.first { $0.name == "file" && $0.logicalBytes == 999 })
                let linked = try #require(entries.first { $0.name == "peer" })
                #expect(replacement.inode != original.inode || replacement.birthSeconds != original.birthSeconds
                    || replacement.birthNanoseconds != original.birthNanoseconds)
                return [replacement, linked]
            })
        })
    #expect(snapshot.root?.logicalBytes == 17 + 65 * 3 + 999)
    #expect(snapshot.root?.apparentBytes == 17 + 65 * 3 + 999)
    #expect(snapshot.root?.fileCount == 67)
    #expect(snapshot.root?.isIncomplete == true)
    #expect(snapshot.issues.contains { $0.path == "changing/file" && $0.reason == .changedDuringScan })
    let reader = try StorageTreeReader(directoryURL: cache, snapshot: snapshot)
    let roots = try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 100)
    let directory = try #require(roots.rows.first { $0.name == "changing" })
    #expect(directory.isIncomplete)
    let children = try await reader.children(parentID: directory.id, metric: .logical, offset: 0, limit: 10)
    #expect(children.rows.count == 2)
    let old = try #require(children.rows.first { $0.name == "file" })
    let peer = try #require(children.rows.first { $0.name == "peer" })
    #expect(old.totals.logicalBytes == 17)
    #expect(old.isIncomplete)
    #expect(try await reader.item(id: old.id)?.identity.inode == original.inode)
    #expect(snapshot.largestCatalog.contains { $0.id == old.id && $0.isIncomplete })
    let stale = try #require(try await reader.item(id: old.id))
    let result = try await service.trash(items: [stale], in: snapshot)
    #expect(result.trashedNodeIDs.isEmpty)
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.message.contains("replaced") == true)
    #expect(action.trashCalls == 0)
    #expect(peer.totals.logicalBytes == 999)
    #expect(!peer.isHardLinkDuplicate)
    #expect(try Data(contentsOf: changing) == Data(repeating: 9, count: 999))
    #expect(try Data(contentsOf: fixture.root.appending(path: "previous-source")) == Data(repeating: 1, count: 17))
    await reader.close()
    await service.releaseTree(snapshotID: snapshot.id)
}

@Test func storageCatalogScannerRejectsStateLimitAndOmitsChangedHistoricalLeaf() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("a", bytes: 7)
    _ = try fixture.file("b", bytes: 11)
    let entries = try fixture.entries()
    await #expect(throws: StorageCatalogScanError.self) {
        try await StorageCatalogScanner(retainedStateLimit: 1).scan(rootURL: fixture.root,
            grantID: UUID(), plans: [fixture.plan()], makeReader: { _ in FixtureCatalog(entries) })
    }
    try FileManager.default.removeItem(at: file)
    _ = try fixture.file("a", bytes: 7)
    let snapshot = try await StorageCatalogScanner().scan(rootURL: fixture.root,
        grantID: UUID(), plans: [fixture.plan()], makeReader: { _ in FixtureCatalog(entries) })
    #expect(snapshot.root?.logicalBytes == 11)
    #expect(snapshot.root?.fileCount == 1)
    #expect(!snapshot.isComplete)
    #expect(snapshot.issues.contains { $0.path == "a" && $0.reason == .changedDuringScan })
    #expect(!snapshot.nodes.contains { $0.relativePath == "a" })
    #expect(!snapshot.largestCatalog.contains { $0.relativePath == "a" })
    try snapshot.validate()
}

@Test(arguments: [false, true])
func storageCatalogScannerOmitsLeafReplacedAfterBatchReadWithoutAdoptingNewIdentity(replaceWithDirectory: Bool) async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    let changed = try fixture.file("outer/Archive.bundle/changing", bytes: 101)
    _ = try fixture.file("outer/Archive.bundle/kept", bytes: 23)
    let entries = try fixture.entries()
    let snapshot = try await StorageCatalogScanner(resourceReader: CatalogFixtureHints()).scan(rootURL: fixture.root,
        grantID: UUID(), plans: [fixture.plan()], makeReader: { _ in
            FixtureCatalog(entries, beforeBatch: {
                try FileManager.default.removeItem(at: changed)
                if replaceWithDirectory { try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false) }
                else { try Data(repeating: 9, count: 9_999).write(to: changed) }
            })
        })
    #expect(snapshot.root?.logicalBytes == 23)
    #expect(snapshot.root?.apparentBytes == 23)
    #expect(snapshot.root?.fileCount == 1)
    #expect(snapshot.root?.isIncomplete == true)
    #expect(snapshot.nodes.first { $0.relativePath == "outer" }?.isIncomplete == true)
    let package = try #require(snapshot.largestCatalog.first { $0.relativePath == "outer/Archive.bundle" })
    #expect(package.isIncomplete)
    #expect(package.logicalBytes == 23)
    #expect(package.fileCount == 1)
    #expect(snapshot.issues.contains { $0.path == "outer/Archive.bundle/changing" && $0.reason == .changedDuringScan })
    #expect(!snapshot.nodes.contains { $0.relativePath == "outer/Archive.bundle/changing" })
    #expect(!snapshot.largestCatalog.contains { $0.relativePath == "outer/Archive.bundle/changing" })
    try snapshot.validate()
}

@Test func storageCatalogScannerRejectsHistoricalDirectoryBirthEvenIfCurrentPathExists() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("directory/a", bytes: 7)
    let entries = try fixture.entries().map { entry in
        StorageCatalogEntry(name: entry.name, inode: entry.inode, parentInode: entry.parentInode, device: entry.device,
            type: entry.type, birthSeconds: entry.birthSeconds, birthNanoseconds: entry.type == UInt32(VDIR.rawValue)
                ? (entry.birthNanoseconds + 1) % 1_000_000_000 : entry.birthNanoseconds,
            flags: entry.flags, logicalBytes: entry.logicalBytes, allocatedBytes: entry.allocatedBytes, linkCount: entry.linkCount)
    }
    let failure = await #expect(throws: StorageCatalogScanError.self) {
        try await StorageCatalogScanner().scan(rootURL: fixture.root,
            grantID: UUID(), plans: [fixture.plan()], makeReader: { _ in FixtureCatalog(entries) })
    }
    if case let .changedItem(path, reason)? = failure {
        #expect(path == "directory")
        #expect(reason.contains("directory historical"))
    } else { Issue.record("Expected an identified directory mismatch, distinct from a kernel catalog-generation change") }
}

@Test func storageCatalogScannerMarksNestedOpaquePackageIncompleteForCloudChild() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("outer/Archive.bundle/local", bytes: 23)
    _ = try fixture.file("outer/Archive.bundle/remote/must-not-count", bytes: 9_999)
    let entries = try fixture.entries().reversed()
    let snapshot = try await StorageCatalogScanner(resourceReader: CatalogFixtureHints()).scan(rootURL: fixture.root,
        grantID: UUID(), plans: [fixture.plan()], makeReader: { _ in FixtureCatalog(Array(entries)) })
    let package = try #require(snapshot.largestCatalog.first { $0.relativePath == "outer/Archive.bundle" })
    #expect(package.logicalBytes == 23)
    #expect(package.isIncomplete)
    #expect(snapshot.scanMethod == .volumeCatalog)
    try snapshot.validate()
}

@Test func storageCatalogScannerHonorsSelectedRootCloudAndPackageOpacity() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("remote/must-not-count", bytes: 9_999)
    let cloudRoot = fixture.root.appending(path: "remote")
    let cloudPlan = try StorageCatalogVolumePlan(mountPath: URL(fileURLWithPath: "/System/Volumes/Data"), rootURL: cloudRoot,
        mappings: [StorageCatalogPathMapping(nativePrefix: cloudRoot.path, visiblePrefix: cloudRoot.path)])
    let cloud = try await StorageCatalogScanner(resourceReader: CatalogFixtureHints()).scan(rootURL: cloudRoot,
        grantID: UUID(), plans: [cloudPlan], makeReader: { _ in throw StorageCatalogScanError.invalidNamespace })
    #expect(cloud.root?.logicalBytes == 0)
    #expect(cloud.root?.isCloudPlaceholder == true)
    #expect(!cloud.isComplete)
    _ = try fixture.file("Archive.bundle/inside/a", bytes: 31)
    let packageRoot = fixture.root.appending(path: "Archive.bundle")
    let packagePlan = try StorageCatalogVolumePlan(mountPath: URL(fileURLWithPath: "/System/Volumes/Data"), rootURL: packageRoot,
        mappings: [StorageCatalogPathMapping(nativePrefix: packageRoot.path, visiblePrefix: packageRoot.path)])
    let entries = try fixture.entries()
    let package = try await StorageCatalogScanner(resourceReader: CatalogFixtureHints()).scan(rootURL: packageRoot,
        grantID: UUID(), plans: [packagePlan], makeReader: { _ in FixtureCatalog(entries) })
    #expect(package.root?.kind == .package)
    #expect(package.root?.logicalBytes == 31)
    #expect(package.nodes.count == 1)
    #expect(package.largestCatalog.isEmpty)
    try package.validate()
}

@Test func storageSnapshotBuilderRejectsListedContributionExceedingRoot() throws {
    let identity = StorageFileIdentity(device: 1, inode: 2, birthSeconds: 3, birthNanoseconds: 0)
    let root = ScanItem(name: "root", relativePath: "", kind: .directory, identity: identity, ancestors: [])
    root.childCount = 1
    let child = StorageItemReference(id: 0, name: "a", relativePath: "a", kind: .file, identity: identity,
        totals: StorageTotals(logicalBytes: 7, allocatedBytes: 0, apparentBytes: 7, fileCount: 1),
        ancestors: [StoragePathIdentity(relativePath: "", identity: identity)])
    #expect(throws: StorageSnapshotValidationError.self) {
        try StorageSnapshotBuilder.build(rootURL: URL(fileURLWithPath: "/"), grantID: UUID(), root: root,
            overview: [child], largest: [], issues: [], omittedIssues: 0)
    }
}

@Test func storageCatalogScannerCancellationAfterInitialProgressDoesNotOpenCatalog() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    let task = Task {
        try await StorageCatalogScanner().scan(rootURL: fixture.root, grantID: UUID(), plans: [fixture.plan()],
            makeReader: { _ in throw StorageCatalogScanError.invalidNamespace },
            progress: { _ in withUnsafeCurrentTask { $0?.cancel() } })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func storageCatalogScannerDisablesMaterializationForReaderCreationAndEveryBatch() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("a", bytes: 7)
    let entries = try fixture.entries()
    let snapshot = try await StorageCatalogScanner().scan(rootURL: fixture.root, grantID: UUID(),
        plans: [fixture.plan()], makeReader: { _ in
            #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
                == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            return PolicyCheckingCatalog(entries)
        })
    #expect(snapshot.root?.fileCount == 1)
    #expect(snapshot.root?.logicalBytes == 7)
    // Restoration is verified separately by synchronous native policy tests. Checking
    // the policy here after await would observe a potentially different worker thread.
}

private final class PolicyCheckingCatalog: StorageCatalogReading {
    let entries: [StorageCatalogEntry]
    private var returned = false
    init(_ entries: [StorageCatalogEntry]) { self.entries = entries }
    func nextBatch() throws -> StorageCatalogBatch {
        #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { returned = true }
        return StorageCatalogBatch(entries: returned ? [] : entries, isComplete: returned)
    }
}

@Test func storageCatalogTreeRetainsPackageContentsAndEveryNestedDirectory() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("outer/deep/a", bytes: 19)
    _ = try fixture.file("outer/Archive.bundle/Contents/b", bytes: 23)
    _ = try fixture.file("outer/remote/not-local", bytes: 9_999)
    let entries = try fixture.entries().reversed()
    let cache = fixture.root.appending(path: "indexes")
    let snapshot = try await StorageCatalogScanner(maximumNodes: 2, largestLimit: 1,
        resourceReader: CatalogFixtureHints(), treeDirectory: cache).scan(rootURL: fixture.root,
            grantID: UUID(), plans: [fixture.plan()], makeReader: { _ in FixtureCatalog(Array(entries)) })
    #expect(snapshot.schemaVersion == 3)
    #expect(snapshot.root?.logicalBytes == 42)
    #expect(snapshot.root?.fileCount == 2)
    let reader = try StorageTreeReader(directoryURL: cache, snapshot: snapshot)
    let root = try await reader.children(parentID: 0, metric: .logical, offset: 0, limit: 20)
    let outer = try #require(root.rows.first)
    #expect(outer.name == "outer")
    let page = try await reader.children(parentID: outer.id, metric: .logical, offset: 0, limit: 20)
    #expect(Set(page.rows.map(\.name)) == ["deep", "Archive.bundle", "remote"])
    let package = try #require(page.rows.first { $0.kind == .package })
    let contents = try await reader.children(parentID: package.id, metric: .logical, offset: 0, limit: 20)
    let directory = try #require(contents.rows.first)
    let leafPage = try await reader.children(parentID: directory.id, metric: .logical, offset: 0, limit: 20)
    let leaf = try #require(leafPage.rows.first)
    let reference = try #require(try await reader.item(id: leaf.id))
    #expect(reference.relativePath == "outer/Archive.bundle/Contents/b")
    #expect(reference.isInsidePackage)
    #expect(reference.ancestors.map(\.relativePath) == ["", "outer", "outer/Archive.bundle", "outer/Archive.bundle/Contents"])
    let remote = try #require(page.rows.first { $0.name == "remote" })
    #expect(remote.isCloudPlaceholder)
    #expect(remote.childCount == 0)
    #expect(try await reader.children(parentID: remote.id, metric: .logical, offset: 0, limit: 20).rows.isEmpty)
    await reader.close()
}

@Test func storageCatalogScannerRejectsSymlinkAncestorBeforeRequestingResourceHints() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("target/a", bytes: 7)
    let target = fixture.root.appending(path: "target")
    let ancestor = fixture.root.appending(path: "ancestor")
    try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: target)
    let plan = try StorageCatalogVolumePlan(mountPath: URL(fileURLWithPath: "/System/Volumes/Data"), rootURL: fixture.root,
        mappings: [StorageCatalogPathMapping(nativePrefix: target.path, visiblePrefix: ancestor.path)])
    let entries = try fixture.entries()
    let spy = CatalogHintSpy()
    await #expect(throws: StorageCatalogScanError.self) {
        try await StorageCatalogScanner(resourceReader: spy).scan(rootURL: fixture.root, grantID: UUID(), plans: [plan],
            makeReader: { _ in FixtureCatalog(entries) })
    }
    #expect(spy.observedPaths.contains(fixture.root.path))
    #expect(!spy.observedPaths.contains(ancestor.path))
    #expect(!spy.observedPaths.contains(ancestor.appending(path: "a").path))
}
