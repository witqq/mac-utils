import Darwin
import Foundation
import MacUtilsCore
@testable import MacUtilsSystem
import Testing

private struct MetadataCacheFixture {
    let root: URL
    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = repository.appending(path: "agent_temp_files_local/metadata-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7]).write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func storageDatalessPolicyRestoresOriginalThreadPolicyAfterSuccessAndThrow() throws {
    let original = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    StorageDatalessPolicy.withMaterializationDisabled { enabled in
        if enabled {
            #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        }
    }
    #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == original)
    #expect(throws: StorageCatalogReaderError.catalogChanged) {
        try StorageDatalessPolicy.withMaterializationDisabled { _ in throw StorageCatalogReaderError.catalogChanged }
    }
    #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == original)
}

@Test func storageDatalessPolicyPreservesIncomingAndNativeOperationErrno() throws {
    let original = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    errno = EBUSY
    let incoming = StorageDatalessPolicy.withMaterializationDisabled { _ in errno }
    #expect(incoming == EBUSY)
    #expect(errno == EBUSY)
    errno = 0
    let result = StorageDatalessPolicy.withMaterializationDisabled { _ in fcntl(-1, F_GETFD) }
    let failure = errno
    #expect(result == -1)
    #expect(failure == EBADF)
    #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == original)
    errno = 0
    #expect(throws: StorageCatalogReaderError.catalogChanged) {
        try StorageDatalessPolicy.withMaterializationDisabled { _ in
            errno = EDEADLK
            throw StorageCatalogReaderError.catalogChanged
        }
    }
    #expect(errno == EDEADLK)
    #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == original)
}

@Test func storageCatalogMetadataCacheBoundsParentsAndEntriesAndFallsBackForLargeParents() throws {
    let fixture = try MetadataCacheFixture()
    defer { fixture.cleanup() }
    let cache = StorageCatalogMetadataCache(maximumParents: 2, maximumEntries: 3, maximumParentEntries: 2)
    for directory in 0..<4 {
        let file = try fixture.file("d\(directory)/a")
        let parent = file.deletingLastPathComponent()
        let metadata = try cache.metadata(name: "a", parentURL: parent, parentIdentity: StorageFileMetadata.identity(at: parent))
        let expected = try StorageFileMetadata.identity(at: file)
        #expect(StorageFileMetadata.identity(metadata) == expected)
        #expect(metadata.st_mode & S_IFMT == S_IFREG)
        #expect(cache.cachedParentCount <= 2)
        #expect(cache.cachedEntryCount <= 3)
    }
    for index in 0..<4 { _ = try fixture.file("large/f\(index)") }
    let parent = fixture.root.appending(path: "large")
    for index in 0..<4 {
        let file = parent.appending(path: "f\(index)")
        let metadata = try cache.metadata(name: file.lastPathComponent, parentURL: parent, parentIdentity: StorageFileMetadata.identity(at: parent))
        let expected = try StorageFileMetadata.identity(at: file)
        #expect(StorageFileMetadata.identity(metadata) == expected)
        #expect(metadata.st_size == 1) // Overflow uses the original complete stat, not zero-sized bulk projection.
    }
    #expect(cache.cachedParentCount <= 2)
    #expect(cache.cachedEntryCount <= 3)
}

@Test func storageCatalogMetadataCacheDoesNotRequireReadableParentForLeafMetadata() throws {
    let fixture = try MetadataCacheFixture()
    defer { fixture.cleanup() }
    let file = try fixture.file("a")
    let cache = StorageCatalogMetadataCache(openDirectory: { _ in errno = EACCES; return -1 })
    let metadata = try cache.metadata(name: "a", parentURL: fixture.root, parentIdentity: StorageFileMetadata.identity(at: fixture.root))
    let expected = try StorageFileMetadata.identity(at: file)
    #expect(StorageFileMetadata.identity(metadata) == expected)
    #expect(metadata.st_size == 1)
}

@Test(arguments: [true, false])
func storageCatalogMetadataCacheDoesNotReenumerateCyclicOversizedOrEvictedParents(oversized: Bool) throws {
    let fixture = try MetadataCacheFixture()
    defer { fixture.cleanup() }
    var parents: [(URL, StorageFileIdentity)] = []
    for directory in 0..<80 {
        for file in 0..<3 { _ = try fixture.file("d\(directory)/f\(file)") }
        let url = fixture.root.appending(path: "d\(directory)")
        parents.append((url, try StorageFileMetadata.identity(at: url)))
    }
    var opens = 0
    let cache = StorageCatalogMetadataCache(maximumParentEntries: oversized ? 2 : 4, openDirectory: { path in
        opens += 1
        return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    })
    for _ in 0..<4 {
        for (url, identity) in parents {
            let metadata = try cache.metadata(name: "f0", parentURL: url, parentIdentity: identity)
            let expected = try StorageFileMetadata.identity(at: url.appending(path: "f0"))
            #expect(StorageFileMetadata.identity(metadata) == expected)
            #expect(metadata.st_mode & S_IFMT == S_IFREG)
        }
    }
    #expect(opens == 80)
    #expect(cache.cachedParentCount <= 64)
    #expect(cache.cachedEntryCount <= 32_768)
    #expect(cache.bypassedParentCount <= 2_000_000)
    if oversized { #expect(cache.cachedParentCount == 0) }
}

@Test func storageCatalogMetadataCacheStopsBulkPopulationWhenBoundedBypassHistoryFills() throws {
    let fixture = try MetadataCacheFixture()
    defer { fixture.cleanup() }
    var parents: [(URL, StorageFileIdentity)] = []
    for directory in 0..<20 {
        for file in 0..<3 { _ = try fixture.file("d\(directory)/f\(file)") }
        let url = fixture.root.appending(path: "d\(directory)")
        parents.append((url, try StorageFileMetadata.identity(at: url)))
    }
    var opens = 0
    let cache = StorageCatalogMetadataCache(maximumParentEntries: 2, maximumBypassedParents: 8, openDirectory: { path in
        opens += 1
        return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    })
    for _ in 0..<3 {
        for (url, identity) in parents {
            let metadata = try cache.metadata(name: "f0", parentURL: url, parentIdentity: identity)
            #expect(metadata.st_size == 1)
        }
    }
    #expect(cache.bypassedParentCount == 8)
    #expect(opens == 9)
    #expect(cache.cachedParentCount == 0)
}

private final class MetadataDescriptorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [CInt] = []
    func openParent(_ path: String, cancel: Bool = false) -> CInt {
        let original = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard original >= 0 else { return original }
        // Keep the witness descriptor away from other tests' normal low-numbered FDs.
        let descriptor = fcntl(original, F_DUPFD_CLOEXEC, 1_000)
        close(original)
        lock.withLock { descriptors.append(descriptor) }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return descriptor
    }
    var opened: [CInt] { lock.withLock { descriptors } }
}

@Test func storageCatalogMetadataCacheClosesParentDescriptorsAfterSuccessFailureAndCancellation() async throws {
    let fixture = try MetadataCacheFixture()
    defer { fixture.cleanup() }
    _ = try fixture.file("a")
    let identity = try StorageFileMetadata.identity(at: fixture.root)
    let supported = StorageDatalessPolicy.withMaterializationDisabled { $0 }
    guard supported else { return }
    let probe = MetadataDescriptorProbe()
    let cache = StorageCatalogMetadataCache(openDirectory: { probe.openParent($0) })
    _ = try cache.metadata(name: "a", parentURL: fixture.root, parentIdentity: identity)
    let wrong = StorageFileIdentity(device: identity.device, inode: identity.inode ^ 1,
        birthSeconds: identity.birthSeconds, birthNanoseconds: identity.birthNanoseconds)
    #expect(throws: StorageCatalogScanError.self) {
        try cache.metadata(name: "a", parentURL: fixture.root, parentIdentity: wrong)
    }
    let task = Task {
        let cache = StorageCatalogMetadataCache(openDirectory: { probe.openParent($0, cancel: true) })
        return try cache.metadata(name: "a", parentURL: fixture.root, parentIdentity: identity)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(probe.opened.count == 3)
    for descriptor in probe.opened { #expect(fcntl(descriptor, F_GETFD) == -1) }
}
