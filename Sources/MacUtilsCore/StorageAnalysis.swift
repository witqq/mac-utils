import Foundation

public enum StorageSizeMetric: String, Codable, CaseIterable, Sendable {
    case logical
    case allocated
}

/// Device/inode and creation time survive snapshot serialization without opaque Foundation objects.
public struct StorageFileIdentity: Hashable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64

    public init(device: UInt64, inode: UInt64, birthSeconds: Int64, birthNanoseconds: Int64) {
        self.device = device
        self.inode = inode
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
    }
}

public enum StorageNodeKind: String, Codable, Sendable {
    case directory
    case file
    case package
    case symbolicLink
    case other
}

public struct StorageTotals: Hashable, Codable, Sendable {
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let apparentBytes: UInt64
    public let fileCount: Int
    public static let zero = StorageTotals(logicalBytes: 0, allocatedBytes: 0, apparentBytes: 0, fileCount: 0)
    public init(logicalBytes: UInt64, allocatedBytes: UInt64, apparentBytes: UInt64, fileCount: Int) {
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes
        self.apparentBytes = apparentBytes; self.fileCount = fileCount
    }
}

public struct StoragePathIdentity: Hashable, Codable, Sendable {
    public let relativePath: String
    public let identity: StorageFileIdentity
    public init(relativePath: String, identity: StorageFileIdentity) {
        self.relativePath = relativePath; self.identity = identity
    }
}

/// An actionable catalog item carries every ancestor identity even when its hierarchy is condensed.
public struct StorageItemReference: Identifiable, Hashable, Codable, Sendable {
    public let id: Int
    public let name: String
    public let relativePath: String
    public let kind: StorageNodeKind
    public let identity: StorageFileIdentity
    public let totals: StorageTotals
    public let ancestors: [StoragePathIdentity]
    public let isCloudPlaceholder: Bool
    public let isHardLinkDuplicate: Bool
    public let isIncomplete: Bool
    public let unlistedChildCount: Int
    private let savedInsidePackage: Bool?
    public var isInsidePackage: Bool { savedInsidePackage ?? false }
    public var logicalBytes: UInt64 { totals.logicalBytes }
    public var allocatedBytes: UInt64 { totals.allocatedBytes }
    public var apparentBytes: UInt64 { totals.apparentBytes }
    public var fileCount: Int { totals.fileCount }
    public init(id: Int, name: String, relativePath: String, kind: StorageNodeKind,
                identity: StorageFileIdentity, totals: StorageTotals, ancestors: [StoragePathIdentity],
                isCloudPlaceholder: Bool = false, isHardLinkDuplicate: Bool = false, isIncomplete: Bool = false,
                unlistedChildCount: Int = 0, isInsidePackage: Bool = false) {
        self.id = id; self.name = name; self.relativePath = relativePath; self.kind = kind
        self.identity = identity; self.totals = totals; self.ancestors = ancestors
        self.isCloudPlaceholder = isCloudPlaceholder; self.isHardLinkDuplicate = isHardLinkDuplicate
        self.isIncomplete = isIncomplete
        self.unlistedChildCount = unlistedChildCount
        savedInsidePackage = isInsidePackage ? true : nil
    }
    public func bytes(for metric: StorageSizeMetric) -> UInt64 { metric == .logical ? logicalBytes : allocatedBytes }
}

public struct StorageNode: Identifiable, Hashable, Codable, Sendable {
    public let id: Int
    public let parentID: Int?
    public let name: String
    public let relativePath: String
    public let kind: StorageNodeKind
    public let identity: StorageFileIdentity
    /// Subtree totals count each hard-linked inode once within the selected root.
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    /// Logical size before hard-link deduplication, including opaque package contents.
    public let apparentBytes: UInt64
    public let fileCount: Int
    public let isCloudPlaceholder: Bool
    public let isHardLinkDuplicate: Bool
    public let isIncomplete: Bool
    private let unlistedTotals: StorageTotals?
    private let unlistedCount: Int?
    public var unlistedChildren: StorageTotals { unlistedTotals ?? .zero }
    public var unlistedChildCount: Int { unlistedCount ?? 0 }

    public init(id: Int, parentID: Int?, name: String, relativePath: String, kind: StorageNodeKind,
                identity: StorageFileIdentity, logicalBytes: UInt64, allocatedBytes: UInt64,
                apparentBytes: UInt64, fileCount: Int, isCloudPlaceholder: Bool = false,
                isHardLinkDuplicate: Bool = false, isIncomplete: Bool = false,
                unlistedChildren: StorageTotals = .zero, unlistedChildCount: Int = 0) {
        self.id = id; self.parentID = parentID; self.name = name; self.relativePath = relativePath
        self.kind = kind; self.identity = identity; self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes; self.apparentBytes = apparentBytes; self.fileCount = fileCount
        self.isCloudPlaceholder = isCloudPlaceholder; self.isHardLinkDuplicate = isHardLinkDuplicate
        self.isIncomplete = isIncomplete
        unlistedTotals = unlistedChildren; unlistedCount = unlistedChildCount
    }

    public func bytes(for metric: StorageSizeMetric) -> UInt64 {
        metric == .logical ? logicalBytes : allocatedBytes
    }
}

public enum StorageScanIssueReason: String, Codable, Sendable {
    case permissionDenied
    case unreadable
    case mountBoundary
    case cloudPlaceholderDirectory
    case changedDuringScan
    case limitReached
    case analysisCache
}

public struct StorageScanIssue: Hashable, Codable, Sendable {
    public let path: String
    public let reason: StorageScanIssueReason
    public let message: String
    public init(path: String, reason: StorageScanIssueReason, message: String) {
        self.path = path; self.reason = reason; self.message = message
    }
}

public struct StorageVolumeCapacity: Hashable, Codable, Sendable {
    public let totalBytes: UInt64?
    public let availableBytes: UInt64?
    public let availableForImportantUsageBytes: UInt64?
    public init(totalBytes: UInt64?, availableBytes: UInt64?, availableForImportantUsageBytes: UInt64?) {
        self.totalBytes = totalBytes; self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
    }
}

public enum StorageScanPhase: String, Sendable {
    case directoryTraversal
    case volumeCatalog
    case validatingResults
}

public enum StorageScanMethod: String, Codable, Sendable {
    case directoryTraversal
    case volumeCatalog
}

public struct StorageScanProgress: Hashable, Sendable {
    public let visitedItems: Int
    public let currentPath: String
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let phase: StorageScanPhase
    public let estimatedTotalItems: Int?
    public init(visitedItems: Int, currentPath: String, logicalBytes: UInt64, allocatedBytes: UInt64,
                phase: StorageScanPhase = .directoryTraversal, estimatedTotalItems: Int? = nil) {
        self.visitedItems = visitedItems; self.currentPath = currentPath
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes
        self.phase = phase; self.estimatedTotalItems = estimatedTotalItems
    }
}

public enum StorageSnapshotValidationError: Error, Sendable {
    case unsupportedSchema
    case invalidRoot
    case invalidNode(Int)
    case invalidTotals(Int)
}

/// The manifest names an immutable app-owned index, never an arbitrary filesystem path.
public struct StorageTreeDescriptor: Hashable, Codable, Sendable {
    public let id: UUID
    public let formatVersion: Int
    /// Stored ID slots, including format-2 tombstones; surviving IDs are never renumbered.
    public let nodeCount: Int
    public let rootChildCount: Int

    public init(id: UUID, formatVersion: Int = 1, nodeCount: Int, rootChildCount: Int) {
        self.id = id; self.formatVersion = formatVersion
        self.nodeCount = nodeCount; self.rootChildCount = rootChildCount
    }
}

/// Child pages carry no duplicated paths or ancestor arrays for unselected rows.
public struct StorageTreeRow: Identifiable, Hashable, Sendable {
    public let id: Int
    public let parentID: Int?
    public let name: String
    public let kind: StorageNodeKind
    public let totals: StorageTotals
    public let childCount: Int
    public let isCloudPlaceholder: Bool
    public let isHardLinkDuplicate: Bool
    public let isIncomplete: Bool
    public let isInsidePackage: Bool

    public init(id: Int, parentID: Int?, name: String, kind: StorageNodeKind,
                totals: StorageTotals, childCount: Int, isCloudPlaceholder: Bool = false,
                isHardLinkDuplicate: Bool = false, isIncomplete: Bool = false, isInsidePackage: Bool = false) {
        self.id = id; self.parentID = parentID; self.name = name; self.kind = kind
        self.totals = totals; self.childCount = childCount
        self.isCloudPlaceholder = isCloudPlaceholder; self.isHardLinkDuplicate = isHardLinkDuplicate
        self.isIncomplete = isIncomplete; self.isInsidePackage = isInsidePackage
    }

    public var isExpandable: Bool {
        childCount > 0 && !isCloudPlaceholder && (kind == .directory || kind == .package)
    }
    public func bytes(for metric: StorageSizeMetric) -> UInt64 {
        metric == .logical ? totals.logicalBytes : totals.allocatedBytes
    }
}

public struct StorageTreePage: Sendable {
    public let rows: [StorageTreeRow]
    public let offset: Int
    public let totalCount: Int
    public var hasMore: Bool { offset >= 0 && offset < totalCount && rows.count < totalCount - offset }

    public init(rows: [StorageTreeRow], offset: Int, totalCount: Int) {
        self.rows = rows; self.offset = offset; self.totalCount = totalCount
    }
}

/// Legacy trees use flat parent indices; schema 3 keeps a bounded summary and an index descriptor.
public struct StorageSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let grantID: UUID
    public let rootPath: String
    public let rootIdentity: StorageFileIdentity
    public let scannedAt: Date
    public let nodes: [StorageNode]
    public let issues: [StorageScanIssue]
    public let omittedIssueCount: Int
    public let volume: StorageVolumeCapacity?
    public let tree: StorageTreeDescriptor?
    private let savedLargestCatalog: [StorageItemReference]?
    private let savedAuthorizationRootPath: String?
    private let savedAuthorizationRootIdentity: StorageFileIdentity?
    private let savedRootAncestors: [StoragePathIdentity]?
    private let savedScanMethod: StorageScanMethod?
    public var largestCatalog: [StorageItemReference] { savedLargestCatalog ?? [] }
    public var authorizationRootPath: String { savedAuthorizationRootPath ?? rootPath }
    public var authorizationRootIdentity: StorageFileIdentity { savedAuthorizationRootIdentity ?? rootIdentity }
    public var rootAncestors: [StoragePathIdentity] { savedRootAncestors ?? [] }
    public var scanMethod: StorageScanMethod { savedScanMethod ?? .directoryTraversal }
    /// Catalog searches can silently omit protected resources; zero reported errors do not prove coverage.
    public var hasUnverifiedCoverage: Bool { scanMethod == .volumeCatalog }
    public var isComplete: Bool { !hasUnverifiedCoverage && issues.isEmpty && omittedIssueCount == 0 && !nodes.contains { $0.isIncomplete } }
    public var root: StorageNode? { nodes.first }

    public init(id: UUID = UUID(), grantID: UUID, rootPath: String, rootIdentity: StorageFileIdentity,
                scannedAt: Date = Date(), nodes: [StorageNode], issues: [StorageScanIssue],
                omittedIssueCount: Int = 0, volume: StorageVolumeCapacity? = nil, schemaVersion: Int = 1,
                largestCatalog: [StorageItemReference] = [], authorizationRootPath: String? = nil,
                authorizationRootIdentity: StorageFileIdentity? = nil, rootAncestors: [StoragePathIdentity] = [],
                scanMethod: StorageScanMethod = .directoryTraversal, tree: StorageTreeDescriptor? = nil) {
        self.schemaVersion = schemaVersion; self.id = id; self.grantID = grantID
        self.rootPath = rootPath; self.rootIdentity = rootIdentity; self.scannedAt = scannedAt
        self.nodes = nodes; self.issues = issues; self.omittedIssueCount = omittedIssueCount; self.volume = volume
        savedLargestCatalog = largestCatalog; savedAuthorizationRootPath = authorizationRootPath
        savedAuthorizationRootIdentity = authorizationRootIdentity; savedRootAncestors = rootAncestors
        savedScanMethod = scanMethod
        self.tree = tree
    }

    public func node(id: Int) -> StorageNode? {
        if schemaVersion == 3 { return nodes.first { $0.id == id } }
        return nodes.indices.contains(id) && nodes[id].id == id ? nodes[id] : nil
    }
    public func children(of id: Int, metric: StorageSizeMetric = .allocated) -> [StorageNode] {
        nodes.filter { $0.parentID == id }.sorted {
            $0.bytes(for: metric) == $1.bytes(for: metric)
                ? $0.relativePath < $1.relativePath : $0.bytes(for: metric) > $1.bytes(for: metric)
        }
    }
    public func largestFiles(metric: StorageSizeMetric = .allocated, limit: Int = 100) -> [StorageNode] {
        Array(nodes.filter { $0.kind == .file || $0.kind == .package }.sorted {
            $0.bytes(for: metric) == $1.bytes(for: metric)
                ? $0.relativePath < $1.relativePath : $0.bytes(for: metric) > $1.bytes(for: metric)
        }.prefix(max(0, limit)))
    }
    public func breadcrumbs(to id: Int) -> [StorageNode] {
        var result: [StorageNode] = []
        var current = node(id: id)
        while let item = current, result.count <= nodes.count {
            result.append(item)
            current = item.parentID.flatMap { node(id: $0) }
        }
        return result.reversed()
    }

    public func itemReference(id: Int) -> StorageItemReference? {
        if let node = node(id: id) {
            return StorageItemReference(id: id, name: node.name, relativePath: node.relativePath, kind: node.kind,
                identity: node.identity, totals: StorageTotals(logicalBytes: node.logicalBytes,
                    allocatedBytes: node.allocatedBytes, apparentBytes: node.apparentBytes, fileCount: node.fileCount),
                ancestors: breadcrumbs(to: id).dropLast().map { StoragePathIdentity(relativePath: $0.relativePath, identity: $0.identity) },
                isCloudPlaceholder: node.isCloudPlaceholder, isHardLinkDuplicate: node.isHardLinkDuplicate,
                isIncomplete: node.isIncomplete, unlistedChildCount: node.unlistedChildCount)
        }
        return largestCatalog.first { $0.id == id }
    }
    public func childReferences(of id: Int, metric: StorageSizeMetric = .allocated) -> [StorageItemReference] {
        children(of: id, metric: metric).compactMap { itemReference(id: $0.id) }
    }
    public func largestItems(metric: StorageSizeMetric = .allocated, limit: Int = 100) -> [StorageItemReference] {
        let candidates = savedLargestCatalog == nil || schemaVersion == 1
            ? largestFiles(metric: metric, limit: max(0, limit)).compactMap { itemReference(id: $0.id) }
            : largestCatalog
        return Array(candidates.sorted {
            $0.bytes(for: metric) == $1.bytes(for: metric) ? $0.relativePath < $1.relativePath : $0.bytes(for: metric) > $1.bytes(for: metric)
        }.prefix(max(0, limit)))
    }

    public func validate() throws {
        guard (1...3).contains(schemaVersion) else { throw StorageSnapshotValidationError.unsupportedSchema }
        guard let root, root.id == 0, root.parentID == nil, root.relativePath.isEmpty,
              root.identity == rootIdentity, rootPath.hasPrefix("/"), !rootPath.contains("\0"),
              root.kind == .directory || root.kind == .package, omittedIssueCount >= 0,
              scannedAt.timeIntervalSince1970.isFinite else { throw StorageSnapshotValidationError.invalidRoot }
        if schemaVersion == 3 {
            let representedChildren = root.unlistedChildCount.addingReportingOverflow(nodes.count - 1)
            guard let tree, tree.id == id, (1...2).contains(tree.formatVersion),
                  tree.nodeCount >= nodes.count, tree.nodeCount > 0,
                  tree.rootChildCount >= 0, tree.rootChildCount < tree.nodeCount,
                  !representedChildren.overflow,
                  root.kind != .directory || tree.rootChildCount == representedChildren.partialValue
            else { throw StorageSnapshotValidationError.invalidRoot }
        } else if tree != nil { throw StorageSnapshotValidationError.invalidRoot }
        let authorization = URL(fileURLWithPath: authorizationRootPath).standardizedFileURL.path
        guard authorization == authorizationRootPath, authorizationRootPath.hasPrefix("/"),
              !authorizationRootPath.contains("\0"),
              rootPath == authorizationRootPath || rootPath.hasPrefix(authorizationRootPath == "/" ? "/" : authorizationRootPath + "/")
        else { throw StorageSnapshotValidationError.invalidRoot }
        let rootRelative = rootPath == authorizationRootPath ? "" : String(rootPath.dropFirst(authorizationRootPath == "/" ? 1 : authorizationRootPath.count + 1))
        guard Self.validProof(rootAncestors, relativePath: rootRelative, rootIdentity: authorizationRootIdentity),
              !rootRelative.isEmpty || rootIdentity == authorizationRootIdentity else { throw StorageSnapshotValidationError.invalidRoot }
        var paths: Set<String> = []
        var logical = Array(repeating: UInt64(0), count: nodes.count)
        var allocated = logical
        var apparent = logical
        var files = Array(repeating: 0, count: nodes.count)
        var nodePositions: [Int: Int] = [:]
        for (index, node) in nodes.enumerated() {
            guard (schemaVersion == 3 ? node.id >= 0 && node.id < (tree?.nodeCount ?? 0) : node.id == index),
                  nodePositions.updateValue(index, forKey: node.id) == nil,
                  node.fileCount >= 0, !node.name.isEmpty,
                  node.unlistedChildCount >= 0, node.unlistedChildren.fileCount >= 0,
                  node.unlistedChildCount > 0 || node.unlistedChildren == .zero,
                  node.kind == .directory || (node.unlistedChildCount == 0 && node.unlistedChildren == .zero),
                  node.identity.birthNanoseconds >= 0, node.identity.birthNanoseconds < 1_000_000_000,
                  paths.insert(node.relativePath).inserted else { throw StorageSnapshotValidationError.invalidNode(index) }
            if index > 0 {
                guard let parentID = node.parentID, let parent = nodePositions[parentID], parent < index,
                      schemaVersion != 3 || parentID == 0,
                      nodes[parent].kind == .directory,
                      !node.name.contains("/"), !node.name.contains("\0"), node.name != ".", node.name != "..",
                      !node.relativePath.hasPrefix("/"),
                      !node.relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                      node.relativePath == (nodes[parent].relativePath.isEmpty ? node.name : nodes[parent].relativePath + "/" + node.name)
                else { throw StorageSnapshotValidationError.invalidNode(index) }
            }
            if let parentID = node.parentID, let parent = nodePositions[parentID] {
                let logicalSum = logical[parent].addingReportingOverflow(node.logicalBytes)
                let allocatedSum = allocated[parent].addingReportingOverflow(node.allocatedBytes)
                let apparentSum = apparent[parent].addingReportingOverflow(node.apparentBytes)
                let fileSum = files[parent].addingReportingOverflow(node.fileCount)
                guard !logicalSum.overflow && !allocatedSum.overflow && !apparentSum.overflow && !fileSum.overflow
                else { throw StorageSnapshotValidationError.invalidTotals(parent) }
                logical[parent] = logicalSum.partialValue; allocated[parent] = allocatedSum.partialValue
                apparent[parent] = apparentSum.partialValue; files[parent] = fileSum.partialValue
            }
        }
        // Each node already contains its subtree total; summing immediate children is sufficient.
        for node in nodes where node.kind == .directory {
            guard let position = nodePositions[node.id] else { throw StorageSnapshotValidationError.invalidNode(node.id) }
            let l = logical[position].addingReportingOverflow(node.unlistedChildren.logicalBytes)
            let a = allocated[position].addingReportingOverflow(node.unlistedChildren.allocatedBytes)
            let p = apparent[position].addingReportingOverflow(node.unlistedChildren.apparentBytes)
            let f = files[position].addingReportingOverflow(node.unlistedChildren.fileCount)
            guard !l.overflow, !a.overflow, !p.overflow, !f.overflow,
                  l.partialValue == node.logicalBytes, a.partialValue == node.allocatedBytes,
                  p.partialValue == node.apparentBytes, f.partialValue == node.fileCount
            else { throw StorageSnapshotValidationError.invalidTotals(node.id) }
        }
        var catalogIDs = Set<Int>()
        var catalogPaths = Set<String>()
        for item in largestCatalog {
            guard item.id > 0, !item.name.isEmpty, item.totals.fileCount >= 0,
                  schemaVersion != 3 || item.id < (tree?.nodeCount ?? 0),
                  item.identity.birthNanoseconds >= 0, item.identity.birthNanoseconds < 1_000_000_000,
                  item.unlistedChildCount == 0,
                  item.logicalBytes <= root.logicalBytes, item.allocatedBytes <= root.allocatedBytes,
                  item.apparentBytes <= root.apparentBytes, item.fileCount <= root.fileCount,
                  item.kind == .file || item.kind == .package,
                  catalogIDs.insert(item.id).inserted, catalogPaths.insert(item.relativePath).inserted,
                  item.relativePath.split(separator: "/").last.map(String.init) == item.name,
                  Self.validProof(item.ancestors, relativePath: item.relativePath, rootIdentity: rootIdentity)
            else { throw StorageSnapshotValidationError.invalidNode(item.id) }
            if node(id: item.id) != nil {
                guard itemReference(id: item.id) == item else { throw StorageSnapshotValidationError.invalidNode(item.id) }
            } else {
                guard (schemaVersion == 3 || item.id >= nodes.count), !paths.contains(item.relativePath) else { throw StorageSnapshotValidationError.invalidNode(item.id) }
            }
        }
    }

    private static func validProof(_ proof: [StoragePathIdentity], relativePath: String, rootIdentity: StorageFileIdentity) -> Bool {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0") else { return false }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if relativePath.isEmpty { return proof.isEmpty }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), proof.count == components.count,
              proof.first?.relativePath == "", proof.first?.identity == rootIdentity else { return false }
        for (index, entry) in proof.enumerated() {
            guard entry.relativePath == components.prefix(index).joined(separator: "/"),
                  entry.identity.birthNanoseconds >= 0, entry.identity.birthNanoseconds < 1_000_000_000 else { return false }
        }
        return true
    }
}
