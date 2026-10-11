import Darwin
import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private struct ScannerFixture {
    let root: URL
    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = repository.appending(path: "agent_temp_files_local/storage-scanner-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ path: String, bytes: Int) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct FixtureResourceReader: StorageResourceReading {
    let cloudNames: Set<String>
    let packageNames: Set<String>
    let unreadableNames: Set<String>
    init(cloudNames: Set<String> = [], packageNames: Set<String> = [], unreadableNames: Set<String> = []) {
        self.cloudNames = cloudNames; self.packageNames = packageNames; self.unreadableNames = unreadableNames
    }
    func hints(at url: URL) throws -> StorageResourceHints {
        if unreadableNames.contains(url.lastPathComponent) { throw POSIXError(.EACCES) }
        return StorageResourceHints(isPackage: packageNames.contains(url.lastPathComponent),
            isCloudPlaceholder: cloudNames.contains(url.lastPathComponent))
    }
}

@Test func storageScannerAggregatesRealNestedFilesAndKeepsCapacitySeparate() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    let a = try fixture.file("nested/a", bytes: 11)
    let b = try fixture.file("b", bytes: 17)
    let snapshot = try await StorageScanner().scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.isComplete)
    #expect(snapshot.scanMethod == .directoryTraversal)
    #expect(!snapshot.hasUnverifiedCoverage)
    #expect(snapshot.root?.logicalBytes == 28)
    let allocated = UInt64((try StorageFileMetadata.read(at: a)).st_blocks + (try StorageFileMetadata.read(at: b)).st_blocks) * 512
    #expect(snapshot.root?.allocatedBytes == allocated)
    #expect(snapshot.root?.fileCount == 2)
    let nested = try #require(snapshot.nodes.first { $0.relativePath == "nested" })
    #expect(nested.logicalBytes == 11)
    let nestedFile = try #require(snapshot.largestCatalog.first { $0.relativePath == "nested/a" })
    #expect(nestedFile.ancestors.map(\.relativePath) == ["", "nested"])
    #expect(nested.unlistedChildren.logicalBytes == 11)
    #expect(snapshot.largestItems(metric: .logical).first?.relativePath == "b")
    #expect(try #require(snapshot.volume?.totalBytes) > 28)
    try snapshot.validate()
}

@Test func storageScannerAggregatesEveryLevelOfARealDeepDirectoryTree() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    let depth = 64
    var relative = ""
    var directories: [String] = []
    var expectedAllocation: UInt64 = 0
    for level in 0..<depth {
        let name = String(format: "d%02d", level)
        relative = relative.isEmpty ? name : relative + "/" + name
        directories.append(relative)
        let side = try fixture.file(relative + "/side.dat", bytes: level + 1)
        expectedAllocation += UInt64((try StorageFileMetadata.read(at: side)).st_blocks) * 512
    }
    let deepestFile = try fixture.file(relative + "/deepest.dat", bytes: 37)
    expectedAllocation += UInt64((try StorageFileMetadata.read(at: deepestFile)).st_blocks) * 512
    let snapshot = try await StorageScanner().scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.isComplete)
    #expect(snapshot.nodes.count == 2)
    #expect(snapshot.root?.logicalBytes == 37 + UInt64(depth * (depth + 1) / 2))
    #expect(snapshot.root?.allocatedBytes == expectedAllocation)
    #expect(snapshot.root?.fileCount == depth + 1)
    let top = try #require(snapshot.nodes.first { $0.relativePath == "d00" })
    #expect(top.kind == .directory)
    #expect(top.logicalBytes == snapshot.root?.logicalBytes)
    #expect(top.unlistedChildren.logicalBytes == top.logicalBytes)
    #expect(top.unlistedChildCount == 2)
    let leaf = try #require(snapshot.largestCatalog.first { $0.relativePath == relative + "/deepest.dat" })
    #expect(leaf.identity == (try StorageFileMetadata.identity(at: deepestFile)))
    #expect(leaf.ancestors.map(\.relativePath) == [""] + directories)
    for ancestor in leaf.ancestors {
        let native = try StorageFileMetadata.identity(at: fixture.root.appending(path: ancestor.relativePath))
        #expect(ancestor.identity == native)
    }
    let restored = try JSONDecoder().decode(StorageSnapshot.self, from: JSONEncoder().encode(snapshot))
    try restored.validate()
    #expect(restored.nodes == snapshot.nodes)
}

@Test func storageScannerCountsHardLinksOnceAndNeverTraversesSymbolicLinkTargets() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    let original = try fixture.file("a", bytes: 100)
    let linked = fixture.root.appending(path: "hardlink")
    #expect(link(original.path, linked.path) == 0)
    let outside = fixture.root.deletingLastPathComponent().appending(path: "outside-scanner-\(UUID())")
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data(repeating: 3, count: 10_000).write(to: outside.appending(path: "must-not-scan"))
    let symlink = fixture.root.appending(path: "external")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "loop"), withDestinationURL: fixture.root)
    let snapshot = try await StorageScanner().scan(rootURL: fixture.root, grantID: UUID())
    let hardlinks = snapshot.nodes.filter { $0.kind == .file }
    #expect(hardlinks.count == 2)
    #expect(hardlinks.reduce(0) { $0 + $1.logicalBytes } == 100)
    #expect(hardlinks.reduce(0) { $0 + $1.allocatedBytes } == UInt64((try StorageFileMetadata.read(at: original)).st_blocks) * 512)
    #expect(hardlinks.filter(\.isHardLinkDuplicate).count == 1)
    #expect(hardlinks.allSatisfy { $0.apparentBytes == 100 })
    #expect(snapshot.nodes.filter { $0.kind == .symbolicLink }.count == 2)
    #expect(!snapshot.nodes.contains { $0.relativePath.contains("must-not-scan") })
    #expect(snapshot.isComplete)
}

@Test func storageScannerKeepsSparseAllocationDistinctAndPackagesOpaque() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    let sparse = fixture.root.appending(path: "sparse")
    let descriptor = open(sparse.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
    #expect(descriptor >= 0)
    defer { if descriptor >= 0 { close(descriptor) } }
    #expect(ftruncate(descriptor, 8 * 1_024 * 1_024) == 0)
    _ = try fixture.file("Archive.bundle/inside/deep.dat", bytes: 31)
    let reader = FixtureResourceReader(packageNames: ["Archive.bundle"])
    let snapshot = try await StorageScanner(resourceReader: reader).scan(rootURL: fixture.root, grantID: UUID())
    let sparseNode = try #require(snapshot.nodes.first { $0.relativePath == "sparse" })
    #expect(sparseNode.logicalBytes == 8 * 1_024 * 1_024)
    #expect(sparseNode.allocatedBytes < sparseNode.logicalBytes)
    let package = try #require(snapshot.nodes.first { $0.relativePath == "Archive.bundle" })
    #expect(package.kind == .package)
    #expect(package.logicalBytes == 31)
    #expect(package.fileCount == 1)
    #expect(snapshot.children(of: package.id).isEmpty)
    #expect(!snapshot.nodes.contains { $0.relativePath.hasPrefix("Archive.bundle/") })
    #expect(snapshot.root?.logicalBytes == 8 * 1_024 * 1_024 + 31)
    try snapshot.validate()
}

@Test func storageScannerReportsCloudOnlyDirectoriesWithoutEnumeratingOrOpeningTheirContents() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("remote/should-stay-cloud", bytes: 91)
    _ = try fixture.file("cloud-file", bytes: 71)
    let snapshot = try await StorageScanner(resourceReader: FixtureResourceReader(cloudNames: ["remote", "cloud-file"]))
        .scan(rootURL: fixture.root, grantID: UUID())
    #expect(!snapshot.isComplete)
    #expect(snapshot.issues.contains { $0.reason == .cloudPlaceholderDirectory })
    #expect(!snapshot.nodes.contains { $0.relativePath == "remote/should-stay-cloud" })
    let cloud = try #require(snapshot.nodes.first { $0.relativePath == "cloud-file" })
    #expect(cloud.isCloudPlaceholder)
    #expect(cloud.logicalBytes == 71)
    #expect(snapshot.root?.logicalBytes == 71)
    let rootCloud = try await StorageScanner(resourceReader: FixtureResourceReader(cloudNames: [fixture.root.lastPathComponent]))
        .scan(rootURL: fixture.root, grantID: UUID())
    #expect(rootCloud.nodes.count == 1)
    #expect(rootCloud.root?.logicalBytes == 0)
    #expect(!rootCloud.isComplete)
    #expect(rootCloud.scanMethod == .directoryTraversal)
}

@Test func storageScannerInjectedReaderKeepsMountedRootOnTraversalWithoutCatalogEnumeration() async throws {
    let root = URL(fileURLWithPath: "/")
    let snapshot = try await StorageScanner(resourceReader: AlwaysCloudRootReader())
        .scan(rootURL: root, grantID: UUID())
    #expect(snapshot.scanMethod == .directoryTraversal)
    #expect(!snapshot.hasUnverifiedCoverage)
    #expect(snapshot.nodes.count == 1)
    #expect(snapshot.root?.fileCount == 0)
    #expect(snapshot.root?.isCloudPlaceholder == true)
    #expect(snapshot.issues.contains { $0.reason == .cloudPlaceholderDirectory })
}

private struct AlwaysCloudRootReader: StorageResourceReading {
    func hints(at url: URL) throws -> StorageResourceHints {
        StorageResourceHints(isCloudPlaceholder: true, isVolumeRoot: true)
    }
}

@Test func storageScannerKeepsCloudPlaceholderStateOnTheResourceItself() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("local/remote/should-stay-cloud", bytes: 91)
    _ = try fixture.file("local/cloud-file", bytes: 71)
    _ = try fixture.file("local/local-file", bytes: 11)
    let reader = FixtureResourceReader(cloudNames: ["remote", "cloud-file"])
    let snapshot = try await StorageScanner(resourceReader: reader).scan(rootURL: fixture.root, grantID: UUID())
    let local = try #require(snapshot.nodes.first { $0.relativePath == "local" })
    #expect(snapshot.root?.isCloudPlaceholder == false)
    #expect(!local.isCloudPlaceholder)
    #expect(snapshot.root?.isIncomplete == true)
    #expect(local.isIncomplete)
    #expect(snapshot.root?.logicalBytes == 82)
    #expect(snapshot.issues.contains { $0.path == "local/remote" && $0.reason == .cloudPlaceholderDirectory })
    #expect(!snapshot.largestCatalog.contains { $0.relativePath == "local/remote/should-stay-cloud" })
    #expect(snapshot.largestCatalog.first { $0.relativePath == "local/cloud-file" }?.isCloudPlaceholder == true)
    // Viewing the local parent still identifies its genuine cloud-only child separately.
    let parent = try await StorageScanner(resourceReader: reader).scan(rootURL: fixture.root.appending(path: "local"), grantID: UUID())
    #expect(parent.root?.isCloudPlaceholder == false)
    #expect(parent.nodes.first { $0.relativePath == "remote" }?.isCloudPlaceholder == true)
    #expect(parent.nodes.first { $0.relativePath == "remote" }?.logicalBytes == 0)
}

@Test func storageScannerReportsReadFailuresButRetentionLimitsKeepCompleteTotals() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("denied/a", bytes: 3)
    #expect(chmod(fixture.root.appending(path: "denied").path, 0) == 0)
    defer { _ = chmod(fixture.root.appending(path: "denied").path, 0o700) }
    _ = try fixture.file("good", bytes: 7)
    let denied = try await StorageScanner().scan(rootURL: fixture.root, grantID: UUID())
    #expect(!denied.isComplete)
    #expect(denied.issues.contains { $0.reason == .permissionDenied || $0.reason == .unreadable })
    #expect(denied.root?.logicalBytes == 7)
    _ = chmod(fixture.root.appending(path: "denied").path, 0o700)
    for index in 0..<10 { _ = try fixture.file("many-\(index)", bytes: 1) }
    let bounded = try await StorageScanner(maximumNodes: 3).scan(rootURL: fixture.root, grantID: UUID())
    #expect(bounded.nodes.count <= 3)
    #expect(bounded.isComplete)
    #expect(bounded.root?.logicalBytes == 20)
    #expect(bounded.root?.fileCount == 12)
    #expect(try #require(bounded.root).unlistedChildCount > 0)
    #expect(!bounded.issues.contains { $0.reason == .limitReached })
    try bounded.validate()
}

private actor ScanPause {
    private var paused = false
    private var resumed = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        guard !paused else { return }
        paused = true
        waiter?.resume(); waiter = nil
        if !resumed { await withCheckedContinuation { release = $0 } }
    }
    func waitUntilPaused() async {
        if !paused { await withCheckedContinuation { waiter = $0 } }
    }
    func resume() { resumed = true; release?.resume(); release = nil }
}

@Test func cancellingStorageScanWhileProgressIsSuspendedReturnsNoSnapshot() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("a", bytes: 3)
    let pause = ScanPause()
    let task = Task { try await StorageScanner().scan(rootURL: fixture.root, grantID: UUID()) { _ in await pause.pause() } }
    await pause.waitUntilPaused()
    task.cancel()
    await pause.resume()
    await #expect(throws: CancellationError.self) { try await task.value }
    let afterCancellation = try await StorageScanner().scan(rootURL: fixture.root, grantID: UUID())
    #expect(afterCancellation.root?.logicalBytes == 3)
}

private final class ThreadCheckingResourceReader: StorageResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var mainThreadCalls = 0
    func hints(at url: URL) throws -> StorageResourceHints {
        lock.withLock { calls += 1; if Thread.isMainThread { mainThreadCalls += 1 } }
        return try NativeStorageResourceReader().hints(at: url)
    }
    var observedCalls: (Int, Int) { lock.withLock { (calls, mainThreadCalls) } }
}

private struct BoundaryResourceReader: StorageResourceReading {
    func hints(at url: URL) throws -> StorageResourceHints { StorageResourceHints() }
    func metadata(in directoryFD: CInt, name: String) throws -> stat {
        var metadata = stat()
        guard fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.EIO) }
        if name == "foreign" { metadata.st_dev ^= 1 }
        if name == "changed" { metadata.st_ino ^= 1 }
        return metadata
    }
}

private struct MountedRootResourceReader: StorageResourceReading {
    let volumeRoots: Set<String>
    func hints(at url: URL) throws -> StorageResourceHints {
        StorageResourceHints(isVolumeRoot: volumeRoots.contains(url.path))
    }
}

@Test func storageScannerSkipsDescendantMountedRootsEvenWhenTheyShareTheRootDevice() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    let mounted = fixture.root.appending(path: "mounted")
    _ = try fixture.file("mounted/duplicate-data", bytes: 31)
    let good = try fixture.file("good", bytes: 7)
    #expect(try StorageFileMetadata.identity(at: mounted).device == StorageFileMetadata.identity(at: fixture.root).device)
    let reader = MountedRootResourceReader(volumeRoots: [fixture.root.path, mounted.path])
    let snapshot = try await StorageScanner(resourceReader: reader).scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.root?.logicalBytes == 7)
    #expect(snapshot.root?.allocatedBytes == UInt64((try StorageFileMetadata.read(at: good)).st_blocks) * 512)
    #expect(snapshot.root?.fileCount == 1)
    #expect(!snapshot.nodes.contains { $0.relativePath == "mounted" || $0.relativePath.hasPrefix("mounted/") })
    #expect(snapshot.issues.contains { $0.path == "mounted" && $0.reason == .mountBoundary })
    #expect(!snapshot.isComplete)
    try snapshot.validate()
    // Selecting that mounted root explicitly still scans its contents.
    let selected = try await StorageScanner(resourceReader: reader).scan(rootURL: mounted, grantID: UUID())
    #expect(selected.isComplete)
    #expect(selected.root?.logicalBytes == 31)
    #expect(selected.root?.fileCount == 1)
}

@Test func storageScannerSkipsForeignVolumesAndDirectoriesThatChangedBetweenLookupAndOpen() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("foreign/do-not-cross", bytes: 31)
    _ = try fixture.file("changed/do-not-enter", bytes: 41)
    _ = try fixture.file("good", bytes: 7)
    let snapshot = try await StorageScanner(resourceReader: BoundaryResourceReader()).scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.root?.logicalBytes == 7)
    #expect(!snapshot.nodes.contains { $0.relativePath.contains("do-not-") })
    #expect(snapshot.issues.contains { $0.path == "foreign" && $0.reason == .mountBoundary })
    #expect(snapshot.issues.contains { $0.path == "changed" && $0.reason == .changedDuringScan })
    #expect(!snapshot.isComplete)
}

@Test func storageScannerTreatsASelectedPackageAsAnOpaqueAggregate() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("Contents/a", bytes: 31)
    let snapshot = try await StorageScanner(resourceReader: FixtureResourceReader(packageNames: [fixture.root.lastPathComponent]))
        .scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.nodes.count == 1)
    #expect(snapshot.root?.kind == .package)
    #expect(snapshot.root?.logicalBytes == 31)
    #expect(snapshot.root?.fileCount == 1)
    try snapshot.validate()
}

private struct EnormousMetadataReader: StorageResourceReading {
    func hints(at url: URL) throws -> StorageResourceHints { StorageResourceHints() }
    func metadata(in directoryFD: CInt, name: String) throws -> stat {
        var metadata = stat()
        guard fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.EIO) }
        if metadata.st_mode & S_IFMT == S_IFREG { metadata.st_size = Int64.max; metadata.st_blocks = 0 }
        return metadata
    }
}

@Test func storageScannerRejectsUnrepresentableTotalsInsteadOfWrappingOrCrashing() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    for name in ["a", "b", "c"] { _ = try fixture.file(name, bytes: 1) }
    await #expect(throws: StorageScannerError.self) {
        try await StorageScanner(resourceReader: EnormousMetadataReader()).scan(rootURL: fixture.root, grantID: UUID())
    }
}

@Test func storageScannerSkipsDirectoriesWhenPackageOrCloudMetadataCannotBeClassified() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("unknown/should-not-enumerate", bytes: 41)
    _ = try fixture.file("good", bytes: 7)
    let snapshot = try await StorageScanner(resourceReader: FixtureResourceReader(unreadableNames: ["unknown"]))
        .scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.root?.logicalBytes == 7)
    #expect(!snapshot.nodes.contains { $0.relativePath == "unknown/should-not-enumerate" })
    #expect(snapshot.issues.contains { $0.path == "unknown" && $0.reason == .unreadable })
    #expect(!snapshot.isComplete)
}

@MainActor @Test func storageScannerNativeMetadataWorkRunsAwayFromMainActor() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("a", bytes: 3)
    let reader = ThreadCheckingResourceReader()
    let snapshot = try await StorageScanner(resourceReader: reader).scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.root?.logicalBytes == 3)
    #expect(reader.observedCalls.0 >= 2)
    #expect(reader.observedCalls.1 == 0)
}

@Test func storageScannerFinishesAllEntriesBeyondRetentionAndKeepsGlobalLargestForBothMetrics() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.cleanup() }
    var expectedLogical: UInt64 = 0
    var expectedAllocated: UInt64 = 0
    for index in 1...320 {
        let file = try fixture.file("small-\(index)", bytes: index)
        expectedLogical += UInt64(index)
        expectedAllocated += UInt64((try StorageFileMetadata.read(at: file)).st_blocks) * 512
    }
    let ordinary = try fixture.file("deep/inside/allocated.bin", bytes: 32_768)
    expectedLogical += 32_768
    expectedAllocated += UInt64((try StorageFileMetadata.read(at: ordinary)).st_blocks) * 512
    let sparse = fixture.root.appending(path: "sparse.bin")
    let fd = open(sparse.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
    #expect(fd >= 0)
    defer { if fd >= 0 { close(fd) } }
    #expect(ftruncate(fd, 64 * 1_024 * 1_024) == 0)
    expectedLogical += 64 * 1_024 * 1_024
    expectedAllocated += UInt64((try StorageFileMetadata.read(at: sparse)).st_blocks) * 512
    let snapshot = try await StorageScanner(maximumNodes: 3, largestLimit: 1).scan(rootURL: fixture.root, grantID: UUID())
    #expect(snapshot.isComplete)
    #expect(snapshot.nodes.count <= 3)
    #expect(snapshot.largestCatalog.count == 2)
    #expect(snapshot.root?.logicalBytes == expectedLogical)
    #expect(snapshot.root?.allocatedBytes == expectedAllocated)
    #expect(snapshot.root?.fileCount == 322)
    let root = try #require(snapshot.root)
    let children = snapshot.childReferences(of: 0)
    #expect(children.reduce(root.unlistedChildren.logicalBytes) { $0 + $1.logicalBytes } == expectedLogical)
    #expect(root.unlistedChildCount + children.count == 322)
    #expect(snapshot.largestItems(metric: .logical, limit: 1).first?.relativePath == "sparse.bin")
    #expect(snapshot.largestItems(metric: .allocated, limit: 1).first?.relativePath == "deep/inside/allocated.bin")
    for item in snapshot.largestCatalog {
        #expect(snapshot.itemReference(id: item.id) == item)
        if let node = snapshot.nodes.first(where: { $0.relativePath == item.relativePath }) { #expect(node.id == item.id) }
    }
    let decoded = try JSONDecoder().decode(StorageSnapshot.self, from: JSONEncoder().encode(snapshot))
    try decoded.validate()
    #expect(decoded.largestCatalog == snapshot.largestCatalog)
}
