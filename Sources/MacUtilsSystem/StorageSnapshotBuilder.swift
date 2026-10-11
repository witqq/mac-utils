import Foundation
import MacUtilsCore

enum StorageSnapshotBuilder {
    static func build(rootURL: URL, grantID: UUID, root: ScanItem, overview: [StorageItemReference],
                      largest: [StorageItemReference], issues: [StorageScanIssue], omittedIssues: Int,
                      authorizationRootPath: String? = nil, authorizationRootIdentity: StorageFileIdentity? = nil,
                      rootAncestors: [StoragePathIdentity] = [], scanMethod: StorageScanMethod = .directoryTraversal,
                      treeWriter: StorageTreeWriter? = nil, maximumNodes: Int = 1_001, largestLimit: Int = 200) throws -> StorageSnapshot {
        if let treeWriter {
            for issue in issues {
                var path = issue.path
                while true {
                    if let id = try treeWriter.directoryID(relativePath: path) {
                        try treeWriter.markIncomplete(directoryID: id); break
                    }
                    if path.isEmpty { break }
                    path = path.split(separator: "/").dropLast().joined(separator: "/")
                }
            }
            if root.isIncomplete { try treeWriter.markIncomplete(directoryID: 0) }
            let summary = try treeWriter.finish(expectedRootTotals: root.totals, maximumNodes: maximumNodes, largestLimit: largestLimit)
            guard try StorageFileMetadata.identity(at: rootURL) == root.identity else {
                throw StorageCatalogScanError.changedItem(path: rootURL.path, reason: "selected root changed during tree finalization")
            }
            var listed = StorageTotals.zero
            for item in summary.overview { listed = try StorageScanner.sum(listed, item.totals, path: "") }
            let unlisted = StorageTotals(logicalBytes: root.totals.logicalBytes - listed.logicalBytes,
                allocatedBytes: root.totals.allocatedBytes - listed.allocatedBytes,
                apparentBytes: root.totals.apparentBytes - listed.apparentBytes, fileCount: root.totals.fileCount - listed.fileCount)
            var nodes = [StorageNode(id: 0, parentID: nil, name: root.name, relativePath: "", kind: root.kind,
                identity: root.identity, logicalBytes: root.totals.logicalBytes, allocatedBytes: root.totals.allocatedBytes,
                apparentBytes: root.totals.apparentBytes, fileCount: root.totals.fileCount,
                isCloudPlaceholder: summary.root.isCloudPlaceholder, isIncomplete: summary.root.isIncomplete,
                unlistedChildren: root.kind == .directory ? unlisted : .zero,
                unlistedChildCount: root.kind == .directory ? summary.descriptor.rootChildCount - summary.overview.count : 0)]
            for item in summary.overview.sorted(by: { $0.relativePath < $1.relativePath }) {
                nodes.append(StorageNode(id: item.id, parentID: 0, name: item.name, relativePath: item.relativePath,
                    kind: item.kind, identity: item.identity, logicalBytes: item.logicalBytes, allocatedBytes: item.allocatedBytes,
                    apparentBytes: item.apparentBytes, fileCount: item.fileCount, isCloudPlaceholder: item.isCloudPlaceholder,
                    isHardLinkDuplicate: item.isHardLinkDuplicate, isIncomplete: item.isIncomplete,
                    unlistedChildren: item.kind == .directory ? item.totals : .zero,
                    unlistedChildCount: item.kind == .directory ? item.unlistedChildCount : 0))
            }
            for item in summary.overview + summary.largest {
                try Task.checkCancellation()
                // Only a confirmed catalog replacement may keep its prior proven leaf
                // as incomplete historical metadata. It never adopts the new object;
                // native action validation still rejects this stale identity later.
                let knownReplacement: Bool
                if scanMethod == .volumeCatalog && item.kind != .directory && item.kind != .package {
                    knownReplacement = try treeWriter.isKnownLeafReplacement(id: item.id)
                } else { knownReplacement = false }
                if !knownReplacement {
                    guard try StorageFileMetadata.identity(at: rootURL.appending(path: item.relativePath)) == item.identity else {
                        throw StorageCatalogScanError.changedItem(path: item.relativePath, reason: "tree summary identity changed during final validation")
                    }
                }
                for ancestor in item.ancestors {
                    guard try StorageFileMetadata.identity(at: rootURL.appending(path: ancestor.relativePath)) == ancestor.identity else {
                        throw StorageCatalogScanError.changedItem(path: ancestor.relativePath, reason: "tree summary ancestor changed during final validation")
                    }
                }
            }
            let capacity = try? StorageDatalessPolicy.withMaterializationDisabled { enabled in
                guard enabled else { throw StorageDatalessPolicyError.unavailable }
                return try rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            }
            let volume = capacity.map { StorageVolumeCapacity(totalBytes: $0.volumeTotalCapacity.map { UInt64(max(0, $0)) },
                availableBytes: $0.volumeAvailableCapacity.map { UInt64(max(0, $0)) },
                availableForImportantUsageBytes: $0.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }) }
            let snapshot = StorageSnapshot(id: summary.descriptor.id, grantID: grantID, rootPath: rootURL.path,
                rootIdentity: root.identity, nodes: nodes, issues: issues, omittedIssueCount: omittedIssues,
                volume: volume, schemaVersion: 3, largestCatalog: summary.largest,
                authorizationRootPath: authorizationRootPath, authorizationRootIdentity: authorizationRootIdentity,
                rootAncestors: rootAncestors, scanMethod: scanMethod, tree: summary.descriptor)
            try snapshot.validate()
            try Task.checkCancellation()
            try treeWriter.publish(snapshot: snapshot)
            return snapshot
        }
        let retained = overview.sorted { $0.relativePath < $1.relativePath }
        var listed = StorageTotals.zero
        for item in retained { listed = try StorageScanner.sum(listed, item.totals, path: "") }
        guard listed.logicalBytes <= root.totals.logicalBytes, listed.allocatedBytes <= root.totals.allocatedBytes,
              listed.apparentBytes <= root.totals.apparentBytes, listed.fileCount <= root.totals.fileCount,
              retained.count <= root.childCount else { throw StorageSnapshotValidationError.invalidTotals(0) }
        let unlisted = StorageTotals(logicalBytes: root.totals.logicalBytes - listed.logicalBytes,
            allocatedBytes: root.totals.allocatedBytes - listed.allocatedBytes,
            apparentBytes: root.totals.apparentBytes - listed.apparentBytes, fileCount: root.totals.fileCount - listed.fileCount)
        var nodes = [root.node(id: 0, parentID: nil,
            unlisted: root.kind == .directory ? unlisted : .zero,
            childCount: root.kind == .directory ? root.childCount - retained.count : 0)]
        var ids: [String: Int] = ["": 0]
        for item in retained {
            let id = nodes.count; ids[item.relativePath] = id
            nodes.append(StorageNode(id: id, parentID: 0, name: item.name, relativePath: item.relativePath,
                kind: item.kind, identity: item.identity, logicalBytes: item.logicalBytes, allocatedBytes: item.allocatedBytes,
                apparentBytes: item.apparentBytes, fileCount: item.fileCount, isCloudPlaceholder: item.isCloudPlaceholder,
                isHardLinkDuplicate: item.isHardLinkDuplicate, isIncomplete: item.isIncomplete,
                unlistedChildren: item.kind == .directory ? item.totals : .zero,
                unlistedChildCount: item.kind == .directory ? item.unlistedChildCount : 0))
        }
        var nextID = nodes.count
        let catalog = largest.sorted { $0.relativePath < $1.relativePath }.map { item in
            let id: Int
            if let existing = ids[item.relativePath] { id = existing }
            else { id = nextID; nextID += 1 }
            return StorageItemReference(id: id, name: item.name, relativePath: item.relativePath, kind: item.kind,
                identity: item.identity, totals: item.totals, ancestors: item.ancestors,
                isCloudPlaceholder: item.isCloudPlaceholder, isHardLinkDuplicate: item.isHardLinkDuplicate, isIncomplete: item.isIncomplete)
        }
        let capacity = try? StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            return try rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        }
        let volume = capacity.map { StorageVolumeCapacity(totalBytes: $0.volumeTotalCapacity.map { UInt64(max(0, $0)) },
            availableBytes: $0.volumeAvailableCapacity.map { UInt64(max(0, $0)) },
            availableForImportantUsageBytes: $0.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }) }
        let snapshot = StorageSnapshot(grantID: grantID, rootPath: rootURL.path, rootIdentity: root.identity,
            nodes: nodes, issues: issues, omittedIssueCount: omittedIssues, volume: volume, schemaVersion: 2,
            largestCatalog: catalog, authorizationRootPath: authorizationRootPath,
            authorizationRootIdentity: authorizationRootIdentity, rootAncestors: rootAncestors, scanMethod: scanMethod)
        try snapshot.validate()
        return snapshot
    }
}
