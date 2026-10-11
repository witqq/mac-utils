import AppKit
import Darwin
import Foundation
import MacUtilsCore

public struct StorageGrant: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let name: String

    public init(id: UUID = UUID(), path: String, name: String) {
        self.id = id
        self.path = path
        self.name = name
    }
}

public struct StorageTrashFailure: Equatable, Sendable {
    public let nodeID: Int
    public let message: String

    public init(nodeID: Int, message: String) {
        self.nodeID = nodeID
        self.message = message
    }
}

public struct StorageTrashResult: Equatable, Sendable {
    public let trashedNodeIDs: [Int]
    public let failures: [StorageTrashFailure]
    public let invalidatedGrantIDs: [UUID]
    public let cacheInvalidationError: String?
    public let updatedSnapshot: StorageSnapshot?

    public init(trashedNodeIDs: [Int], failures: [StorageTrashFailure], invalidatedGrantIDs: [UUID], cacheInvalidationError: String? = nil,
                updatedSnapshot: StorageSnapshot? = nil) {
        self.trashedNodeIDs = trashedNodeIDs
        self.failures = failures
        self.invalidatedGrantIDs = invalidatedGrantIDs
        self.cacheInvalidationError = cacheInvalidationError
        self.updatedSnapshot = updatedSnapshot
    }
}

public protocol StorageManaging: Sendable {
    func grants() async throws -> [StorageGrant]
    func selectFolder(_ url: URL) async throws -> StorageGrant
    func cachedSnapshot(for grant: StorageGrant) async throws -> StorageSnapshot?
    func isSnapshotSuperseded(_ snapshot: StorageSnapshot) async throws -> Bool
    func scan(_ grant: StorageGrant, progress: @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot
    func scanDirectory(nodeID: Int, in snapshot: StorageSnapshot, progress: @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot
    func treeChildren(parentID: Int, in snapshot: StorageSnapshot, metric: StorageSizeMetric,
                      descending: Bool, offset: Int, limit: Int) async throws -> StorageTreePage
    func treeItem(id: Int, in snapshot: StorageSnapshot) async throws -> StorageItemReference?
    func releaseTree(snapshotID: UUID) async
    func openDirectory(nodeID: Int, in snapshot: StorageSnapshot) async throws
    func clearCache() async throws
    func resetSavedLocations() async throws
    func removeGrant(_ grant: StorageGrant) async throws
    func reveal(nodeID: Int, in snapshot: StorageSnapshot) async throws
    func reveal(item: StorageItemReference, in snapshot: StorageSnapshot) async throws
    func trash(nodeIDs: [Int], in snapshot: StorageSnapshot) async throws -> StorageTrashResult
    func trash(items: [StorageItemReference], in snapshot: StorageSnapshot) async throws -> StorageTrashResult
}

public extension StorageManaging {
    func isSnapshotSuperseded(_ snapshot: StorageSnapshot) async throws -> Bool { false }

    func treeChildren(parentID: Int, in snapshot: StorageSnapshot, metric: StorageSizeMetric = .allocated,
                      descending: Bool = true, offset: Int = 0, limit: Int = 200) async throws -> StorageTreePage {
        try legacyStorageTreePage(parentID: parentID, snapshot: snapshot, metric: metric,
            descending: descending, offset: offset, limit: limit)
    }

    func treeItem(id: Int, in snapshot: StorageSnapshot) async throws -> StorageItemReference? {
        try snapshot.validate()
        guard snapshot.schemaVersion == 1 else {
            throw StorageServiceError.treeUnavailable
        }
        return snapshot.itemReference(id: id)
    }

    func releaseTree(snapshotID: UUID) async {}

    func openDirectory(nodeID: Int, in snapshot: StorageSnapshot) async throws {
        throw StorageServiceError.access("This storage provider does not support opening directory contents.")
    }

    func scanDirectory(nodeID: Int, in snapshot: StorageSnapshot, progress: @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot {
        throw StorageServiceError.access("This storage provider does not support directory drill-down.")
    }

    func reveal(item: StorageItemReference, in snapshot: StorageSnapshot) async throws {
        guard snapshot.itemReference(id: item.id) == item else { throw StorageServiceError.invalidData("The selected item is absent from this scan.") }
        try await reveal(nodeID: item.id, in: snapshot)
    }

    func trash(items: [StorageItemReference], in snapshot: StorageSnapshot) async throws -> StorageTrashResult {
        guard items.allSatisfy({ snapshot.itemReference(id: $0.id) == $0 }) else { throw StorageServiceError.invalidData("The selected item is absent from this scan.") }
        return try await trash(nodeIDs: items.map(\.id), in: snapshot)
    }
}

public enum StorageServiceError: Error, Sendable, CustomStringConvertible {
    case invalidData(String)
    case access(String)
    case staleItem(String)
    case unsafeItem(String)
    case treeUnavailable

    public var description: String {
        switch self {
        case let .invalidData(message), let .access(message), let .staleItem(message), let .unsafeItem(message): message
        case .treeUnavailable: "This saved overview has no complete tree. Start an explicit fresh analysis to build it."
        }
    }
}

protocol StorageResourceAccess: Sendable {
    func bookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool)
    func start(_ url: URL) throws -> Bool
    func stop(_ url: URL)
    func trash(_ url: URL) throws
    func reveal(_ url: URL) async throws
    func openDirectory(_ url: URL) async throws
}

extension StorageResourceAccess {
    func openDirectory(_ url: URL) async throws {
        throw StorageServiceError.access("This storage provider does not support opening directory contents.")
    }
}

struct NativeStorageResourceAccess: StorageResourceAccess {
    func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    func start(_ url: URL) throws -> Bool {
        let started = url.startAccessingSecurityScopedResource()
        #if APP_STORE
        guard started else { throw StorageServiceError.access("Folder access has expired. Select the folder again.") }
        #endif
        return started
    }

    func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }

    func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    @MainActor func reveal(_ url: URL) async throws {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor func openDirectory(_ url: URL) async throws {
        guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) else {
            throw StorageServiceError.access("Finder could not open this directory.")
        }
    }
}

private struct SavedStorageGrant: Codable, Sendable {
    var grant: StorageGrant
    var bookmark: Data
}

private struct StorageGrantArchive: Codable, Sendable {
    var schemaVersion = 1
    var entries: [SavedStorageGrant] = []
}

private struct StorageCacheArchive: Codable, Sendable {
    var schemaVersion = 1
    var snapshots: [StorageSnapshot] = []
    // Optional preserves decoding of the original schema-1 cache envelope.
    var savedCompleteSnapshots: [StorageSnapshot]?
    var completeSnapshots: [StorageSnapshot] {
        get { savedCompleteSnapshots ?? [] }
        set { savedCompleteSnapshots = newValue.isEmpty ? nil : newValue }
    }
}

private struct BoundedStorageFileAccess: AtomicFileAccess {
    let maximumBytes: Int
    func read(from url: URL) async throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw StorageServiceError.invalidData("The storage cache exceeds its size limit. Clear the cache.") }
        return data
    }
    func writeAtomically(_ data: Data, to url: URL) async throws {
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw StorageServiceError.invalidData("The storage cache exceeds its size limit.") }
        try await LocalAtomicFileAccess().writeAtomically(data, to: url)
    }
}

/// Folder grants survive cache clearing. Snapshots are dated historical metadata, never freshness proofs.
public actor StorageService: StorageManaging {
    public static var defaultGrantsURL: URL {
        ConfigurationStore.defaultFileURL.deletingLastPathComponent().appending(path: "storage-grants.json")
    }
    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.witqq.mac-utils/storage-snapshots.json")
    }

    private let grantsStore: AtomicJSONFileStore<StorageGrantArchive>
    private let cacheStore: AtomicJSONFileStore<StorageCacheArchive>
    private let resourceAccess: any StorageResourceAccess
    private let diagnostics: StorageDiagnostics?
    private let scanOperation: @Sendable (URL, UUID, @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot
    private let treePruneOperation: @Sendable (StorageTreeReader, [Int]) async throws -> StorageSnapshot
    private var grantArchive: StorageGrantArchive?
    private var cacheArchive: StorageCacheArchive?
    // A failed manifest replacement can leave readable disk JSON naming older
    // generations than the accurate session archive. Keep both sets alive.
    private var persistedTreeIDs = Set<UUID>()
    private var cacheGeneration: UInt64 = 0
    private var scanVersions: [UUID: UInt64] = [:]
    private var mutationActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private let maximumCacheBytes: Int
    private let maximumCachedRoots: Int
    private let treeDirectoryURL: URL
    private let maximumTreeBytes: UInt64
    private let treeScansEnabled: Bool
    private struct TreeLease {
        let reader: StorageTreeReader
        let snapshot: StorageSnapshot
    }
    private var treeReaders: [UUID: TreeLease] = [:]
    private var supersededTrees: [UUID: UUID] = [:]
    private var activeTreeScans = 0
    private let userHomeDirectoryProvider: @Sendable () -> URL?
    private let applicationHomeDirectoryProvider: @Sendable () -> URL

    private nonisolated static func defaultTreePrune(_ reader: StorageTreeReader, _ ids: [Int]) async throws -> StorageSnapshot {
        try await reader.prunedSnapshot(removing: ids)
    }

    public init(grantsURL: URL = StorageService.defaultGrantsURL, cacheURL: URL = StorageService.defaultCacheURL) {
        grantsStore = AtomicJSONFileStore(fileURL: grantsURL)
        cacheStore = AtomicJSONFileStore(fileURL: cacheURL, fileAccess: BoundedStorageFileAccess(maximumBytes: 32 * 1_024 * 1_024))
        resourceAccess = NativeStorageResourceAccess()
        diagnostics = .shared
        let treeDirectory = cacheURL.deletingLastPathComponent().appending(path: "storage-trees", directoryHint: .isDirectory)
        treeDirectoryURL = treeDirectory
        maximumTreeBytes = 8 * 1_024 * 1_024 * 1_024
        treeScansEnabled = true
        treePruneOperation = Self.defaultTreePrune
        scanOperation = { root, id, progress in try await StorageScanner(treeDirectory: treeDirectory).scan(rootURL: root, grantID: id, progress: progress) }
        maximumCacheBytes = 32 * 1_024 * 1_024
        maximumCachedRoots = 12
        userHomeDirectoryProvider = { SystemEnvironment.userHomeDirectoryURL }
        applicationHomeDirectoryProvider = { FileManager.default.homeDirectoryForCurrentUser }
    }

    init(grantsURL: URL, cacheURL: URL, resourceAccess: any StorageResourceAccess, maximumCacheBytes: Int = 32 * 1_024 * 1_024, maximumCachedRoots: Int = 12,
         userHomeDirectoryProvider: @escaping @Sendable () -> URL? = { SystemEnvironment.userHomeDirectoryURL },
         applicationHomeDirectoryProvider: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
         diagnostics: StorageDiagnostics? = nil,
         maximumTreeBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024,
         treeScansEnabled: Bool = false,
         treePruneOperation: @escaping @Sendable (StorageTreeReader, [Int]) async throws -> StorageSnapshot = StorageService.defaultTreePrune,
         scanOperation: @escaping @Sendable (URL, UUID, @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot = { root, id, progress in try await StorageScanner().scan(rootURL: root, grantID: id, progress: progress) }) {
        grantsStore = AtomicJSONFileStore(fileURL: grantsURL)
        cacheStore = AtomicJSONFileStore(fileURL: cacheURL, fileAccess: BoundedStorageFileAccess(maximumBytes: maximumCacheBytes))
        self.resourceAccess = resourceAccess
        self.diagnostics = diagnostics
        self.scanOperation = scanOperation
        self.treePruneOperation = treePruneOperation
        self.maximumCacheBytes = maximumCacheBytes
        self.maximumCachedRoots = maximumCachedRoots
        treeDirectoryURL = cacheURL.deletingLastPathComponent().appending(path: "storage-trees", directoryHint: .isDirectory)
        self.maximumTreeBytes = maximumTreeBytes
        self.treeScansEnabled = treeScansEnabled
        self.userHomeDirectoryProvider = userHomeDirectoryProvider
        self.applicationHomeDirectoryProvider = applicationHomeDirectoryProvider
    }

    public func grants() async throws -> [StorageGrant] {
        await acquireMutation()
        defer { releaseMutation() }
        try await loadGrants()
        return grantArchive!.entries.map(\.grant)
    }

    public func selectFolder(_ url: URL) async throws -> StorageGrant {
        await acquireMutation()
        defer { releaseMutation() }
        try await loadGrants()
        let started = try resourceAccess.start(url)
        defer { if started { resourceAccess.stop(url) } }
        let selected = url.standardizedFileURL
        let values = try selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw StorageServiceError.unsafeItem("Select a directory rather than a symbolic link.")
        }
        let root = selected.resolvingSymlinksInPath()
        let bookmark = try resourceAccess.bookmark(for: url)
        var old = grantArchive!.entries.first { $0.grant.path == root.path }
        if old == nil {
            for entry in grantArchive!.entries {
                // An unrelated expired grant must not prevent selecting a newly authorized folder.
                do {
                    let resolved = try resourceAccess.resolve(entry.bookmark)
                    let started = try resourceAccess.start(resolved.url)
                    defer { if started { resourceAccess.stop(resolved.url) } }
                    if resolved.url.standardizedFileURL.resolvingSymlinksInPath().path == root.path {
                        old = entry
                        break
                    }
                } catch { continue }
            }
        }
        let grant = StorageGrant(id: old?.grant.id ?? UUID(), path: root.path, name: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
        var candidate = grantArchive!
        candidate.entries.removeAll { $0.grant.id == grant.id }
        candidate.entries.append(SavedStorageGrant(grant: grant, bookmark: bookmark))
        try await grantsStore.write(candidate)
        grantArchive = candidate
        return grant
    }

    public func cachedSnapshot(for grant: StorageGrant) async throws -> StorageSnapshot? {
        await acquireMutation()
        defer { releaseMutation() }
        try await loadGrants()
        guard grantArchive!.entries.contains(where: { $0.grant.id == grant.id }) else { throw StorageServiceError.access("Select this folder again to restore access.") }
        try await loadCache()
        let snapshot = cacheArchive!.snapshots.first { $0.grantID == grant.id }
        if let snapshot, snapshot.tree != nil { _ = try reader(for: snapshot) }
        try cleanupTreeIndices()
        return snapshot
    }

    public func treeChildren(parentID: Int, in snapshot: StorageSnapshot, metric: StorageSizeMetric = .allocated,
                             descending: Bool = true, offset: Int = 0, limit: Int = 200) async throws -> StorageTreePage {
        if snapshot.tree == nil {
            return try legacyStorageTreePage(parentID: parentID, snapshot: snapshot, metric: metric,
                descending: descending, offset: offset, limit: limit)
        }
        return try await reader(for: snapshot).children(parentID: parentID, metric: metric,
            descending: descending, offset: offset, limit: limit)
    }

    public func isSnapshotSuperseded(_ snapshot: StorageSnapshot) async throws -> Bool {
        try Self.validate(snapshot)
        return try snapshotIsSuperseded(snapshot)
    }

    private func snapshotIsSuperseded(_ snapshot: StorageSnapshot) throws -> Bool {
        if supersededTrees[snapshot.id] != nil { return true }
        return try StorageTreeReader.isSuperseded(directoryURL: treeDirectoryURL, id: snapshot.id)
    }

    public func treeItem(id: Int, in snapshot: StorageSnapshot) async throws -> StorageItemReference? {
        if snapshot.tree == nil {
            guard snapshot.schemaVersion == 1 else {
                throw StorageServiceError.treeUnavailable
            }
            try Self.validate(snapshot)
            return snapshot.itemReference(id: id)
        }
        return try await reader(for: snapshot).item(id: id)
    }

    public func releaseTree(snapshotID: UUID) async {
        await acquireMutation()
        defer { releaseMutation() }
        if let lease = treeReaders.removeValue(forKey: snapshotID) { await lease.reader.close() }
        do { try await loadCache(); try cleanupTreeIndices() }
        catch { diagnostics?.record("tree.cleanupFailed", scanID: snapshotID.uuidString, details: ["error": String(describing: error)]) }
    }

    public func scan(_ grant: StorageGrant, progress: @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot {
        activeTreeScans += 1
        defer { activeTreeScans -= 1; cleanupAfterScan() }
        let diagnostic = StorageScanDiagnosticSession(rootPath: grant.path, operation: "scan", diagnostics: diagnostics)
        let heartbeat = diagnostic.heartbeat()
        defer { heartbeat.cancel() }
        var newlyRetainedTreeID: UUID?
        func completed(_ snapshot: StorageSnapshot, cache: String) -> StorageSnapshot {
            diagnostic.finish("scan.complete", details: ["cacheDisposition": cache,
                "isComplete": String(snapshot.isComplete), "issueCount": String(snapshot.issues.count),
                "omittedIssueCount": String(snapshot.omittedIssueCount), "fileCount": String(snapshot.root?.fileCount ?? 0)])
            return snapshot
        }
        do {
            let (scopedURL, generation, scanVersion) = try await scanContext(for: grant.id, beginsScan: true)
            diagnostic.phase("access")
            let started = try resourceAccess.start(scopedURL)
            defer { if started { resourceAccess.stop(scopedURL) } }
            let root = scopedURL.standardizedFileURL.resolvingSymlinksInPath()
            diagnostic.phase("preparation")
            let treeLease = treeScansEnabled ? try StorageTreeScanLease(directoryURL: treeDirectoryURL) : nil
            defer { treeLease?.close() }
            let snapshot = try await scanOperation(root, grant.id) { value in
                diagnostic.progress(value)
                await progress(value)
            }
            diagnostic.phase("validateSnapshot")
            try Task.checkCancellation()
            try Self.validate(snapshot)
            guard snapshot.grantID == grant.id, snapshot.rootPath == root.path else {
                throw StorageServiceError.invalidData("The scanner returned a snapshot for another folder.")
            }
            if let tree = snapshot.tree {
                let alreadyActive = treeReaders[tree.id] != nil
                _ = try reader(for: snapshot)
                if !alreadyActive { newlyRetainedTreeID = tree.id }
            }
            diagnostic.phase("loadCache")
            await acquireMutation()
            defer { releaseMutation() }
            try await loadCache()
            guard generation == cacheGeneration, scanVersion == scanVersions[grant.id] else { return completed(snapshot, cache: "generationChanged") }
            let previous = cacheArchive!.snapshots.first { $0.grantID == grant.id }
            if snapshot.tree == nil, !snapshot.isComplete, previous?.isComplete == true {
                return completed(snapshot, cache: "previousCompletePreserved")
            }
            var candidate = cacheArchive!
            if snapshot.tree != nil, !snapshot.isComplete, let previous, previous.isComplete {
                candidate.completeSnapshots.removeAll { $0.grantID == grant.id }
                candidate.completeSnapshots.insert(previous, at: 0)
            } else if snapshot.isComplete { candidate.completeSnapshots.removeAll { $0.grantID == grant.id } }
            candidate.snapshots.removeAll { $0.grantID == grant.id }
            candidate.snapshots.insert(snapshot, at: 0)
            candidate.snapshots = Array(candidate.snapshots.prefix(maximumCachedRoots))
            let retainedGrants = Set(candidate.snapshots.map(\.grantID))
            candidate.completeSnapshots.removeAll { !retainedGrants.contains($0.grantID) }
            trimTreeBudget(&candidate, preserving: snapshot.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard try encoder.encode(StorageCacheArchive(snapshots: [snapshot])).count <= maximumCacheBytes else { return completed(snapshot, cache: "snapshotTooLarge") }
            while !candidate.snapshots.isEmpty, try encoder.encode(candidate).count > maximumCacheBytes {
                if !candidate.completeSnapshots.isEmpty { candidate.completeSnapshots.removeLast() }
                else { candidate.snapshots.removeLast() }
            }
            try Task.checkCancellation()
            guard generation == cacheGeneration, scanVersion == scanVersions[grant.id] else { return completed(snapshot, cache: "generationChanged") }
            diagnostic.phase("saveCache")
            try await writeCache(candidate)
            cacheArchive = candidate
            try cleanupTreeIndices()
            return completed(snapshot, cache: "saved")
        } catch {
            if let id = newlyRetainedTreeID, !storedTreeIDs.contains(id) {
                if let lease = treeReaders.removeValue(forKey: id) { await lease.reader.close() }
                do { _ = try StorageTreeReader.removeIfUnused(directoryURL: treeDirectoryURL, id: id) }
                catch { diagnostics?.record("tree.cleanupFailed", scanID: id.uuidString, details: ["error": String(describing: error)]) }
            }
            diagnostic.finish(error is CancellationError ? "scan.cancelled" : "scan.failed", details: ["error": String(describing: error)])
            throw error
        }
    }

    public func clearCache() async throws {
        await acquireMutation()
        defer { releaseMutation() }
        cacheGeneration &+= 1
        let candidate = StorageCacheArchive()
        try await writeCache(candidate)
        cacheArchive = candidate
        try cleanupTreeIndices()
    }

    /// Drill-down uses the original folder permission and never replaces its historical overview cache.
    public func scanDirectory(nodeID: Int, in snapshot: StorageSnapshot, progress: @escaping @Sendable (StorageScanProgress) async -> Void) async throws -> StorageSnapshot {
        activeTreeScans += 1
        defer { activeTreeScans -= 1; cleanupAfterScan() }
        let diagnostic = StorageScanDiagnosticSession(rootPath: snapshot.rootPath, operation: "scanDirectory", diagnostics: diagnostics)
        let heartbeat = diagnostic.heartbeat()
        defer { heartbeat.cancel() }
        do {
            try Self.validate(snapshot)
            guard let item = try await canonicalItem(id: nodeID, in: snapshot), item.kind == .directory, !item.isCloudPlaceholder else {
                throw StorageServiceError.unsafeItem("Select an available directory to inspect its contents.")
            }
            let (scopedURL, _, _) = try await scanContext(for: snapshot.grantID)
            let started = try resourceAccess.start(scopedURL)
            defer { if started { resourceAccess.stop(scopedURL) } }
            let authorizationRoot = scopedURL.standardizedFileURL.resolvingSymlinksInPath()
            diagnostic.phase("validateSelection")
            let target = try validatedURL(item: item, snapshot: snapshot, root: authorizationRoot, allowRoot: true)
            let currentRelative = Self.relativePath(of: URL(fileURLWithPath: snapshot.rootPath), under: authorizationRoot)
            let ancestors = snapshot.rootAncestors + item.ancestors.map {
                StoragePathIdentity(relativePath: Self.join(currentRelative, $0.relativePath), identity: $0.identity)
            }
            diagnostic.phase("preparation")
            let treeLease = treeScansEnabled ? try StorageTreeScanLease(directoryURL: treeDirectoryURL) : nil
            defer { treeLease?.close() }
            let result = try await StorageScanner(treeDirectory: treeScansEnabled ? treeDirectoryURL : nil).scan(rootURL: target, grantID: snapshot.grantID,
                authorizationRootPath: snapshot.authorizationRootPath, authorizationRootIdentity: snapshot.authorizationRootIdentity,
                rootAncestors: ancestors, progress: { value in diagnostic.progress(value); await progress(value) })
            diagnostic.phase("validateSnapshot")
            try Task.checkCancellation()
            try Self.validate(result)
            guard result.rootIdentity == item.identity else {
                throw StorageServiceError.staleItem("The selected directory changed while it was being inspected. Scan again.")
            }
            if result.tree != nil { _ = try reader(for: result) }
            diagnostic.finish("scan.complete", details: ["cacheDisposition": "drillNotCached", "isComplete": String(result.isComplete),
                "issueCount": String(result.issues.count), "fileCount": String(result.root?.fileCount ?? 0)])
            return result
        } catch {
            diagnostic.finish(error is CancellationError ? "scan.cancelled" : "scan.failed", details: ["error": String(describing: error)])
            throw error
        }
    }

    /// Explicit recovery removes only this utility's saved grants and snapshots, never scanned files.
    public func resetSavedLocations() async throws {
        await acquireMutation()
        defer { releaseMutation() }
        cacheGeneration &+= 1
        let emptyCache = StorageCacheArchive()
        try await writeCache(emptyCache)
        cacheArchive = emptyCache
        let emptyGrants = StorageGrantArchive()
        try await grantsStore.write(emptyGrants)
        grantArchive = emptyGrants
        scanVersions.removeAll()
        try cleanupTreeIndices()
    }

    public func removeGrant(_ grant: StorageGrant) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        try await loadGrants()
        var grants = grantArchive!
        grants.entries.removeAll { $0.grant.id == grant.id }
        try await grantsStore.write(grants)
        grantArchive = grants
        try await loadCache()
        cacheGeneration &+= 1
        var cache = cacheArchive!
        cache.snapshots.removeAll { $0.grantID == grant.id }
        cache.completeSnapshots.removeAll { $0.grantID == grant.id }
        try await writeCache(cache)
        cacheArchive = cache
        try cleanupTreeIndices()
    }

    public func reveal(nodeID: Int, in snapshot: StorageSnapshot) async throws {
        guard let item = try await canonicalItem(id: nodeID, in: snapshot) else { throw StorageServiceError.invalidData("The selected item is absent from this scan.") }
        try await reveal(item: item, in: snapshot)
    }

    public func openDirectory(nodeID: Int, in snapshot: StorageSnapshot) async throws {
        try Self.validate(snapshot)
        guard let item = try await canonicalItem(id: nodeID, in: snapshot), item.kind == .directory else {
            throw StorageServiceError.unsafeItem("Select a directory to open its contents in Finder.")
        }
        let (scopedURL, _, _) = try await scanContext(for: snapshot.grantID)
        let started = try resourceAccess.start(scopedURL)
        defer { if started { resourceAccess.stop(scopedURL) } }
        let root = scopedURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = try validatedURL(item: item, snapshot: snapshot, root: root, allowRoot: true)
        try await resourceAccess.openDirectory(url)
    }

    public func reveal(item: StorageItemReference, in snapshot: StorageSnapshot) async throws {
        try Self.validate(snapshot)
        guard try await canonicalItem(id: item.id, in: snapshot) == item else {
            throw StorageServiceError.invalidData("The selected item does not match this scan.")
        }
        let (scopedURL, _, _) = try await scanContext(for: snapshot.grantID)
        let started = try resourceAccess.start(scopedURL)
        defer { if started { resourceAccess.stop(scopedURL) } }
        let root = scopedURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = try validatedURL(item: item, snapshot: snapshot, root: root, allowRoot: true)
        try await resourceAccess.reveal(url)
    }

    public func trash(nodeIDs: [Int], in snapshot: StorageSnapshot) async throws -> StorageTrashResult {
        var items: [StorageItemReference] = []
        var missing: [StorageTrashFailure] = []
        for id in Set(nodeIDs).sorted() {
            if let item = try await canonicalItem(id: id, in: snapshot) { items.append(item) }
            else { missing.append(StorageTrashFailure(nodeID: id, message: "The selected item is absent from this scan.")) }
        }
        let result = try await trash(items: items, in: snapshot)
        return StorageTrashResult(trashedNodeIDs: result.trashedNodeIDs, failures: result.failures + missing,
            invalidatedGrantIDs: result.invalidatedGrantIDs, cacheInvalidationError: result.cacheInvalidationError,
            updatedSnapshot: result.updatedSnapshot)
    }

    public func trash(items: [StorageItemReference], in snapshot: StorageSnapshot) async throws -> StorageTrashResult {
        await acquireMutation()
        defer { releaseMutation() }
        try Self.validate(snapshot)
        let scopedURL = try await resolve(snapshot.grantID)
        let started = try resourceAccess.start(scopedURL)
        defer { if started { resourceAccess.stop(scopedURL) } }
        let root = scopedURL.standardizedFileURL.resolvingSymlinksInPath()
        try await loadCache()
        guard try !snapshotIsSuperseded(snapshot) else {
            throw StorageServiceError.staleItem("This result has already been updated after moving items to Trash. Use the current result.")
        }
        if snapshot.tree != nil, let latest = cacheArchive!.snapshots.first(where: { $0.grantID == snapshot.grantID }),
           latest.rootPath == snapshot.rootPath, latest.id != snapshot.id {
            throw StorageServiceError.staleItem("A newer saved analysis exists for this location. Use its current result before cleanup.")
        }
        let updateLease = snapshot.tree != nil ? try StorageTreeScanLease(directoryURL: treeDirectoryURL) : nil
        defer { updateLease?.close(); cleanupAfterScan() }
        let trashID = UUID().uuidString
        diagnostics?.record("trash.begin", scanID: trashID, details: ["rootPath": snapshot.rootPath,
            "snapshotID": snapshot.id.uuidString, "selectedCount": String(Set(items.map(\.id)).count)])
        var currentCachedRoots: [UUID: URL] = [snapshot.grantID: root]
        var unresolvedCachedRoots = Set<UUID>()
        // Cache retention bounds this lookup to at most twelve roots, without scanning any root.
        for cached in cacheArchive!.snapshots where cached.grantID != snapshot.grantID {
            do {
                _ = try await resolve(cached.grantID)
                guard let grant = grantArchive!.entries.first(where: { $0.grant.id == cached.grantID })?.grant else {
                    unresolvedCachedRoots.insert(cached.grantID)
                    continue
                }
                currentCachedRoots[cached.grantID] = URL(fileURLWithPath: grant.path)
            } catch { unresolvedCachedRoots.insert(cached.grantID) }
        }
        var trashed: [Int] = []
        var failures: [StorageTrashFailure] = []
        var changedURLs: [URL] = []
        var cacheInvalidationError: String?
        var updatedSnapshot: StorageSnapshot?
        var processedIDs = Set<Int>()
        var prepared: [(StorageItemReference, URL)] = []
        for item in items.sorted(by: { $0.id < $1.id }) where processedIDs.insert(item.id).inserted {
            do {
                guard try await canonicalItem(id: item.id, in: snapshot) == item else {
                    throw StorageServiceError.invalidData("The selected item does not match this scan.")
                }
                let url = try validatedURL(item: item, snapshot: snapshot, root: root, allowRoot: false)
                prepared.append((item, url))
            } catch {
                failures.append(StorageTrashFailure(nodeID: item.id, message: String(describing: error)))
            }
        }
        // Persist mutation exclusion before touching source files. A readable old
        // manifest can survive a later save failure and must remain read-only on restart.
        let potentialURLs = prepared.map { $0.1 }
        let potentialGrants = Set(grantArchive!.entries.filter { entry in
            !potentialURLs.isEmpty && (entry.grant.id == snapshot.grantID || potentialURLs.contains { changed in
                Self.overlaps(URL(fileURLWithPath: entry.grant.path), changed)
                    || currentCachedRoots[entry.grant.id].map { Self.overlaps($0, changed) } == true
            })
        }.map { $0.grant.id }).union(potentialURLs.isEmpty ? [] : unresolvedCachedRoots)
        let generations = cacheArchive!.snapshots + cacheArchive!.completeSnapshots + treeReaders.values.map(\.snapshot) + [snapshot]
        let affectedIDs = Set(generations.filter { candidate in
            guard !potentialURLs.isEmpty else { return false }
            if candidate.id == snapshot.id { return true }
            return candidate.grantID == snapshot.grantID
                ? potentialURLs.contains { Self.overlaps(URL(fileURLWithPath: candidate.rootPath), $0) }
                : potentialGrants.contains(candidate.grantID)
                    || potentialURLs.contains { Self.overlaps(URL(fileURLWithPath: candidate.rootPath), $0) }
        }.map(\.id))
        var provisionalMarkers = Set<UUID>()
        do {
            for id in affectedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                if try StorageTreeReader.markSuperseded(directoryURL: treeDirectoryURL, id: id) {
                    provisionalMarkers.insert(id)
                } else if id == snapshot.id {
                    throw StorageServiceError.staleItem("This result was superseded by another cleanup operation. Use its current result.")
                }
            }
        } catch {
            for id in provisionalMarkers { try? StorageTreeReader.unmarkSuperseded(directoryURL: treeDirectoryURL, id: id) }
            throw StorageServiceError.access("Cleanup could not record durable protection for the saved results. No items were moved: \(error)")
        }
        for (item, _) in prepared {
            do {
                // Validate once more after metadata preparation, immediately before moving.
                let url = try validatedURL(item: item, snapshot: snapshot, root: root, allowRoot: false)
                try resourceAccess.trash(url)
                trashed.append(item.id)
                changedURLs.append(url)
            } catch {
                failures.append(StorageTrashFailure(nodeID: item.id, message: String(describing: error)))
            }
        }
        if trashed.isEmpty {
            for id in provisionalMarkers { try StorageTreeReader.unmarkSuperseded(directoryURL: treeDirectoryURL, id: id) }
        }
        var invalidated = Set(grantArchive!.entries.filter { entry in
            !changedURLs.isEmpty && (entry.grant.id == snapshot.grantID || changedURLs.contains { changed in
                Self.overlaps(URL(fileURLWithPath: entry.grant.path), changed) || cacheArchive!.snapshots.contains {
                    $0.grantID == entry.grant.id && Self.overlaps(currentCachedRoots[$0.grantID] ?? URL(fileURLWithPath: $0.rootPath), changed)
                }
            })
        }.map { $0.grant.id })
        if !trashed.isEmpty {
            invalidated.formUnion(unresolvedCachedRoots)
            let actuallyAffectedIDs = Set(generations.filter { candidate in
                if candidate.id == snapshot.id { return true }
                return candidate.grantID == snapshot.grantID
                    ? changedURLs.contains { Self.overlaps(URL(fileURLWithPath: candidate.rootPath), $0) }
                    : invalidated.contains(candidate.grantID)
                        || changedURLs.contains { Self.overlaps(URL(fileURLWithPath: candidate.rootPath), $0) }
            }.map(\.id))
            for id in provisionalMarkers.subtracting(actuallyAffectedIDs) {
                do { try StorageTreeReader.unmarkSuperseded(directoryURL: treeDirectoryURL, id: id) }
                catch {
                    diagnostics?.record("trash.markerCleanupFailed", scanID: trashID,
                        details: ["snapshotID": id.uuidString, "error": String(describing: error)])
                }
            }
            cacheGeneration &+= 1
            if snapshot.tree != nil {
                // Even a later index-write failure makes this generation unsafe for a
                // second mutation: cloning it again could resurrect previously moved rows.
                supersededTrees[snapshot.id] = snapshot.id
                do {
                    let revised = try await treePruneOperation(reader(for: snapshot), trashed)
                    guard revised.id != snapshot.id, revised.schemaVersion == 3,
                          revised.grantID == snapshot.grantID, revised.rootPath == snapshot.rootPath,
                          revised.rootIdentity == snapshot.rootIdentity,
                          revised.authorizationRootPath == snapshot.authorizationRootPath,
                          revised.authorizationRootIdentity == snapshot.authorizationRootIdentity,
                          revised.rootAncestors == snapshot.rootAncestors, revised.scannedAt == snapshot.scannedAt,
                          revised.scanMethod == snapshot.scanMethod, revised.issues == snapshot.issues,
                          revised.omittedIssueCount == snapshot.omittedIssueCount, revised.volume == snapshot.volume,
                          revised.tree?.formatVersion == 2, revised.tree?.nodeCount == snapshot.tree?.nodeCount else {
                        throw StorageServiceError.invalidData("The updated tree does not belong to the original analysis.")
                    }
                    _ = try reader(for: revised)
                    updatedSnapshot = revised
                    supersededTrees[snapshot.id] = revised.id
                } catch {
                    cacheInvalidationError = "Items were moved to Trash, but the saved tree could not be updated. The displayed result is historical: \(error)"
                    diagnostics?.record("trash.cacheUpdateFailed", scanID: trashID,
                        details: ["phase": "updateTree", "error": String(describing: error), "movedCount": String(trashed.count)])
                }
            }
            var candidate = cacheArchive!
            candidate.snapshots.removeAll { invalidated.contains($0.grantID) }
            candidate.completeSnapshots.removeAll { invalidated.contains($0.grantID) }
            for (id, lease) in treeReaders where id != updatedSnapshot?.id {
                let affected = lease.snapshot.grantID == snapshot.grantID
                    ? changedURLs.contains(where: { Self.overlaps(URL(fileURLWithPath: lease.snapshot.rootPath), $0) })
                    : invalidated.contains(lease.snapshot.grantID)
                if affected { supersededTrees[id] = updatedSnapshot?.id ?? id }
            }
            if let updatedSnapshot, updatedSnapshot.rootPath == root.path {
                candidate.snapshots.insert(updatedSnapshot, at: 0)
                candidate.snapshots = Array(candidate.snapshots.prefix(maximumCachedRoots))
                let retainedGrants = Set(candidate.snapshots.map(\.grantID))
                candidate.completeSnapshots.removeAll { !retainedGrants.contains($0.grantID) }
                invalidated.remove(snapshot.grantID)
                trimTreeBudget(&candidate, preserving: updatedSnapshot.id)
            }
            // Physical moves already happened: retain the accurate in-memory tree even
            // when its manifest cannot be persisted, and report persistence separately.
            cacheArchive = candidate
            do { try await writeCache(candidate) }
            catch {
                let message = "Items were moved to Trash, but the updated cache could not be saved: \(error)"
                cacheInvalidationError = [cacheInvalidationError, message].compactMap { $0 }.joined(separator: "\n")
                diagnostics?.record("trash.cacheUpdateFailed", scanID: trashID,
                    details: ["phase": "saveCache", "error": String(describing: error), "movedCount": String(trashed.count)])
            }
            if cacheInvalidationError == nil {
                do { try cleanupTreeIndices() }
                catch { cacheInvalidationError = "Items were moved to Trash, but unused tree indices could not be removed: \(error)" }
            }
        }
        diagnostics?.record("trash.complete", scanID: trashID, details: ["snapshotID": snapshot.id.uuidString,
            "updatedSnapshotID": updatedSnapshot?.id.uuidString ?? "", "movedCount": String(trashed.count),
            "failureCount": String(failures.count), "changedPaths": changedURLs.map(\.path).joined(separator: "\n"),
            "cacheUpdateFailed": String(cacheInvalidationError != nil)])
        return StorageTrashResult(trashedNodeIDs: trashed, failures: failures,
            invalidatedGrantIDs: invalidated.sorted { $0.uuidString < $1.uuidString },
            cacheInvalidationError: cacheInvalidationError, updatedSnapshot: updatedSnapshot)
    }

    private func loadGrants() async throws {
        guard grantArchive == nil else { return }
        switch await grantsStore.read() {
        case .missing: grantArchive = StorageGrantArchive()
        case let .value(archive):
            guard archive.schemaVersion == 1, Set(archive.entries.map { $0.grant.id }).count == archive.entries.count,
                  archive.entries.allSatisfy({ $0.grant.path.hasPrefix("/") && !$0.bookmark.isEmpty }) else {
                throw StorageServiceError.invalidData("The saved folder grants are invalid. Use Reset Saved Locations, then select the folders again.")
            }
            grantArchive = archive
        case let .failure(error): throw StorageServiceError.invalidData("Folder grants could not be loaded. Use Reset Saved Locations, then select the folders again: \(error)")
        }
    }

    private func loadCache() async throws {
        guard cacheArchive == nil else { return }
        switch await cacheStore.read() {
        case .missing:
            cacheArchive = StorageCacheArchive()
            persistedTreeIDs = []
        case let .value(archive):
            guard archive.schemaVersion == 1, archive.snapshots.count <= maximumCachedRoots,
                  Set(archive.snapshots.map(\.grantID)).count == archive.snapshots.count,
                  archive.completeSnapshots.count <= maximumCachedRoots,
                  Set(archive.completeSnapshots.map(\.grantID)).count == archive.completeSnapshots.count,
                  archive.completeSnapshots.allSatisfy(\.isComplete) else {
                throw StorageServiceError.invalidData("The storage cache is invalid. Clear the cache.")
            }
            for snapshot in archive.snapshots { try Self.validate(snapshot) }
            for snapshot in archive.completeSnapshots { try Self.validate(snapshot) }
            cacheArchive = archive
            persistedTreeIDs = Self.treeIDs(in: archive)
        case let .failure(error): throw StorageServiceError.invalidData("Storage cache could not be loaded. Clear the cache: \(error)")
        }
    }

    private func writeCache(_ archive: StorageCacheArchive) async throws {
        try await cacheStore.write(archive)
        persistedTreeIDs = Self.treeIDs(in: archive)
    }

    private static func treeIDs(in archive: StorageCacheArchive) -> Set<UUID> {
        Set((archive.snapshots + archive.completeSnapshots).compactMap { $0.tree?.id })
    }

    private func resolve(_ id: UUID) async throws -> URL {
        try await loadGrants()
        guard let index = grantArchive!.entries.firstIndex(where: { $0.grant.id == id }) else {
            throw StorageServiceError.access("Select this folder again to restore access.")
        }
        let resolved = try resourceAccess.resolve(grantArchive!.entries[index].bookmark)
        let started = try resourceAccess.start(resolved.url)
        defer { if started { resourceAccess.stop(resolved.url) } }
        let root = resolved.url.standardizedFileURL.resolvingSymlinksInPath()
        let previous = grantArchive!.entries[index].grant
        let updated = StorageGrant(id: previous.id, path: root.path, name: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
        if resolved.stale || updated != previous {
            var candidate = grantArchive!
            candidate.entries[index].bookmark = try resourceAccess.bookmark(for: resolved.url)
            candidate.entries[index].grant = updated
            try await grantsStore.write(candidate)
            grantArchive = candidate
        }
        return resolved.url
    }

    private func validatedURL(item: StorageItemReference, snapshot: StorageSnapshot, root: URL, allowRoot: Bool) throws -> URL {
        var rootAncestor = URL(fileURLWithPath: "/")
        for component in root.pathComponents.dropFirst() {
            rootAncestor.appendPathComponent(component)
            let values = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                guard enabled else { throw StorageDatalessPolicyError.unavailable }
                return try rootAncestor.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey])
            }
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw StorageServiceError.unsafeItem("The selected root has an unsafe parent directory. Select it again.")
            }
            guard allowRoot || values.isPackage != true else {
                throw StorageServiceError.unsafeItem("Items inside a package cannot be moved to Trash separately. Select the whole package.")
            }
        }
        guard root.path == snapshot.authorizationRootPath,
              try StorageFileMetadata.identity(at: root) == snapshot.authorizationRootIdentity else {
            throw StorageServiceError.staleItem("The selected root has moved or been replaced. Scan it again.")
        }
        guard allowRoot || !item.relativePath.isEmpty else { throw StorageServiceError.unsafeItem("The selected scan root cannot be moved to Trash.") }
        let currentRelative = Self.relativePath(of: URL(fileURLWithPath: snapshot.rootPath), under: root)
        let proof = snapshot.rootAncestors
            + [StoragePathIdentity(relativePath: currentRelative, identity: snapshot.rootIdentity)]
            + item.ancestors.map { StoragePathIdentity(relativePath: Self.join(currentRelative, $0.relativePath), identity: $0.identity) }
        var expectedIdentities: [String: StorageFileIdentity] = [:]
        for ancestor in proof {
            if let existing = expectedIdentities[ancestor.relativePath], existing != ancestor.identity {
                throw StorageServiceError.invalidData("The scan contains conflicting parent identities.")
            }
            expectedIdentities[ancestor.relativePath] = ancestor.identity
        }
        var url = root
        var relative = ""
        let components = Self.join(currentRelative, item.relativePath).split(separator: "/").map(String.init)
        for component in components {
            let metadata = try StorageFileMetadata.read(at: url)
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw StorageServiceError.unsafeItem("A parent directory has become a symbolic link or is inaccessible. Scan again.")
            }
            guard let expected = expectedIdentities[relative], StorageFileMetadata.identity(metadata) == expected else {
                throw StorageServiceError.staleItem("A parent directory has been replaced or is missing from the scan. Scan again.")
            }
            if !allowRoot, try NativeStorageResourceReader().hints(at: url, isDirectory: true, mode: .volumeCatalog).isPackage {
                throw StorageServiceError.unsafeItem("Items inside a package cannot be moved to Trash separately. Select the whole package.")
            }
            url.appendPathComponent(component)
            relative = Self.join(relative, component)
        }
        guard try StorageFileMetadata.identity(at: url) == item.identity else {
            throw StorageServiceError.staleItem("The selected item has been replaced. Scan again before moving it to Trash.")
        }
        if !allowRoot {
            guard !item.isInsidePackage else { throw StorageServiceError.unsafeItem("Items inside a package cannot be moved to Trash separately. Select the whole package.") }
            guard let accountHome = userHomeDirectoryProvider()?.standardizedFileURL else {
                throw StorageServiceError.access("The account home directory could not be resolved. Storage cleanup is unavailable.")
            }
            let applicationHome = applicationHomeDirectoryProvider().standardizedFileURL
            let protectedHomes = [accountHome.path, accountHome.resolvingSymlinksInPath().path,
                applicationHome.path, applicationHome.resolvingSymlinksInPath().path]
            let protected = ["/System", "/Library", "/bin", "/sbin", "/usr", "/private", "/dev"]
            let treePaths = [treeDirectoryURL.standardizedFileURL.path, treeDirectoryURL.resolvingSymlinksInPath().path]
            guard url.path != "/", url.path != "/Volumes", !protected.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }),
                  !treePaths.contains(where: { Self.overlaps(URL(fileURLWithPath: $0), url) }),
                  !protectedHomes.contains(where: { $0 == url.path || $0.hasPrefix(url.path + "/") }) else {
                throw StorageServiceError.unsafeItem("This system or home directory is protected from storage cleanup.")
            }
        }
        return url
    }

    private func reader(for snapshot: StorageSnapshot) throws -> StorageTreeReader {
        try Self.validate(snapshot)
        guard let tree = snapshot.tree, tree.id == snapshot.id else {
            throw StorageServiceError.treeUnavailable
        }
        if let lease = treeReaders[tree.id] {
            let saved = lease.snapshot
            guard saved.grantID == snapshot.grantID, saved.rootPath == snapshot.rootPath,
                  saved.rootIdentity == snapshot.rootIdentity, saved.tree == snapshot.tree,
                  saved.authorizationRootPath == snapshot.authorizationRootPath,
                  saved.authorizationRootIdentity == snapshot.authorizationRootIdentity,
                  saved.rootAncestors == snapshot.rootAncestors, saved.nodes == snapshot.nodes,
                  saved.largestCatalog == snapshot.largestCatalog, saved.scanMethod == snapshot.scanMethod,
                  saved.scannedAt == snapshot.scannedAt, saved.issues == snapshot.issues,
                  saved.omittedIssueCount == snapshot.omittedIssueCount, saved.volume == snapshot.volume else {
                throw StorageServiceError.invalidData("The tree manifest differs from the active snapshot.")
            }
            return lease.reader
        }
        let reader = try StorageTreeReader(directoryURL: treeDirectoryURL, snapshot: snapshot)
        treeReaders[tree.id] = TreeLease(reader: reader, snapshot: snapshot)
        return reader
    }

    private func canonicalItem(id: Int, in snapshot: StorageSnapshot) async throws -> StorageItemReference? {
        try Self.validate(snapshot)
        if snapshot.tree != nil { return try await reader(for: snapshot).item(id: id) }
        return snapshot.itemReference(id: id)
    }

    private var storedTreeIDs: Set<UUID> {
        persistedTreeIDs.union(cacheArchive.map(Self.treeIDs(in:)) ?? [])
    }

    private func trimTreeBudget(_ archive: inout StorageCacheArchive, preserving newest: UUID) {
        func size(_ snapshot: StorageSnapshot) -> UInt64 {
            guard let tree = snapshot.tree else { return 0 }
            let url = StorageTreeReader.indexURL(directoryURL: treeDirectoryURL, id: tree.id)
            let value = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return UInt64(max(0, value))
        }
        func exceedsBudget() -> Bool {
            var bytes: UInt64 = 0
            for snapshot in archive.snapshots + archive.completeSnapshots {
                let sum = bytes.addingReportingOverflow(size(snapshot))
                if sum.overflow || sum.partialValue > maximumTreeBytes { return true }
                bytes = sum.partialValue
            }
            return false
        }
        while exceedsBudget() {
            if let index = archive.completeSnapshots.indices.reversed().first(where: {
                let snapshot = archive.completeSnapshots[$0]
                return snapshot.tree != nil && snapshot.id != newest && treeReaders[snapshot.id] == nil
            }) { archive.completeSnapshots.remove(at: index); continue }
            if let index = archive.snapshots.indices.reversed().first(where: {
                let snapshot = archive.snapshots[$0]
                return snapshot.tree != nil && snapshot.id != newest && treeReaders[snapshot.id] == nil
            }) {
                let removed = archive.snapshots.remove(at: index)
                archive.completeSnapshots.removeAll { $0.grantID == removed.grantID }
                continue
            }
            // Active/latest indices take priority over the soft whole-generation budget.
            break
        }
    }

    private func cleanupAfterScan() {
        guard activeTreeScans == 0, cacheArchive != nil else { return }
        do { try cleanupTreeIndices() }
        catch { diagnostics?.record("tree.cleanupFailed", scanID: "cleanup", details: ["error": String(describing: error)]) }
    }

    private func cleanupTreeIndices() throws {
        // Publication hands a completed UUID to the service before its first reader opens.
        // Do not sweep that handoff interval while another scan is still in flight.
        guard activeTreeScans == 0, cacheArchive != nil,
              FileManager.default.fileExists(atPath: treeDirectoryURL.path) else { return }
        var metadata = stat()
        guard lstat(treeDirectoryURL.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw StorageServiceError.invalidData("The storage tree directory is not a safe local directory.")
        }
        let retained = storedTreeIDs.union(treeReaders.keys)
        let files = try FileManager.default.contentsOfDirectory(at: treeDirectoryURL, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "sqlite" {
            let building = file.deletingPathExtension().pathExtension == "building"
            let name = building ? file.deletingPathExtension().deletingPathExtension().lastPathComponent
                : file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name),
                  file.lastPathComponent == StorageTreeReader.indexURL(directoryURL: treeDirectoryURL, id: id, building: building).lastPathComponent,
                  building || !retained.contains(id) else { continue }
            do { _ = try StorageTreeReader.removeIfUnused(directoryURL: treeDirectoryURL, id: id, building: building) }
            catch StorageTreeIndexError.invalid(_) { continue } // Foreign or malformed files are never disposal authority.
        }
    }

    private static func overlaps(_ left: URL, _ right: URL) -> Bool {
        let a = left.standardizedFileURL.path
        let b = right.standardizedFileURL.path
        return a == b || a == "/" || b == "/" || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private static func join(_ prefix: String, _ suffix: String) -> String {
        if prefix.isEmpty { return suffix }
        if suffix.isEmpty { return prefix }
        return prefix + "/" + suffix
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        if url.path == root.path { return "" }
        return String(url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
    }

    private static func validate(_ snapshot: StorageSnapshot) throws {
        try snapshot.validate()
    }

    // Only short archive transactions hold this gate; native scanning remains cancellable and concurrent.
    private func acquireMutation() async {
        if !mutationActive { mutationActive = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty { mutationActive = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    private func scanContext(for id: UUID, beginsScan: Bool = false) async throws -> (URL, UInt64, UInt64) {
        await acquireMutation()
        defer { releaseMutation() }
        let root = try await resolve(id)
        if beginsScan { scanVersions[id, default: 0] &+= 1 }
        return (root, cacheGeneration, scanVersions[id, default: 0])
    }
}

private func legacyStorageTreePage(parentID: Int, snapshot: StorageSnapshot, metric: StorageSizeMetric,
                                   descending: Bool, offset: Int, limit: Int) throws -> StorageTreePage {
    try snapshot.validate()
    guard snapshot.schemaVersion == 1 else {
        throw StorageServiceError.treeUnavailable
    }
    guard offset >= 0, limit > 0, let parent = snapshot.node(id: parentID), parent.kind == .directory else {
        throw StorageServiceError.invalidData("Invalid tree parent or page range.")
    }
    let children = snapshot.nodes.filter { $0.parentID == parentID }.sorted {
        let left = $0.bytes(for: metric), right = $1.bytes(for: metric)
        if left != right { return descending ? left > right : left < right }
        return $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
    }
    let start = min(offset, children.count)
    let rows = children.dropFirst(start).prefix(min(limit, 1_000)).map { node in
        StorageTreeRow(id: node.id, parentID: node.parentID, name: node.name, kind: node.kind,
            totals: StorageTotals(logicalBytes: node.logicalBytes, allocatedBytes: node.allocatedBytes,
                apparentBytes: node.apparentBytes, fileCount: node.fileCount),
            childCount: snapshot.nodes.filter { $0.parentID == node.id }.count,
            isCloudPlaceholder: node.isCloudPlaceholder, isHardLinkDuplicate: node.isHardLinkDuplicate,
            isIncomplete: node.isIncomplete)
    }
    return StorageTreePage(rows: rows, offset: offset, totalCount: children.count)
}
