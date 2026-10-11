import Foundation
import MacUtilsCore
@testable import MacUtilsApp
import MacUtilsSystem
import Testing

private actor ModelStorageService: StorageManaging {
    struct ScanRequest: Sendable {
        let id: UUID
        let grant: StorageGrant
    }
    private struct PendingScan {
        let continuation: CheckedContinuation<StorageSnapshot, any Error>
        let progress: @Sendable (StorageScanProgress) async -> Void
    }
    private var storedGrants: [StorageGrant]
    private let availableFolders: [StorageGrant]
    private var cache: [UUID: StorageSnapshot]
    private var pendingScans: [UUID: PendingScan] = [:]
    private var scanEvents: [ScanRequest] = []
    private var scanWaiters: [CheckedContinuation<ScanRequest, Never>] = []
    private(set) var scannedRoots: [UUID] = []
    private(set) var trashedItems: [Int] = []
    private(set) var openedDirectories: [Int] = []
    private(set) var revealedItems: [Int] = []
    private var trashResult = StorageTrashResult(trashedNodeIDs: [], failures: [], invalidatedGrantIDs: [])
    private var suspendsTrash = false
    private var trashContinuation: CheckedContinuation<Void, Never>?
    private var trashWaiter: CheckedContinuation<Void, Never>?
    private var cacheFailure: String?
    private var statusFailure: String?
    private var clearFailure: String?
    private var grantsFailure: String?
    private var resetFailure: String?
    private var suspendsCacheReads = false
    private var cacheReadContinuation: CheckedContinuation<Void, Never>?
    private var cacheReadWaiter: CheckedContinuation<Void, Never>?
    private(set) var cacheReadCount = 0
    private(set) var releasedTrees: [UUID] = []

    init(grants: [StorageGrant], snapshots: [StorageSnapshot], availableFolders: [StorageGrant]? = nil) {
        storedGrants = grants
        self.availableFolders = availableFolders ?? grants
        cache = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.grantID, $0) })
    }
    func grants() async throws -> [StorageGrant] {
        if let grantsFailure { throw StorageServiceError.invalidData(grantsFailure) }
        return storedGrants
    }
    func selectFolder(_ url: URL) async throws -> StorageGrant {
        guard let grant = availableFolders.first(where: { $0.path == url.path }) else {
            throw StorageServiceError.access("Folder access denied")
        }
        if !storedGrants.contains(grant) { storedGrants.append(grant) }
        return grant
    }
    func cachedSnapshot(for grant: StorageGrant) async throws -> StorageSnapshot? {
        if let cacheFailure { throw StorageServiceError.invalidData(cacheFailure) }
        cacheReadCount += 1
        if suspendsCacheReads {
            await withCheckedContinuation { continuation in
                cacheReadContinuation = continuation
                cacheReadWaiter?.resume(); cacheReadWaiter = nil
            }
        }
        return cache[grant.id]
    }
    func holdCacheReads() { suspendsCacheReads = true }
    func isSnapshotSuperseded(_ snapshot: StorageSnapshot) async throws -> Bool {
        if let statusFailure { throw StorageServiceError.invalidData(statusFailure) }
        return false
    }
    func setStatusFailure(_ value: String?) { statusFailure = value }
    func waitForHeldCacheRead() async {
        if cacheReadContinuation != nil { return }
        await withCheckedContinuation { cacheReadWaiter = $0 }
    }
    func resumeCacheReads() {
        suspendsCacheReads = false
        cacheReadContinuation?.resume(); cacheReadContinuation = nil
    }
    func releaseTree(snapshotID: UUID) async { releasedTrees.append(snapshotID) }
    func scan(_ grant: StorageGrant,
              progress: @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot {
        let request = ScanRequest(id: UUID(), grant: grant)
        scannedRoots.append(grant.id)
        // Deliberately ignores cancellation until resumed, exercising the model's stale-result guard.
        return try await withCheckedThrowingContinuation { continuation in
            pendingScans[request.id] = PendingScan(continuation: continuation, progress: progress)
            if scanWaiters.isEmpty { scanEvents.append(request) }
            else { scanWaiters.removeFirst().resume(returning: request) }
        }
    }
    func nextScan() async -> ScanRequest {
        if !scanEvents.isEmpty { return scanEvents.removeFirst() }
        return await withCheckedContinuation { scanWaiters.append($0) }
    }
    func scanDirectory(nodeID: Int, in snapshot: StorageSnapshot,
                       progress: @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot {
        guard let item = snapshot.itemReference(id: nodeID) else { throw StorageServiceError.staleItem("Missing folder") }
        return try await scan(StorageGrant(id: snapshot.grantID,
            path: URL(fileURLWithPath: snapshot.rootPath).appending(path: item.relativePath).path,
            name: item.name), progress: progress)
    }
    func emitProgress(_ progress: StorageScanProgress, for request: ScanRequest) async {
        await pendingScans[request.id]?.progress(progress)
    }
    func finish(_ request: ScanRequest, snapshot: StorageSnapshot) {
        pendingScans.removeValue(forKey: request.id)?.continuation.resume(returning: snapshot)
    }
    func fail(_ request: ScanRequest, message: String) {
        pendingScans.removeValue(forKey: request.id)?.continuation.resume(throwing: StorageServiceError.access(message))
    }
    func clearCache() async throws {
        if let clearFailure { throw StorageServiceError.invalidData(clearFailure) }
        cache.removeAll()
    }
    func removeGrant(_ grant: StorageGrant) async throws { storedGrants.removeAll { $0.id == grant.id } }
    func resetSavedLocations() async throws {
        if let resetFailure { throw StorageServiceError.access(resetFailure) }
        storedGrants = []; cache = [:]; cacheFailure = nil; grantsFailure = nil
    }
    func reveal(nodeID: Int, in snapshot: StorageSnapshot) async throws { revealedItems.append(nodeID) }
    func openDirectory(nodeID: Int, in snapshot: StorageSnapshot) async throws { openedDirectories.append(nodeID) }
    func trash(nodeIDs: [Int], in snapshot: StorageSnapshot) async throws -> StorageTrashResult {
        trashedItems.append(contentsOf: nodeIDs)
        if suspendsTrash {
            await withCheckedContinuation { continuation in
                trashContinuation = continuation
                trashWaiter?.resume(); trashWaiter = nil
            }
        }
        return trashResult
    }
    func holdTrash() { suspendsTrash = true }
    func waitForHeldTrash() async {
        if trashContinuation != nil { return }
        await withCheckedContinuation { trashWaiter = $0 }
    }
    func resumeTrash() { suspendsTrash = false; trashContinuation?.resume(); trashContinuation = nil }
    func setTrashResult(_ value: StorageTrashResult) { trashResult = value }
    func setCacheFailure(_ value: String?) { cacheFailure = value }
    func setClearFailure(_ value: String?) { clearFailure = value }
    func setGrantsFailure(_ value: String?) { grantsFailure = value }
    func setResetFailure(_ value: String?) { resetFailure = value }
    func setStoredGrants(_ value: [StorageGrant]) { storedGrants = value }
}

private func storageModelSnapshot(_ grant: StorageGrant, bytes: UInt64 = 100) -> StorageSnapshot {
    let identity = StorageFileIdentity(device: 1, inode: 1, birthSeconds: 1, birthNanoseconds: 0)
    let nodes = [
        StorageNode(id: 0, parentID: nil, name: grant.name, relativePath: "", kind: .directory,
                    identity: identity, logicalBytes: bytes, allocatedBytes: bytes, apparentBytes: bytes, fileCount: 2),
        StorageNode(id: 1, parentID: 0, name: "one.bin", relativePath: "one.bin", kind: .file,
                    identity: identity, logicalBytes: bytes / 2, allocatedBytes: bytes / 2,
                    apparentBytes: bytes / 2, fileCount: 1),
        StorageNode(id: 2, parentID: 0, name: "two.bin", relativePath: "two.bin", kind: .file,
                    identity: identity, logicalBytes: bytes - bytes / 2, allocatedBytes: bytes - bytes / 2,
                    apparentBytes: bytes - bytes / 2, fileCount: 1),
    ]
    return StorageSnapshot(grantID: grant.id, rootPath: grant.path, rootIdentity: identity,
                           scannedAt: Date(timeIntervalSince1970: 100), nodes: nodes, issues: [])
}

/// Hold the current operation's completion even after the UI cancels or switches its task reference.
@MainActor
private func currentStorageWork(_ model: StorageModel) async -> Task<Void, Never> {
    let ready = AsyncStream<Void>.makeStream()
    let task = Task { @MainActor in
        ready.continuation.yield(())
        ready.continuation.finish()
        await model.waitForScan()
    }
    for await _ in ready.stream { break }
    return task
}

@Test @MainActor
func storageModelReopensDatedCacheWithoutStartingTraversal() async {
    let grant = StorageGrant(path: "/fixture/cache", name: "Cache")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    await model.waitForScan()
    #expect(model.snapshot?.id == cached.id)
    #expect(model.snapshot?.scannedAt == Date(timeIntervalSince1970: 100))
    #expect(model.isCached && !model.isScanning && !model.isLoading)
    #expect(model.visibleNodes.map(\.id) == [1, 2])
    #expect(await service.scannedRoots.isEmpty)
    model.stop()
}

@Test @MainActor
func storageModelCachedStatusLookupFailureKeepsReadOnlyBrowser() async {
    let grant = StorageGrant(path: "/fixture/stale-status", name: "Status lookup")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    await service.setStatusFailure("Saved generation marker is unreadable")
    let model = StorageModel(service: service, volumeProvider: { [] })
    await model.start()
    await model.waitForPresentation()
    model.selectItems([1], in: cached.id)
    #expect(model.snapshot?.id == cached.id && model.visibleNodes.count == 2)
    #expect(model.hasStaleTrashResults && !model.canTrash)
    #expect(model.error?.contains("Saved generation marker is unreadable") == true)
    model.requestTrashConfirmation()
    #expect(model.pendingTrash == nil)
    #expect(await service.scannedRoots.isEmpty)
    model.stop()
    await model.waitForPresentation()
}

@Test @MainActor
func storageModelConcurrentStartLoadsOnceAndStopRejectsLateCacheCompletion() async {
    let grant = StorageGrant(path: "/fixture/startup-race", name: "Startup")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    await service.holdCacheReads()
    let model = StorageModel(service: service, volumeProvider: { [] })
    let first = Task { @MainActor in await model.start() }
    await service.waitForHeldCacheRead()
    await model.start()
    #expect(await service.cacheReadCount == 1)
    model.stop()
    await service.resumeCacheReads()
    await first.value
    await model.waitForPresentation()
    #expect(model.snapshot == nil && !model.isLoading && !model.isScanning)
    #expect(await service.releasedTrees.contains(cached.id))
}

@Test @MainActor
func storageModelRejectsSelectionCallbacksFromOldRowsAndDisablesCleanupWhilePreparingRows() async {
    let first = StorageGrant(path: "/fixture/old-rows", name: "First")
    let second = StorageGrant(path: "/fixture/current-rows", name: "Second")
    let old = storageModelSnapshot(first)
    let current = storageModelSnapshot(second)
    let service = ModelStorageService(grants: [first, second], snapshots: [old, current])
    let model = StorageModel(service: service, volumeProvider: { [] })
    await model.start()
    await model.waitForScan()
    model.selectGrant(second.id)
    await model.waitForScan()
    model.selectItems([1], in: old.id)
    #expect(model.selection.isEmpty)
    model.selectItems([1], in: current.id)
    #expect(model.selection == [1] && model.canTrash)
    model.metric = .logical
    model.selectItems([2], in: current.id)
    #expect(model.selection == [1] && !model.canTrash)
    await model.waitForScan()
    #expect(model.selection == [1] && model.canTrash)
    model.stop()
}

@Test @MainActor
func storageModelConfirmationCapturesExactPathsAndCancelsWithoutMovingFiles() async {
    let grant = StorageGrant(path: "/fixture/confirm-paths", name: "Confirmation")
    let snapshot = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [snapshot])
    let model = StorageModel(service: service, volumeProvider: { [] })
    await model.start()
    await model.waitForScan()
    model.selectItems([1], in: snapshot.id)
    model.requestTrashConfirmation()
    model.selection = [2]
    #expect(model.pendingTrash?.snapshotID == snapshot.id)
    #expect(model.pendingTrash?.nodeIDs == [1])
    #expect(model.pendingTrash?.paths == [grant.path + "/one.bin"])
    model.cancelTrashConfirmation()
    #expect(model.pendingTrash == nil)
    #expect(await service.trashedItems.isEmpty)
    model.stop()
}

@Test @MainActor
func storageModelOpensCurrentFolderContentsInsteadOfRevealingTheSelectedFile() async {
    let grant = StorageGrant(path: "/fixture/finder", name: "Finder")
    let snapshot = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [snapshot])
    let model = StorageModel(service: service, volumeProvider: { [] })
    await model.start()
    await model.waitForScan()
    model.selectItems([1], in: snapshot.id)
    await model.openCurrentFolderInFinder(in: UUID())
    #expect(await service.openedDirectories.isEmpty)
    await model.openCurrentFolderInFinder(in: snapshot.id)
    #expect(await service.openedDirectories == [0])
    #expect(await service.revealedItems.isEmpty)
    await model.revealSelection()
    #expect(await service.revealedItems == [1])
    model.stop()
}

@Test @MainActor
func storageModelPackageRootCanBeRevealedButCannotBeOpenedOrMovedToTrash() async {
    let grant = StorageGrant(path: "/fixture/Example.app", name: "Example.app")
    let identity = StorageFileIdentity(device: 1, inode: 1, birthSeconds: 1, birthNanoseconds: 0)
    let snapshot = StorageSnapshot(grantID: grant.id, rootPath: grant.path, rootIdentity: identity,
        nodes: [StorageNode(id: 0, parentID: nil, name: grant.name, relativePath: "", kind: .package,
            identity: identity, logicalBytes: 100, allocatedBytes: 100, apparentBytes: 100, fileCount: 2)], issues: [])
    let service = ModelStorageService(grants: [grant], snapshots: [snapshot])
    let model = StorageModel(service: service, volumeProvider: { [] })
    await model.start()
    await model.waitForScan()
    model.selectItems([0], in: snapshot.id)
    #expect(model.selection == [0] && !model.canTrash && !model.canOpenCurrentFolderInFinder)
    model.requestTrashConfirmation()
    #expect(model.pendingTrash == nil)
    await model.openCurrentFolderInFinder(in: snapshot.id)
    #expect(await service.openedDirectories.isEmpty)
    #expect(await service.trashedItems.isEmpty)
    await model.revealSelection()
    #expect(await service.revealedItems == [0])
    model.stop()
}

@Test @MainActor
func storageModelCancellationKeepsCachedResultAndRejectsLateCompletionAndProgress() async {
    let grant = StorageGrant(path: "/fixture/cancel", name: "Cancel")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    model.refresh()
    let request = await service.nextScan()
    #expect(model.scanStartedAt != nil)
    let completion = await currentStorageWork(model)
    model.cancelScan()
    await service.emitProgress(StorageScanProgress(visitedItems: 500, currentPath: "late",
        logicalBytes: 900, allocatedBytes: 900), for: request)
    await service.finish(request, snapshot: storageModelSnapshot(grant, bytes: 900))
    await completion.value
    #expect(model.snapshot?.id == cached.id)
    #expect(model.isCached && !model.isScanning)
    #expect(model.progress == nil && model.notice != nil && model.error == nil)
    #expect(model.scanStartedAt == nil)
    model.stop()
}

@Test @MainActor
func storageModelSwitchingRootRejectsOldScanAndItsProgress() async {
    let first = StorageGrant(path: "/fixture/first", name: "First")
    let second = StorageGrant(path: "/fixture/second", name: "Second")
    let firstSnapshot = storageModelSnapshot(first)
    let secondSnapshot = storageModelSnapshot(second, bytes: 200)
    let service = ModelStorageService(grants: [first, second], snapshots: [firstSnapshot, secondSnapshot])
    let model = StorageModel(service: service)
    await model.start()
    model.refresh()
    let old = await service.nextScan()
    let completion = await currentStorageWork(model)
    model.selectGrant(second.id)
    await model.waitForScan()
    model.refresh()
    let current = await service.nextScan()
    let progress = StorageScanProgress(visitedItems: 7, currentPath: "second", logicalBytes: 300, allocatedBytes: 300)
    await service.emitProgress(progress, for: current)
    await service.emitProgress(StorageScanProgress(visitedItems: 99, currentPath: "first",
        logicalBytes: 999, allocatedBytes: 999), for: old)
    #expect(model.progress == progress)
    await service.finish(old, snapshot: storageModelSnapshot(first, bytes: 999))
    await completion.value
    #expect(model.selectedGrantID == second.id && model.snapshot?.id == secondSnapshot.id)
    #expect(model.isScanning)
    let refreshed = storageModelSnapshot(second, bytes: 300)
    await service.finish(current, snapshot: refreshed)
    await model.waitForScan()
    #expect(model.snapshot?.id == refreshed.id && !model.isCached && !model.isScanning)
    model.stop()
}

@Test @MainActor
func storageModelFailedRefreshPreservesUsableSnapshotAndShowsFailure() async {
    let grant = StorageGrant(path: "/fixture/error", name: "Error")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    model.refresh()
    let request = await service.nextScan()
    await service.fail(request, message: "Folder access expired")
    await model.waitForScan()
    #expect(model.snapshot?.id == cached.id && model.isCached && !model.isScanning)
    #expect(model.error?.contains("Folder access expired") == true)
    model.stop()
}

@Test @MainActor
func storageModelTrashCacheFailureKeepsBrowserAndFailedSelection() async {
    let grant = StorageGrant(path: "/fixture/trash", name: "Trash")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    await model.waitForScan()
    model.selection = [1, 2]
    #expect(model.canTrash)
    await service.setTrashResult(StorageTrashResult(trashedNodeIDs: [1],
        failures: [StorageTrashFailure(nodeID: 2, message: "Item changed")], invalidatedGrantIDs: [grant.id],
        cacheInvalidationError: "Cache could not be invalidated"))
    await model.trashConfirmed(snapshotID: cached.id, nodeIDs: [1, 2])
    await model.waitForPresentation()
    #expect(model.snapshot?.id == cached.id && model.selection == [2])
    #expect(model.mapNodes.map(\.id) == [2] && model.visibleNodes.map(\.id) == [2])
    #expect(model.hasStaleTrashResults && !model.canTrash && model.notice != nil)
    #expect(model.error?.contains("two.bin: Item changed") == true)
    #expect(model.error?.contains("Cache could not be invalidated") == true)
    model.stop()
}

@Test @MainActor
func storageModelAllFailedTrashKeepsResultsAndStaleConfirmationHasNoEffect() async {
    let grant = StorageGrant(path: "/fixture/confirmation", name: "Confirm")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    model.selection = [1]
    await model.trashConfirmed(snapshotID: UUID(), nodeIDs: [1])
    #expect(await service.trashedItems.isEmpty)
    #expect(model.snapshot?.id == cached.id && model.selection == [1])
    await service.setTrashResult(StorageTrashResult(trashedNodeIDs: [],
        failures: [StorageTrashFailure(nodeID: 1, message: "Permission denied")], invalidatedGrantIDs: []))
    await model.trashConfirmed(snapshotID: cached.id, nodeIDs: [1])
    #expect(model.snapshot?.id == cached.id && model.isCached && model.selection == [1])
    #expect(model.error?.contains("one.bin: Permission denied") == true)
    model.stop()
}

@Test @MainActor
func storageModelSuccessfulTrashWithoutUpdatedIndexKeepsRemainingObjectsVisible() async {
    let grant = StorageGrant(path: "/fixture/success", name: "Success")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    await model.waitForScan()
    model.selection = [1]
    await service.setTrashResult(StorageTrashResult(trashedNodeIDs: [1], failures: [], invalidatedGrantIDs: [grant.id]))
    await model.trashConfirmed(snapshotID: cached.id, nodeIDs: [1])
    await model.waitForPresentation()
    #expect(model.snapshot?.id == cached.id && model.selection.isEmpty && !model.isMutating)
    #expect(model.visibleNodes.map(\.id) == [2] && model.mapNodes.map(\.id) == [2])
    #expect(model.hasStaleTrashResults && !model.canTrash)
    #expect(model.notice == model.text.format("storage.trashed", 1))
    #expect(model.grants == [grant])
    model.stop()
}

@Test @MainActor
func storageModelStopRejectsLateTrashRevisionAndReleasesItsReader() async {
    let grant = StorageGrant(path: "/fixture/late-trash", name: "Late Trash")
    let original = storageModelSnapshot(grant)
    let revised = storageModelSnapshot(grant, bytes: 50)
    let service = ModelStorageService(grants: [grant], snapshots: [original])
    await service.setTrashResult(StorageTrashResult(trashedNodeIDs: [1], failures: [],
        invalidatedGrantIDs: [grant.id], updatedSnapshot: revised))
    await service.holdTrash()
    let model = StorageModel(service: service, volumeProvider: { [] })
    await model.start()
    await model.waitForPresentation()
    let work = Task { @MainActor in await model.trashConfirmed(snapshotID: original.id, nodeIDs: [1]) }
    await service.waitForHeldTrash()
    model.stop()
    await service.resumeTrash()
    await work.value
    await model.waitForPresentation()
    #expect(model.snapshot == nil && model.selection.isEmpty && !model.isMutating)
    #expect(await service.releasedTrees.contains(revised.id))
    #expect(await service.scannedRoots.isEmpty)
}

@Test @MainActor
func storageModelTrashCacheFailureHidesUnloadedDescendantsInLargestView() async {
    let grant = StorageGrant(path: "/fixture/fallback-subtree", name: "Fallback subtree")
    let identity = StorageFileIdentity(device: 1, inode: 1, birthSeconds: 1, birthNanoseconds: 0)
    let snapshot = StorageSnapshot(grantID: grant.id, rootPath: grant.path, rootIdentity: identity,
        nodes: [
            StorageNode(id: 0, parentID: nil, name: grant.name, relativePath: "", kind: .directory,
                identity: identity, logicalBytes: 30, allocatedBytes: 30, apparentBytes: 30, fileCount: 2),
            StorageNode(id: 1, parentID: 0, name: "Moved", relativePath: "Moved", kind: .directory,
                identity: identity, logicalBytes: 20, allocatedBytes: 20, apparentBytes: 20, fileCount: 1),
            StorageNode(id: 2, parentID: 1, name: "hidden.bin", relativePath: "Moved/hidden.bin", kind: .file,
                identity: identity, logicalBytes: 20, allocatedBytes: 20, apparentBytes: 20, fileCount: 1),
            StorageNode(id: 3, parentID: 0, name: "kept.bin", relativePath: "kept.bin", kind: .file,
                identity: identity, logicalBytes: 10, allocatedBytes: 10, apparentBytes: 10, fileCount: 1)
        ], issues: [])
    let service = ModelStorageService(grants: [grant], snapshots: [snapshot])
    await service.setTrashResult(StorageTrashResult(trashedNodeIDs: [1], failures: [],
        invalidatedGrantIDs: [grant.id], cacheInvalidationError: "Index update failed"))
    let model = StorageModel(service: service, volumeProvider: { [] })
    await model.start()
    await model.waitForPresentation()
    #expect(model.row(id: 2) == nil)
    await model.trashConfirmed(snapshotID: snapshot.id, nodeIDs: [1])
    model.browserMode = .largestFiles
    await model.waitForPresentation()
    #expect(model.visibleNodes.map(\.id) == [3] && model.mapNodes.map(\.id) == [3])
    #expect(model.snapshot?.id == snapshot.id && model.hasStaleTrashResults)
    #expect(await service.scannedRoots.isEmpty)
    model.stop()
    await model.waitForPresentation()
}

@Test @MainActor
func storageModelClearCachePreservesGrantsAndFailedClearPreservesResults() async throws {
    let grant = StorageGrant(path: "/fixture/clear", name: "Clear")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    await service.setClearFailure("Cache is not writable")
    await model.clearCache()
    #expect(model.snapshot?.id == cached.id && model.isCached)
    #expect(model.error?.contains("Cache is not writable") == true)
    await service.setClearFailure(nil)
    await model.clearCache()
    #expect(model.snapshot == nil && !model.isCached && model.error == nil)
    #expect(model.selectedGrantID == grant.id && model.grants == [grant])
    #expect(try await service.grants() == [grant])
    model.stop()
}

@Test @MainActor
func storageModelCacheReadFailureIsVisibleWithoutUnrequestedScan() async {
    let grant = StorageGrant(path: "/fixture/badcache", name: "Bad cache")
    let service = ModelStorageService(grants: [grant], snapshots: [])
    await service.setCacheFailure("Cache schema is unsupported")
    let model = StorageModel(service: service)
    await model.start()
    #expect(model.snapshot == nil && !model.isLoading && !model.isScanning)
    #expect(model.error?.contains("Cache schema is unsupported") == true)
    #expect(await service.scannedRoots.isEmpty)
    model.stop()
}

@Test @MainActor
func storageModelReselectingACorruptCachedLocationDoesNotSilentlyStartAnalysis() async {
    let grant = StorageGrant(path: "/fixture/missing-index", name: "Missing index")
    let service = ModelStorageService(grants: [grant], snapshots: [])
    await service.setCacheFailure("Saved tree index is missing")
    let model = StorageModel(service: service, volumeProvider: { [] })
    await model.start()
    await model.selectFolder(URL(fileURLWithPath: grant.path))
    #expect(model.snapshot == nil && !model.isScanning && !model.isLoading)
    #expect(model.error?.contains("Saved tree index is missing") == true)
    #expect(await service.scannedRoots.isEmpty)
    // Keep a regressed provider continuation recoverable after reporting the failed assertions.
    if model.isScanning {
        let request = await service.nextScan()
        await service.fail(request, message: "Unexpected automatic scan")
        await model.waitForScan()
    }
    model.stop()
}

@Test(arguments: [true, false]) @MainActor
func storageModelStartupMetadataFailureRemainsVisibleUntilExplicitReset(failedGrants: Bool) async {
    let grant = StorageGrant(path: "/fixture/reset-startup", name: "Reset startup")
    let service = ModelStorageService(grants: [grant], snapshots: [])
    if failedGrants { await service.setGrantsFailure("Saved folders are damaged") }
    else { await service.setCacheFailure("Saved scan cache is damaged") }
    let model = StorageModel(service: service)
    await model.start()
    let expectedError = failedGrants ? "Saved folders are damaged" : "Saved scan cache is damaged"
    #expect(model.error?.contains(expectedError) == true)
    await model.start()
    #expect(model.error?.contains(expectedError) == true)
    #expect(await service.scannedRoots.isEmpty)
    await model.resetSavedLocations()
    #expect(model.error == nil && model.notice != nil && model.grants.isEmpty)
    #expect(model.selectedGrantID == nil && model.snapshot == nil && !model.isMutating)
    await model.selectFolder(URL(fileURLWithPath: grant.path))
    let request = await service.nextScan()
    let result = storageModelSnapshot(grant)
    await service.finish(request, snapshot: result)
    await model.waitForScan()
    #expect(model.selectedGrantID == grant.id && model.snapshot?.id == result.id && model.error == nil)
    model.stop()
}

@Test @MainActor
func storageModelExplicitResetClearsSavedMetadataAndAllowsFolderReselection() async throws {
    let grant = StorageGrant(path: "/fixture/reset-usable", name: "Reset usable")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    await model.waitForScan()
    model.selection = [1]
    await service.setClearFailure("Cache clear failed")
    await model.clearCache()
    #expect(model.error != nil && model.snapshot?.id == cached.id)
    await model.resetSavedLocations()
    #expect(model.grants.isEmpty && model.selectedGrantID == nil && model.snapshot == nil && model.selection.isEmpty)
    #expect(model.mapNodes.isEmpty && model.visibleNodes.isEmpty && !model.isCached && !model.isMutating)
    #expect(model.error == nil && model.notice == model.text("storage.locationsReset"))
    #expect(try await service.grants().isEmpty)
    #expect(try await service.cachedSnapshot(for: grant) == nil)
    await model.selectFolder(URL(fileURLWithPath: grant.path))
    let request = await service.nextScan()
    let current = storageModelSnapshot(grant, bytes: 400)
    await service.finish(request, snapshot: current)
    await model.waitForScan()
    #expect(model.grants == [grant] && model.snapshot?.id == current.id && !model.isCached)
    #expect(model.selectedGrantID == grant.id && model.error == nil)
    model.stop()
}

@Test @MainActor
func storageModelFailedResetRetainsUsableSelectionAndReportsFailure() async throws {
    let grant = StorageGrant(path: "/fixture/reset-failure", name: "Reset failure")
    let cached = storageModelSnapshot(grant)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    await model.waitForScan()
    model.selection = [2]
    await service.setResetFailure("Saved locations are not writable")
    await model.resetSavedLocations()
    #expect(model.snapshot?.id == cached.id && model.isCached && model.selection == [2])
    #expect(model.selectedGrantID == grant.id && model.grants == [grant] && model.canTrash)
    #expect(model.visibleNodes.map(\.id) == [1, 2] && model.mapNodes.map(\.id) == [1, 2])
    #expect(!model.isMutating && model.error?.contains("Saved locations are not writable") == true)
    #expect(try await service.grants() == [grant])
    #expect(try await service.cachedSnapshot(for: grant)?.id == cached.id)
    model.stop()
}

@Test @MainActor
func storageModelRefreshPublishesRelocatedFolderMetadataWithoutChangingSelectionIdentity() async {
    let original = StorageGrant(path: "/fixture/original", name: "Original")
    let relocated = StorageGrant(id: original.id, path: "/fixture/relocated", name: "Renamed folder")
    let cached = storageModelSnapshot(original)
    let fresh = storageModelSnapshot(relocated, bytes: 300)
    let service = ModelStorageService(grants: [original], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    model.refresh()
    let request = await service.nextScan()
    await service.setStoredGrants([relocated])
    await service.finish(request, snapshot: fresh)
    await model.waitForScan()
    #expect(model.selectedGrantID == original.id)
    #expect(model.selectedGrant?.path == relocated.path && model.selectedGrant?.name == relocated.name)
    #expect(model.grants == [relocated] && model.snapshot?.id == fresh.id)
    #expect(model.snapshot?.rootPath == relocated.path && model.breadcrumbs.first?.name == relocated.name)
    #expect(!model.isCached && !model.isScanning && model.error == nil)
    model.stop()
}

@Test @MainActor
func storageModelRosterReadFailureAfterScanRetainsFreshResultsAndReportsIndependentError() async {
    let grant = StorageGrant(path: "/fixture/roster-failure", name: "Roster failure")
    let cached = storageModelSnapshot(grant)
    let fresh = storageModelSnapshot(grant, bytes: 600)
    let service = ModelStorageService(grants: [grant], snapshots: [cached])
    let model = StorageModel(service: service)
    await model.start()
    model.refresh()
    let request = await service.nextScan()
    await service.setGrantsFailure("Cannot read updated saved folders")
    await service.finish(request, snapshot: fresh)
    await model.waitForScan()
    #expect(model.snapshot?.id == fresh.id && model.snapshot?.root?.allocatedBytes == 600)
    #expect(model.selectedGrantID == grant.id && model.grants == [grant])
    #expect(!model.isCached && !model.isScanning && model.visibleNodes.count == 2)
    #expect(model.error?.contains("Cannot read updated saved folders") == true)
    model.stop()
}

@Test @MainActor
func storageModelDiskChoiceScansExactMountedVolumeAndUsesItsName() async {
    let grant = StorageGrant(path: "/Volumes/Fixture disk", name: "Fixture disk")
    let volume = StorageVolume(url: URL(fileURLWithPath: grant.path), name: "Named disk", totalBytes: 1_000, availableBytes: 500)
    let service = ModelStorageService(grants: [], snapshots: [], availableFolders: [grant])
    let model = StorageModel(service: service, volumeProvider: { [volume] })
    await model.start()
    model.chooseDisk(volume)
    let request = await service.nextScan()
    #expect(request.grant.path == volume.url.path)
    await service.finish(request, snapshot: storageModelSnapshot(grant))
    await model.waitForScan()
    #expect(model.selectedGrantID == grant.id && model.currentName == "Named disk")
    #expect(model.locationName(grant) == "Named disk")
    model.stop()
}

@Test @MainActor
func storageModelLegacyCondensedOverviewRequiresExplicitRefreshAndNeverDrillsByScanning() async {
    let grant = StorageGrant(path: "/fixture/overview", name: "Overview")
    let identity = StorageFileIdentity(device: 1, inode: 1, birthSeconds: 1, birthNanoseconds: 0)
    let totals = StorageTotals(logicalBytes: 100, allocatedBytes: 100, apparentBytes: 100, fileCount: 2)
    let overview = StorageSnapshot(grantID: grant.id, rootPath: grant.path, rootIdentity: identity,
        nodes: [StorageNode(id: 0, parentID: nil, name: grant.name, relativePath: "", kind: .directory,
            identity: identity, logicalBytes: 100, allocatedBytes: 100, apparentBytes: 100, fileCount: 2),
            StorageNode(id: 1, parentID: 0, name: "Projects", relativePath: "Projects", kind: .directory,
                identity: identity, logicalBytes: 100, allocatedBytes: 100, apparentBytes: 100, fileCount: 2,
                unlistedChildren: totals, unlistedChildCount: 2)], issues: [], schemaVersion: 2)
    let service = ModelStorageService(grants: [grant], snapshots: [overview])
    let model = StorageModel(service: service, volumeProvider: { [] })
    await model.start()
    await model.waitForScan()
    #expect(model.treeUnavailable)
    model.openFolder(1)
    #expect(await model.expand(relativePath: "Projects") == nil)
    #expect(model.snapshot?.id == overview.id && model.isCached && !model.isScanning)
    #expect(await service.scannedRoots.isEmpty)
    model.stop()
}
