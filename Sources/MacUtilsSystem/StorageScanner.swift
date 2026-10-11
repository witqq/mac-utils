import Darwin
import Foundation
import MacUtilsCore

public enum StorageScannerError: Error, Sendable, CustomStringConvertible {
    case rootNotDirectory
    case sizeOverflow(String)
    public var description: String {
        switch self {
        case .rootNotDirectory: "Select a directory or a mounted volume to scan."
        case let .sizeOverflow(path): "Storage sizes exceed the supported byte range at \(path). Scan a smaller folder."
        }
    }
}

enum StorageFileMetadata {
    static func identity(_ metadata: stat) -> StorageFileIdentity {
        StorageFileIdentity(device: UInt64(UInt32(bitPattern: metadata.st_dev)), inode: UInt64(metadata.st_ino),
            birthSeconds: Int64(metadata.st_birthtimespec.tv_sec), birthNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec))
    }
    static func read(at url: URL) throws -> stat {
        try StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            var value = stat()
            guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return value
        }
    }
    static func identity(at url: URL) throws -> StorageFileIdentity { identity(try read(at: url)) }
}

struct StorageResourceHints: Sendable {
    var isPackage = false
    var isCloudPlaceholder = false
    var isVolumeRoot = false
}
enum StorageResourceHintMode {
    case directoryTraversal
    /// Catalog mode classifies cloud placeholders from native SF_DATALESS and blocked
    /// metadata I/O (EDEADLK). It does not query legacy ubiquitous downloading status.
    case volumeCatalog
}
protocol StorageResourceReading: Sendable {
    func hints(at url: URL) throws -> StorageResourceHints
    func hints(at url: URL, isDirectory: Bool) throws -> StorageResourceHints
    func hints(at url: URL, isDirectory: Bool, mode: StorageResourceHintMode) throws -> StorageResourceHints
    func metadata(in directoryFD: CInt, name: String) throws -> stat
}
extension StorageResourceReading {
    func hints(at url: URL, isDirectory: Bool) throws -> StorageResourceHints { try hints(at: url) }
    func hints(at url: URL, isDirectory: Bool, mode: StorageResourceHintMode) throws -> StorageResourceHints {
        try hints(at: url, isDirectory: isDirectory)
    }
    func metadata(in directoryFD: CInt, name: String) throws -> stat {
        try StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            var metadata = stat()
            guard fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return metadata
        }
    }
}
struct NativeStorageResourceReader: StorageResourceReading {
    func hints(at url: URL) throws -> StorageResourceHints {
        try hints(at: url, isDirectory: true)
    }
    func hints(at url: URL, isDirectory: Bool) throws -> StorageResourceHints {
        try hints(at: url, isDirectory: isDirectory, mode: .directoryTraversal)
    }
    func hints(at url: URL, isDirectory: Bool, mode: StorageResourceHintMode) throws -> StorageResourceHints {
        // Download status is meaningful only for ubiquitous resources. Avoid asking the
        // cloud provider for it on every ordinary local file, while preserving its semantics.
        var keys: Set<URLResourceKey> = mode == .directoryTraversal ? [.isUbiquitousItemKey] : []
        if isDirectory { keys.formUnion([.isPackageKey, .isVolumeKey]) }
        return try autoreleasepool {
            try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                guard enabled else { throw StorageDatalessPolicyError.unavailable }
                let values = try url.resourceValues(forKeys: keys)
                var cloud = false
                if mode == .directoryTraversal && values.isUbiquitousItem == true {
                    cloud = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus == .notDownloaded
                }
                return StorageResourceHints(isPackage: values.isPackage ?? false,
                    isCloudPlaceholder: cloud, isVolumeRoot: values.isVolume ?? false)
            }
        }
    }
}

/// Streams all readable metadata. Retention limits bound the overview, never stop traversal.
/// Exact hard-link deduplication additionally retains O(multiply-linked identities) state.
public actor StorageScanner {
    private let maximumNodes: Int
    private let maximumIssues: Int
    private let largestLimit: Int
    private let resourceReader: any StorageResourceReading
    private let treeDirectory: URL?
    public init(maximumNodes: Int = 1_001, maximumIssues: Int = 1_000, largestLimit: Int = 200, treeDirectory: URL? = nil) {
        self.maximumNodes = max(1, maximumNodes); self.maximumIssues = max(1, maximumIssues)
        self.largestLimit = max(0, largestLimit); resourceReader = NativeStorageResourceReader()
        self.treeDirectory = treeDirectory
    }
    init(maximumNodes: Int = 1_001, maximumIssues: Int = 1_000, largestLimit: Int = 200,
         resourceReader: any StorageResourceReading, treeDirectory: URL? = nil) {
        self.maximumNodes = max(1, maximumNodes); self.maximumIssues = max(1, maximumIssues)
        self.largestLimit = max(0, largestLimit); self.resourceReader = resourceReader
        self.treeDirectory = treeDirectory
    }

    public func scan(rootURL: URL, grantID: UUID, authorizationRootPath: String? = nil,
                     authorizationRootIdentity: StorageFileIdentity? = nil, rootAncestors: [StoragePathIdentity] = [],
                     progress: @escaping @Sendable (StorageScanProgress) async -> Void = { _ in }) async throws -> StorageSnapshot {
        try Task.checkCancellation()
        let rootURL = rootURL.standardizedFileURL
        let rootMetadata = try StorageFileMetadata.read(at: rootURL)
        guard rootMetadata.st_mode & S_IFMT == S_IFDIR else { throw StorageScannerError.rootNotDirectory }
        if resourceReader is NativeStorageResourceReader, rootMetadata.st_flags & UInt32(SF_DATALESS) == 0 {
            do {
                // Planning queries volume properties and live firmlink metadata. Keep the
                // entire synchronous operation protected, including intermediate folders.
                let plans = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                    guard enabled else { throw StorageDatalessPolicyError.unavailable }
                    return try autoreleasepool { try StorageCatalogVolumePlan.plans(for: rootURL) }
                }
                return try await StorageCatalogScanner(maximumNodes: maximumNodes, largestLimit: largestLimit,
                    maximumIssues: maximumIssues, resourceReader: resourceReader, treeDirectory: treeDirectory).scan(rootURL: rootURL,
                        grantID: grantID, plans: plans, authorizationRootPath: authorizationRootPath,
                        authorizationRootIdentity: authorizationRootIdentity, rootAncestors: rootAncestors,
                        progress: progress)
            } catch StorageCatalogVolumePlanError.unsupported {
                // Ordinary folders and other filesystem formats retain directory traversal.
            } catch StorageCatalogReaderError.unsupported {
                // An explicitly unsupported catalog API retains directory traversal.
            }
            // Other catalog failures propagate: a changed catalog or invalid namespace
            // must not silently start a different scan with weaker historical evidence.
        }
        let rootHints = rootMetadata.st_flags & UInt32(SF_DATALESS) != 0 ? StorageResourceHints(isCloudPlaceholder: true)
            : try resourceReader.hints(at: rootURL)
        let rootIdentity = StorageFileMetadata.identity(rootMetadata)
        let root = ScanItem(name: rootURL.lastPathComponent.isEmpty ? "/" : rootURL.lastPathComponent,
            relativePath: "", kind: rootHints.isPackage ? .package : .directory, identity: rootIdentity, ancestors: [])
        let writer = try treeDirectory.map { try StorageTreeWriter(directoryURL: $0, snapshotID: UUID(),
            grantID: grantID, rootURL: rootURL, rootIdentity: rootIdentity, rootKind: root.kind,
            rootCloud: rootHints.isCloudPlaceholder) }
        root.treeID = writer == nil ? nil : 0
        defer { writer?.abort() }
        guard writer?.excludes(url: rootURL, identity: rootIdentity) != true else {
            throw StorageTreeIndexError.invalid("The analysis cache itself cannot be scanned")
        }
        var issues: [StorageScanIssue] = []
        var omittedIssues = 0
        var stack: [DirectoryFrame] = []
        var overview = DualTopItems(limit: maximumNodes - 1)
        var largest = DualTopItems(limitPerMetric: largestLimit)
        var linkedFiles: Set<StorageFileIdentity> = []
        var visited = 0
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        let clock = ContinuousClock()
        var lastProgress = clock.now
        var cacheReported = false
        func issue(_ path: String, _ reason: StorageScanIssueReason, _ message: String, item: ScanItem) {
            item.isIncomplete = true
            if issues.count < maximumIssues { issues.append(StorageScanIssue(path: path, reason: reason, message: message)) }
            else { omittedIssues += 1 }
        }
        await progress(StorageScanProgress(visitedItems: 0, currentPath: rootURL.path, logicalBytes: 0, allocatedBytes: 0))
        if rootMetadata.st_flags & UInt32(SF_DATALESS) != 0 || rootHints.isCloudPlaceholder {
            root.isCloudPlaceholder = true
            issue("", .cloudPlaceholderDirectory, "Cloud-only folder contents were not downloaded or enumerated", item: root)
        } else {
            let fd = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                guard enabled else { throw StorageDatalessPolicyError.unavailable }
                return open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var actual = stat()
            let rootStatus: CInt
            do {
                rootStatus = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                    guard enabled else { throw StorageDatalessPolicyError.unavailable }
                    return fstat(fd, &actual)
                }
            } catch { close(fd); throw error }
            guard rootStatus == 0, StorageFileMetadata.identity(actual) == rootIdentity else {
                close(fd); throw CocoaError(.fileReadUnknown)
            }
            let directory = try StorageDirectoryReader(descriptor: fd, bulk: resourceReader is NativeStorageResourceReader)
            stack.append(DirectoryFrame(directory: directory, item: root, isOpaque: root.kind == .package))
        }
        while let frame = stack.last {
            try Task.checkCancellation()
            let entry: (name: String, metadata: stat?)?
            do { entry = try frame.directory.next() }
            catch {
                issue(frame.item.relativePath, (error as? POSIXError)?.code == .EDEADLK ? .cloudPlaceholderDirectory : .unreadable,
                    String(describing: error), item: frame.item)
                entry = nil
            }
            guard let entry else {
                if frame.item.isIncomplete, let writer, let id = try writer.directoryID(relativePath: frame.item.relativePath) {
                    try writer.markIncomplete(directoryID: id)
                }
                stack.removeLast()
                if let parent = stack.last {
                    try parent.item.add(frame.item.totals)
                    parent.item.isIncomplete = parent.item.isIncomplete || frame.item.isIncomplete
                    if writer == nil && stack.count == 1 && !parent.isOpaque { overview.insert(frame.item.reference()) }
                    if writer == nil && frame.item.kind == .package && !parent.isOpaque { largest.insert(frame.item.reference()) }
                }
                continue
            }
            let name = entry.name
            if name == "." || name == ".." { continue }
            visited += 1
            let relative = frame.item.relativePath.isEmpty ? name : frame.item.relativePath + "/" + name
            let itemURL = rootURL.appending(path: relative)
            if clock.now - lastProgress >= .milliseconds(120) {
                await progress(StorageScanProgress(visitedItems: visited, currentPath: itemURL.path, logicalBytes: logical, allocatedBytes: allocated))
                lastProgress = clock.now; try Task.checkCancellation()
            }
            let metadata: stat
            do {
                if let batched = entry.metadata { metadata = batched }
                else { metadata = try resourceReader.metadata(in: frame.directory.descriptor, name: name) }
            }
            catch {
                let code = (error as? POSIXError)?.code
                issue(relative, code == .EACCES || code == .EPERM ? .permissionDenied : .unreadable,
                    String(describing: error), item: frame.item)
                continue
            }
            let type = metadata.st_mode & S_IFMT
            let identity = StorageFileMetadata.identity(metadata)
            if writer?.excludes(url: itemURL, identity: identity) == true {
                if !cacheReported {
                    issue(relative, .analysisCache, "This utility's analysis indexes were excluded", item: root)
                    cacheReported = true
                }
                continue
            }
            if identity.device != rootIdentity.device {
                issue(relative, .mountBoundary, "Another mounted filesystem was not scanned", item: frame.item); continue
            }
            var hints = StorageResourceHints()
            var hintsAvailable = true
            if metadata.st_flags & UInt32(SF_DATALESS) != 0 { hints.isCloudPlaceholder = true }
            else if type != S_IFLNK {
                do { hints = try resourceReader.hints(at: itemURL, isDirectory: type == S_IFDIR) }
                catch { hintsAvailable = false; issue(relative, .unreadable, String(describing: error), item: frame.item) }
            }
            // APFS volume-group mounts can share st_dev with the visible firmlink paths.
            if type == S_IFDIR && hints.isVolumeRoot {
                issue(relative, .mountBoundary, "Another mounted volume root was not scanned", item: frame.item); continue
            }
            let cloud = metadata.st_flags & UInt32(SF_DATALESS) != 0 || hints.isCloudPlaceholder
            let kind: StorageNodeKind = type == S_IFDIR ? (hints.isPackage ? .package : .directory)
                : type == S_IFREG ? .file : type == S_IFLNK ? .symbolicLink : .other
            let needsProof = writer == nil && (stack.count == 1 || kind == .package || (kind == .file && !frame.isOpaque))
            let ancestors = needsProof ? stack.map { StoragePathIdentity(relativePath: $0.item.relativePath, identity: $0.item.identity) } : []
            let item = ScanItem(name: name, relativePath: relative, kind: kind, identity: identity, ancestors: ancestors)
            item.isCloudPlaceholder = cloud
            let parentTreeID = frame.item.treeID
            if writer != nil && parentTreeID == nil { throw StorageTreeIndexError.invalid("Missing scanned parent") }
            frame.item.childCount += 1
            if type == S_IFDIR {
                if let writer, let parentTreeID {
                    item.treeID = try writer.ensureDirectory(name: name, relativePath: relative, parentID: parentTreeID,
                        identity: identity, kind: kind, isCloudPlaceholder: cloud, isIncomplete: !hintsAvailable || cloud)
                }
                var directory: StorageDirectoryReader?
                if !hintsAvailable { item.isIncomplete = true }
                else if cloud { issue(relative, .cloudPlaceholderDirectory, "Cloud-only folder contents were not downloaded or enumerated", item: item) }
                else {
                    let fd = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                        guard enabled else { throw StorageDatalessPolicyError.unavailable }
                        return openat(frame.directory.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    if fd < 0 {
                        let failure = errno
                        issue(relative, failure == EACCES || failure == EPERM ? .permissionDenied : .unreadable,
                            String(cString: strerror(failure)), item: item)
                    } else {
                        var opened = stat()
                        let status: CInt
                        do {
                            status = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                                guard enabled else { throw StorageDatalessPolicyError.unavailable }
                                return fstat(fd, &opened)
                            }
                        } catch { close(fd); throw error }
                        if status != 0 || StorageFileMetadata.identity(opened) != identity {
                            close(fd); issue(relative, .changedDuringScan, "The directory changed while it was being scanned", item: item)
                        } else {
                            do { directory = try StorageDirectoryReader(descriptor: fd, bulk: resourceReader is NativeStorageResourceReader) }
                            catch { issue(relative, .unreadable, String(describing: error), item: item) }
                        }
                    }
                }
                if let directory {
                    stack.append(DirectoryFrame(directory: directory, item: item, isOpaque: frame.isOpaque || kind == .package))
                    continue
                }
            } else if type == S_IFREG || type == S_IFLNK {
                let apparent = UInt64(max(0, metadata.st_size))
                let duplicate = type == S_IFREG && metadata.st_nlink > 1 && !linkedFiles.insert(identity).inserted
                let allocation = UInt64(max(0, metadata.st_blocks)).multipliedReportingOverflow(by: 512)
                guard !allocation.overflow else { throw StorageScannerError.sizeOverflow(relative) }
                item.totals = StorageTotals(logicalBytes: duplicate ? 0 : apparent, allocatedBytes: duplicate ? 0 : allocation.partialValue,
                    apparentBytes: apparent, fileCount: type == S_IFREG ? 1 : 0)
                item.isHardLinkDuplicate = duplicate
                logical = try Self.add(logical, item.totals.logicalBytes, path: relative)
                allocated = try Self.add(allocated, item.totals.allocatedBytes, path: relative)
            }
            try frame.item.add(item.totals)
            frame.item.isIncomplete = frame.item.isIncomplete || item.isIncomplete
            if let writer, let parentTreeID, type != S_IFDIR {
                _ = try writer.appendLeaf(name: name, parentID: parentTreeID, kind: kind, identity: identity,
                    totals: item.totals, isCloudPlaceholder: cloud, isHardLinkDuplicate: item.isHardLinkDuplicate,
                    isIncomplete: item.isIncomplete, isInsidePackage: frame.isOpaque)
            }
            if item.isIncomplete, let writer, let id = try writer.directoryID(relativePath: relative) {
                try writer.markIncomplete(directoryID: id)
            }
            if writer == nil && stack.count == 1 && !frame.isOpaque { overview.insert(item.reference()) }
            if writer == nil && !frame.isOpaque && (kind == .file || kind == .package) { largest.insert(item.reference()) }
        }
        try Task.checkCancellation()
        if writer != nil {
            await progress(StorageScanProgress(visitedItems: visited, currentPath: rootURL.path,
                logicalBytes: logical, allocatedBytes: allocated, phase: .validatingResults))
            try Task.checkCancellation()
        }
        let snapshot = try StorageSnapshotBuilder.build(rootURL: rootURL, grantID: grantID, root: root,
            overview: overview.values, largest: largest.values, issues: issues, omittedIssues: omittedIssues,
            authorizationRootPath: authorizationRootPath, authorizationRootIdentity: authorizationRootIdentity,
            rootAncestors: rootAncestors, treeWriter: writer, maximumNodes: maximumNodes, largestLimit: largestLimit)
        await progress(StorageScanProgress(visitedItems: visited, currentPath: rootURL.path, logicalBytes: logical, allocatedBytes: allocated))
        try Task.checkCancellation()
        writer?.completeHandoff()
        return snapshot
    }
    static func add(_ left: UInt64, _ right: UInt64, path: String) throws -> UInt64 {
        let sum = left.addingReportingOverflow(right)
        guard !sum.overflow else { throw StorageScannerError.sizeOverflow(path) }
        return sum.partialValue
    }
    static func sum(_ left: StorageTotals, _ right: StorageTotals, path: String) throws -> StorageTotals {
        let files = left.fileCount.addingReportingOverflow(right.fileCount)
        guard !files.overflow else { throw StorageScannerError.sizeOverflow(path) }
        return StorageTotals(logicalBytes: try add(left.logicalBytes, right.logicalBytes, path: path),
            allocatedBytes: try add(left.allocatedBytes, right.allocatedBytes, path: path),
            apparentBytes: try add(left.apparentBytes, right.apparentBytes, path: path), fileCount: files.partialValue)
    }
}

private struct DirectoryFrame {
    let directory: StorageDirectoryReader
    let item: ScanItem
    let isOpaque: Bool
}
final class ScanItem {
    let name: String
    let relativePath: String
    let kind: StorageNodeKind
    let identity: StorageFileIdentity
    let ancestors: [StoragePathIdentity]
    var totals = StorageTotals.zero
    var childCount = 0
    var isCloudPlaceholder = false
    var isHardLinkDuplicate = false
    var isIncomplete = false
    var treeID: Int?
    init(name: String, relativePath: String, kind: StorageNodeKind, identity: StorageFileIdentity, ancestors: [StoragePathIdentity]) {
        self.name = name; self.relativePath = relativePath; self.kind = kind; self.identity = identity; self.ancestors = ancestors
    }
    func add(_ contribution: StorageTotals) throws { totals = try StorageScanner.sum(totals, contribution, path: relativePath) }
    func reference() -> StorageItemReference {
        StorageItemReference(id: 0, name: name, relativePath: relativePath, kind: kind, identity: identity,
            totals: totals, ancestors: ancestors, isCloudPlaceholder: isCloudPlaceholder,
            isHardLinkDuplicate: isHardLinkDuplicate, isIncomplete: isIncomplete,
            unlistedChildCount: kind == .directory ? childCount : 0)
    }
    func node(id: Int, parentID: Int?, unlisted: StorageTotals, childCount: Int) -> StorageNode {
        StorageNode(id: id, parentID: parentID, name: name, relativePath: relativePath, kind: kind, identity: identity,
            logicalBytes: totals.logicalBytes, allocatedBytes: totals.allocatedBytes, apparentBytes: totals.apparentBytes,
            fileCount: totals.fileCount, isCloudPlaceholder: isCloudPlaceholder, isHardLinkDuplicate: isHardLinkDuplicate,
            isIncomplete: isIncomplete, unlistedChildren: unlisted, unlistedChildCount: childCount)
    }
}

/// The least useful retained candidate is the heap root; each insertion costs O(log limit).
struct TopItems {
    let limit: Int
    let metric: StorageSizeMetric
    var items: [StorageItemReference] = []
    func better(_ a: StorageItemReference, _ b: StorageItemReference) -> Bool {
        a.bytes(for: metric) == b.bytes(for: metric) ? a.relativePath < b.relativePath : a.bytes(for: metric) > b.bytes(for: metric)
    }
    mutating func insert(_ item: StorageItemReference) {
        guard limit > 0 else { return }
        if items.count < limit {
            items.append(item)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard better(items[parent], items[child]) else { break }
                items.swapAt(parent, child); child = parent
            }
        } else if better(item, items[0]) {
            items[0] = item
            var parent = 0
            while parent * 2 + 1 < items.count {
                var child = parent * 2 + 1
                if child + 1 < items.count && better(items[child], items[child + 1]) { child += 1 }
                guard better(items[parent], items[child]) else { break }
                items.swapAt(parent, child); parent = child
            }
        }
    }
}
struct DualTopItems {
    var logical: TopItems
    var allocated: TopItems
    init(limit: Int) {
        logical = TopItems(limit: (limit + 1) / 2, metric: .logical)
        allocated = TopItems(limit: limit / 2, metric: .allocated)
    }
    init(limitPerMetric: Int) {
        logical = TopItems(limit: limitPerMetric, metric: .logical)
        allocated = TopItems(limit: limitPerMetric, metric: .allocated)
    }
    mutating func insert(_ item: StorageItemReference) { logical.insert(item); allocated.insert(item) }
    var values: [StorageItemReference] {
        Array(Dictionary((logical.items + allocated.items).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first }).values)
    }
}
