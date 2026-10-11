import Foundation
import Combine
import MacUtilsCore
@testable import MacUtilsSystem
@testable import MacUtilsApp
import Testing

/// Keeps the real saved index while preventing native Finder/Trash effects in model tests.
private actor TreeModelService: StorageManaging {
    let base: StorageService
    private(set) var scans = 0
    private(set) var directoryScans = 0
    private(set) var released: [UUID] = []
    private(set) var revealed: [StorageItemReference] = []
    private var heldParent: Int?
    private var heldChildren: CheckedContinuation<Void, Never>?
    private var heldChildrenWaiter: CheckedContinuation<Void, Never>?
    private var failingPageParent: Int?
    private var remainingPageFailures = 0
    private(set) var failedPageAttempts = 0

    init(base: StorageService) { self.base = base }
    func grants() async throws -> [StorageGrant] { try await base.grants() }
    func selectFolder(_ url: URL) async throws -> StorageGrant { try await base.selectFolder(url) }
    func cachedSnapshot(for grant: StorageGrant) async throws -> StorageSnapshot? { try await base.cachedSnapshot(for: grant) }
    func isSnapshotSuperseded(_ snapshot: StorageSnapshot) async throws -> Bool {
        try await base.isSnapshotSuperseded(snapshot)
    }
    func scan(_ grant: StorageGrant, progress: @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot {
        scans += 1
        return try await base.scan(grant, progress: progress)
    }
    func scanDirectory(nodeID: Int, in snapshot: StorageSnapshot,
                       progress: @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot {
        directoryScans += 1
        throw StorageServiceError.access("Tree browsing must not scan directories")
    }
    func treeChildren(parentID: Int, in snapshot: StorageSnapshot, metric: StorageSizeMetric,
                      descending: Bool, offset: Int, limit: Int) async throws -> StorageTreePage {
        if failingPageParent == parentID, offset > 0 {
            failedPageAttempts += 1
            if remainingPageFailures > 0 {
                remainingPageFailures -= 1
                throw StorageServiceError.access("Saved page temporarily unavailable")
            }
        }
        if heldParent == parentID {
            heldParent = nil
            // Ignore cancellation deliberately so the model also faces a late old response.
            await withCheckedContinuation { continuation in
                heldChildren = continuation
                heldChildrenWaiter?.resume(); heldChildrenWaiter = nil
            }
        }
        return try await base.treeChildren(parentID: parentID, in: snapshot, metric: metric,
            descending: descending, offset: offset, limit: limit)
    }
    func holdNextChildren(of parentID: Int) { heldParent = parentID }
    func failAppendedPages(of parentID: Int) {
        failingPageParent = parentID; remainingPageFailures = 2; failedPageAttempts = 0
    }
    func clearPageFailures() { failingPageParent = nil; remainingPageFailures = 0 }
    func waitForHeldChildren() async {
        if heldChildren != nil { return }
        await withCheckedContinuation { heldChildrenWaiter = $0 }
    }
    func releaseHeldChildren() { heldChildren?.resume(); heldChildren = nil }
    func treeItem(id: Int, in snapshot: StorageSnapshot) async throws -> StorageItemReference? {
        try await base.treeItem(id: id, in: snapshot)
    }
    func releaseTree(snapshotID: UUID) async {
        released.append(snapshotID)
        await base.releaseTree(snapshotID: snapshotID)
    }
    func clearCache() async throws { try await base.clearCache() }
    func resetSavedLocations() async throws { try await base.resetSavedLocations() }
    func removeGrant(_ grant: StorageGrant) async throws { try await base.removeGrant(grant) }
    func reveal(nodeID: Int, in snapshot: StorageSnapshot) async throws {
        if let item = try await base.treeItem(id: nodeID, in: snapshot) { try await reveal(item: item, in: snapshot) }
    }
    func reveal(item: StorageItemReference, in snapshot: StorageSnapshot) async throws {
        guard try await base.treeItem(id: item.id, in: snapshot) == item else {
            throw StorageServiceError.invalidData("A compact summary is not a canonical tree reference")
        }
        revealed.append(item)
    }
    func trash(nodeIDs: [Int], in snapshot: StorageSnapshot) async throws -> StorageTrashResult {
        try await base.trash(nodeIDs: nodeIDs, in: snapshot)
    }
    func trash(items: [StorageItemReference], in snapshot: StorageSnapshot) async throws -> StorageTrashResult {
        try await base.trash(items: items, in: snapshot)
    }
}

/// Trash effects are confined to this test's own directory, never the macOS Trash.
private struct TreeFixtureAccess: StorageResourceAccess {
    let root: URL
    let bin: URL
    func bookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        (URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), false)
    }
    func start(_ url: URL) throws -> Bool { true }
    func stop(_ url: URL) {}
    func reveal(_ url: URL) async throws {}
    func openDirectory(_ url: URL) async throws {}
    func trash(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw StorageServiceError.unsafeItem("Only this disposable fixture may be moved")
        }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: bin.appending(path: UUID().uuidString))
    }
}

private struct TreeModelFixture {
    let directory: URL
    let root: URL
    let service: TreeModelService

    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        directory = repository.appending(path: "agent_temp_files_local/storage-tree-model-\(UUID())")
        root = directory.appending(path: "Sample")
        let sources = root.appending(path: "Workspace/Code/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        for index in 0..<600 {
            try Data(repeating: 1, count: index + 1).write(to: sources.appending(path: String(format: "item-%03d.bin", index)))
        }
        let contents = root.appending(path: "Example.app/Contents/Resources")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 32).write(to: contents.appending(path: "data.bin"))
        service = Self.makeService(directory: directory, root: root)
    }
    func cleanup() throws { try FileManager.default.removeItem(at: directory) }
    func restartedService() -> TreeModelService {
        Self.makeService(directory: directory, root: root)
    }
    private static func makeService(directory: URL, root: URL) -> TreeModelService {
        let treeDirectory = directory.appending(path: "cache/storage-trees")
        return TreeModelService(base: StorageService(grantsURL: directory.appending(path: "support/grants.json"),
            cacheURL: directory.appending(path: "cache/snapshots.json"),
            resourceAccess: TreeFixtureAccess(root: root, bin: directory.appending(path: "fixture-trash")),
            treeScansEnabled: true, scanOperation: { root, grantID, progress in
                try await StorageScanner(treeDirectory: treeDirectory)
                    .scan(rootURL: root, grantID: grantID, progress: progress)
            }))
    }
}

@Test @MainActor
func storageTreeBrowsingPagesEverySiblingAndPreservesExpansionSelectionAcrossSortWithoutScanning() async throws {
    let fixture = try TreeModelFixture()
    defer { try? fixture.cleanup() }
    let model = StorageModel(service: fixture.service, volumeProvider: { [] })
    await model.start()
    await model.selectFolder(fixture.root)
    await model.waitForScan()
    let snapshot = try #require(model.snapshot)
    #expect(snapshot.schemaVersion == 3)
    let parent = try #require(await model.expand(relativePath: "Workspace/Code/Sources"))
    #expect(model.children(of: parent).count == 200 && model.hasMoreChildren(of: parent))
    while model.hasMoreChildren(of: parent) {
        model.loadMoreChildren(of: parent, in: snapshot.id)
        await model.waitForPresentation()
    }
    #expect(model.children(of: parent).count == 600)
    let selected = try #require(model.children(of: parent).first { $0.name == "item-299.bin" })
    #expect(snapshot.itemReference(id: selected.id) == nil)
    model.selectItems([selected.id], in: snapshot.id)
    await model.waitForPresentation()
    #expect(model.canTrash && model.selectedNodes.first?.relativePath == "Workspace/Code/Sources/item-299.bin")
    let expanded = model.expandedIDs
    model.metric = .logical
    await model.waitForPresentation()
    #expect(model.children(of: parent).first?.name == "item-599.bin")
    #expect(model.children(of: parent).count == 600)
    #expect(model.selection == [selected.id] && model.expandedIDs == expanded)
    model.sortDescending = false
    await model.waitForPresentation()
    #expect(model.children(of: parent).first?.name == "item-000.bin")
    #expect(model.children(of: parent).count == 600)
    #expect(model.selection == [selected.id] && model.expandedIDs == expanded)
    await model.focus(relativePath: "Workspace/Code")
    #expect(model.snapshot?.id == snapshot.id && model.currentName == "Code")
    #expect(model.showsMap)
    #expect(await fixture.service.scans == 1)
    #expect(await fixture.service.directoryScans == 0)
    model.stop()
    await model.waitForPresentation()
    #expect(await fixture.service.released.contains(snapshot.id))
}

@Test @MainActor
func storageTreeCanonicalRootRevealAndPackageNavigationKeepCleanupBoundaries() async throws {
    let fixture = try TreeModelFixture()
    defer { try? fixture.cleanup() }
    let model = StorageModel(service: fixture.service, volumeProvider: { [] })
    await model.start()
    await model.selectFolder(fixture.root)
    await model.waitForScan()
    let snapshot = try #require(model.snapshot)
    model.selectItems([0], in: snapshot.id)
    await model.waitForPresentation()
    await model.revealSelection()
    #expect(model.error == nil)
    #expect(await fixture.service.revealed.first?.id == 0)
    await model.select(relativePath: "Example.app/Contents/Resources/data.bin")
    #expect(model.selectedNodes.first?.isInsidePackage == true && !model.canTrash)
    model.requestTrashConfirmation()
    #expect(model.pendingTrash == nil)
    await model.select(relativePath: "Example.app")
    #expect(model.selectedNodes.first?.kind == .package && model.canTrash)
    await model.focus(relativePath: "Example.app/Contents")
    #expect(model.currentName == "Contents")
    #expect(await fixture.service.scans == 1)
    #expect(await fixture.service.directoryScans == 0)
    model.stop()
    await model.waitForPresentation()
    await model.start()
    await model.waitForPresentation()
    #expect(model.snapshot?.id == snapshot.id && model.isCached)
    #expect(await fixture.service.scans == 1)
    model.stop()
    await model.waitForPresentation()
}

@Test @MainActor
func storageTreeFocusRetiresInFlightChildQueriesWithoutBlockingLaterExpansion() async throws {
    let fixture = try TreeModelFixture()
    defer { try? fixture.cleanup() }
    let model = StorageModel(service: fixture.service, volumeProvider: { [] })
    await model.start()
    await model.selectFolder(fixture.root)
    await model.waitForScan()
    let snapshot = try #require(model.snapshot)
    let workspace = try #require(await model.expand(relativePath: "Workspace"))
    let code = try #require(model.children(of: workspace).first { $0.name == "Code" })
    await fixture.service.holdNextChildren(of: code.id)
    model.expandFolder(code.id, in: snapshot.id)
    await fixture.service.waitForHeldChildren()
    #expect(model.loadingChildren.contains(code.id))
    model.openFolder(0, in: snapshot.id)
    await fixture.service.releaseHeldChildren()
    // Observe the actual new presentation completing, rather than waiting on a broken query
    // registry forever when this regression returns.
    for await preparing in model.$isPreparingPresentation.values {
        if !preparing { break }
    }
    #expect(!model.loadingChildren.contains(code.id))
    #expect(model.children(of: code.id).first?.name == "Sources")
    if !model.loadingChildren.contains(code.id), !model.children(of: code.id).isEmpty {
        model.collapseFolder(code.id, in: snapshot.id)
        model.expandFolder(code.id, in: snapshot.id)
        await model.waitForPresentation()
        #expect(model.expandedIDs.contains(code.id))
    }
    #expect(await fixture.service.scans == 1)
    #expect(await fixture.service.directoryScans == 0)
    model.stop()
    await model.waitForPresentation()
}

@Test @MainActor
func storageTreeTrashPreservesContextPagesAndRestartWithoutRescanning() async throws {
    let fixture = try TreeModelFixture()
    defer { try? fixture.cleanup() }
    let model = StorageModel(service: fixture.service, volumeProvider: { [] })
    await model.start()
    await model.selectFolder(fixture.root)
    await model.waitForScan()
    let original = try #require(model.snapshot)
    await model.focus(relativePath: "Workspace/Code/Sources")
    let folder = model.folderID
    while model.hasMoreChildren(of: folder) {
        model.loadMoreChildren(of: folder, in: original.id)
        await model.waitForPresentation()
    }
    model.metric = .logical
    model.sortDescending = false
    await model.waitForPresentation()
    let moved = try #require(model.children(of: folder).first { $0.name == "item-299.bin" })
    let retained = try #require(model.children(of: folder).first { $0.name == "item-300.bin" })
    model.selectItems([retained.id], in: original.id)
    await model.waitForPresentation()
    let expanded = model.expandedIDs
    await model.trashConfirmed(snapshotID: original.id, nodeIDs: [moved.id])
    await model.waitForPresentation()
    let revised = try #require(model.snapshot)
    #expect(revised.id != original.id && revised.scannedAt == original.scannedAt)
    #expect(model.folderID == folder && model.expandedIDs == expanded)
    #expect(model.selection == [retained.id] && model.selectedNodes.first?.id == retained.id)
    #expect(model.metric == .logical && !model.sortDescending && model.showsMap)
    #expect(model.children(of: folder).count == 599 && !model.hasMoreChildren(of: folder))
    #expect(!model.children(of: folder).contains { $0.id == moved.id })
    #expect(model.error == nil && !model.hasStaleTrashResults && model.canTrash)
    #expect(await fixture.service.scans == 1)
    #expect(await fixture.service.directoryScans == 0)
    // A loaded page remains loaded even when its branch is collapsed during another cleanup.
    model.collapseFolder(folder, in: revised.id)
    await model.focus(relativePath: "Workspace/Code")
    let package = try #require(model.children(of: 0).first { $0.name == "Example.app" })
    await model.trashConfirmed(snapshotID: revised.id, nodeIDs: [package.id])
    await model.waitForPresentation()
    let restartID = try #require(model.snapshot?.id)
    #expect(!model.expandedIDs.contains(folder))
    model.expandFolder(folder, in: restartID)
    await model.waitForPresentation()
    #expect(model.children(of: folder).count == 599 && !model.hasMoreChildren(of: folder))
    #expect(await fixture.service.scans == 1)
    model.stop()
    await model.waitForPresentation()
    await model.start()
    await model.waitForPresentation()
    #expect(model.snapshot?.id == restartID)
    #expect(await model.expand(relativePath: "Workspace/Code/Sources/item-299.bin") == nil)
    #expect(await fixture.service.scans == 1)
    model.stop()
    await model.waitForPresentation()
}

@Test @MainActor
func storageTreeTrashingFocusedAncestorReturnsToNearestSurvivingFolder() async throws {
    let fixture = try TreeModelFixture()
    defer { try? fixture.cleanup() }
    let model = StorageModel(service: fixture.service, volumeProvider: { [] })
    await model.start()
    await model.selectFolder(fixture.root)
    await model.waitForScan()
    let original = try #require(model.snapshot)
    await model.focus(relativePath: "Workspace/Code/Sources")
    let code = try #require(model.breadcrumbs.first { $0.name == "Code" })
    let workspace = try #require(model.breadcrumbs.first { $0.name == "Workspace" })
    await model.trashConfirmed(snapshotID: original.id, nodeIDs: [code.id])
    await model.waitForPresentation()
    #expect(model.snapshot != nil && model.snapshot?.id != original.id)
    #expect(model.folderID == workspace.id && model.currentName == "Workspace")
    #expect(model.children(of: workspace.id).isEmpty && !model.expandedIDs.contains(code.id))
    #expect(model.error == nil)
    #expect(await fixture.service.scans == 1)
    model.stop()
    await model.waitForPresentation()
}

@Test(arguments: [true, false]) @MainActor
func storageTreeFailedAppendStopsAutomaticRetryAndPreservesUsableTree(restoringPages: Bool) async throws {
    let fixture = try TreeModelFixture()
    defer { try? fixture.cleanup() }
    let model = StorageModel(service: fixture.service, volumeProvider: { [] })
    await model.start()
    await model.selectFolder(fixture.root)
    await model.waitForScan()
    let snapshot = try #require(model.snapshot)
    model.metric = .logical
    await model.waitForPresentation()
    let folder = try #require(await model.expand(relativePath: "Workspace/Code/Sources"))
    if restoringPages {
        while model.hasMoreChildren(of: folder) {
            model.loadMoreChildren(of: folder, in: snapshot.id)
            await model.waitForPresentation()
        }
    }
    await fixture.service.failAppendedPages(of: folder)
    if restoringPages {
        model.metric = .allocated
        await model.waitForPresentation()
    } else {
        #expect(await model.expand(relativePath: "Workspace/Code/Sources/item-000.bin") == nil)
        await model.waitForPresentation()
    }
    #expect(await fixture.service.failedPageAttempts == 1)
    #expect(model.error?.contains("Saved page temporarily unavailable") == true)
    #expect(model.snapshot?.id == snapshot.id && !model.isPreparingPresentation)
    #expect(model.children(of: folder).count == 200 && model.hasMoreChildren(of: folder))
    await fixture.service.clearPageFailures()
    model.loadMoreChildren(of: folder, in: snapshot.id)
    await model.waitForPresentation()
    #expect(model.children(of: folder).count == 400)
    #expect(await fixture.service.scans == 1)
    model.stop()
    await model.waitForPresentation()
}

@Test @MainActor
func storageTreeRestartKeepsHistoricalCacheReadOnlyAfterTrashSaveFailure() async throws {
    let fixture = try TreeModelFixture()
    defer { try? fixture.cleanup() }
    let cacheDirectory = fixture.directory.appending(path: "cache")
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path) }
    let model = StorageModel(service: fixture.service, volumeProvider: { [] })
    await model.start()
    await model.selectFolder(fixture.root)
    await model.waitForScan()
    let original = try #require(model.snapshot)
    await model.select(relativePath: "Workspace/Code/Sources/item-299.bin")
    let moved = try #require(model.selectedNodes.first)
    // Keep the old JSON readable while allowing the independent index directory to be updated.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheDirectory.path)
    await model.trashConfirmed(snapshotID: original.id, nodeIDs: [moved.id])
    await model.waitForPresentation()
    #expect(model.snapshot?.id != original.id && model.error != nil)
    model.stop()
    await model.waitForPresentation()

    let restarted = fixture.restartedService()
    let reopened = StorageModel(service: restarted, volumeProvider: { [] })
    await reopened.start()
    await reopened.waitForPresentation()
    #expect(reopened.snapshot?.id == original.id && reopened.hasStaleTrashResults)
    await reopened.select(relativePath: "Workspace/Code/Sources/item-300.bin")
    #expect(!reopened.selectedNodes.isEmpty && !reopened.canTrash)
    reopened.requestTrashConfirmation()
    #expect(reopened.pendingTrash == nil)
    #expect(await restarted.scans == 0)
    reopened.stop()
    await reopened.waitForPresentation()
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)
    await reopened.start()
    await reopened.waitForPresentation()
    reopened.refresh()
    await reopened.waitForScan()
    #expect(reopened.snapshot?.id != original.id && !reopened.hasStaleTrashResults)
    #expect(await restarted.scans == 1)
    reopened.stop()
    await reopened.waitForPresentation()
}
