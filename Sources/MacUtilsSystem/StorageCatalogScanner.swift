import Darwin
import Foundation
import MacUtilsCore

enum StorageCatalogScanError: Error, CustomStringConvertible {
    case retainedStateLimit
    case invalidNamespace
    case changedItem(path: String, reason: String)
    var description: String {
        switch self {
        case .retainedStateLimit: "Catalog aggregation exceeded its bounded retained-state limit."
        case .invalidNamespace: "Catalog path mapping encountered an invalid or symbolic-link ancestor."
        case let .changedItem(path, reason): "Catalog identity changed at \(path): \(reason)"
        }
    }
}

/// Prototype catalog engine. Product routing remains separate until native parity is verified.
actor StorageCatalogScanner {
    private let maximumNodes: Int
    private let largestLimit: Int
    private let maximumIssues: Int
    private let retainedStateLimit: Int
    private let resourceReader: any StorageResourceReading
    private let treeDirectory: URL?
    init(maximumNodes: Int = 1_001, largestLimit: Int = 200, maximumIssues: Int = 1_000,
         retainedStateLimit: Int = 100_000, resourceReader: any StorageResourceReading = NativeStorageResourceReader(),
         treeDirectory: URL? = nil) {
        self.maximumNodes = max(1, maximumNodes); self.largestLimit = max(0, largestLimit)
        self.maximumIssues = max(1, maximumIssues); self.retainedStateLimit = max(1, retainedStateLimit)
        self.resourceReader = resourceReader
        self.treeDirectory = treeDirectory
    }

    func scan(rootURL: URL, grantID: UUID, plans: [StorageCatalogVolumePlan],
              authorizationRootPath: String? = nil, authorizationRootIdentity: StorageFileIdentity? = nil,
              rootAncestors: [StoragePathIdentity] = [],
              makeReader: @Sendable (URL) throws -> any StorageCatalogReading = { try StorageCatalogReader(volumeURL: $0) },
              progress: @escaping @Sendable (StorageScanProgress) async -> Void = { _ in }) async throws -> StorageSnapshot {
        try Task.checkCancellation()
        let rootMetadata = try StorageDatalessPolicy.withMaterializationDisabled { _ in try StorageFileMetadata.read(at: rootURL) }
        guard rootMetadata.st_mode & S_IFMT == S_IFDIR else { throw StorageScannerError.rootNotDirectory }
        let rootIdentity = StorageFileMetadata.identity(rootMetadata)
        let rootHints = rootMetadata.st_flags & UInt32(SF_DATALESS) != 0 ? StorageResourceHints(isCloudPlaceholder: true)
            : try StorageDatalessPolicy.withMaterializationDisabled { _ in
                try resourceReader.hints(at: rootURL, isDirectory: true, mode: .volumeCatalog)
            }
        let root = ScanItem(name: rootURL.lastPathComponent.isEmpty ? "/" : rootURL.lastPathComponent,
            relativePath: "", kind: rootHints.isPackage ? .package : .directory, identity: rootIdentity, ancestors: [])
        let writer = try treeDirectory.map { try StorageTreeWriter(directoryURL: $0, snapshotID: UUID(),
            grantID: grantID, rootURL: rootURL, rootIdentity: rootIdentity, rootKind: root.kind,
            rootCloud: rootHints.isCloudPlaceholder) }
        defer { writer?.abort() }
        guard writer?.excludes(url: rootURL, identity: rootIdentity) != true else {
            throw StorageTreeIndexError.invalid("The analysis cache itself cannot be scanned")
        }
        var cacheReported = false
        let estimates = plans.compactMap(\.estimatedTotalItems)
        let estimatedTotalItems: Int? = estimates.count == plans.count && !estimates.isEmpty
            ? estimates.reduce(0) { total, value in let sum = total.addingReportingOverflow(value); return sum.overflow ? Int.max : sum.partialValue } : nil
        var children: [String: ScanItem] = [:]
        var packages: [String: ScanItem] = [:]
        var links: Set<CatalogLinkIdentity> = []
        // Compact scans already retain multiply-linked identities. Retain their exact
        // catalog names as well: APFS may vend one hard-link record more than once.
        // Full-tree scans use SQLite instead, without an all-leaf Swift collection.
        var compactLinkedRecords: [CatalogLeafName: Data] = [:]
        var largest = DualTopItems(limitPerMetric: largestLimit)
        var issues: [StorageScanIssue] = []
        var omittedIssues = 0
        var visited = 0
        var prefixContexts: [String: CatalogContextResult] = [:]
        var prefixOrder: [String] = []
        let clock = ContinuousClock()
        var lastProgress = clock.now
        func issue(_ path: String, _ reason: StorageScanIssueReason, _ message: String) {
            root.isIncomplete = true
            if let first = path.split(separator: "/").first { children[String(first)]?.isIncomplete = true }
            var prefix = ""
            for component in path.split(separator: "/") {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                packages[prefix]?.isIncomplete = true
            }
            if issues.count < maximumIssues { issues.append(StorageScanIssue(path: path, reason: reason, message: message)) }
            else { omittedIssues += 1 }
        }
        func retain(_ item: ScanItem, in collection: inout [String: ScanItem], otherCount: Int) throws {
            if collection[item.relativePath] == nil {
                guard collection.count + otherCount < retainedStateLimit else { throw StorageCatalogScanError.retainedStateLimit }
                collection[item.relativePath] = item
            }
        }
        func context(relative: String) throws -> CatalogDirectoryContext? {
            var ancestors = [StoragePathIdentity(relativePath: "", identity: rootIdentity)]
            var prefix = ""
            var outerPackage: String? = root.kind == .package ? "" : nil
            if relative.isEmpty { return CatalogDirectoryContext(relativePath: "", url: rootURL, identity: rootIdentity, ancestors: [], package: outerPackage, treeID: writer == nil ? nil : 0) }
            let components = relative.split(separator: "/").map(String.init)
            guard !components.contains("."), !components.contains(".."), !relative.hasPrefix("/"), !relative.contains("\0") else {
                throw StorageCatalogScanError.invalidNamespace
            }
            for (index, component) in components.enumerated() {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                if let cached = prefixContexts[prefix] {
                    guard let value = cached.value else { return nil }
                    outerPackage = value.package
                    if index == components.count - 1 { return value }
                    ancestors.append(StoragePathIdentity(relativePath: prefix, identity: value.identity))
                    continue
                }
                func cache(_ value: CatalogContextResult) {
                    if prefixContexts.count == 4_096 { prefixContexts.removeValue(forKey: prefixOrder.removeFirst()) }
                    prefixContexts[prefix] = value; prefixOrder.append(prefix)
                }
                let url = rootURL.appending(path: prefix)
                let metadata: stat
                let hints: StorageResourceHints
                do {
                    metadata = try StorageDatalessPolicy.withMaterializationDisabled { _ in try StorageFileMetadata.read(at: url) }
                } catch {
                    let code = (error as? POSIXError)?.code
                    issue(prefix, code == .EDEADLK ? .cloudPlaceholderDirectory
                        : code == .EACCES || code == .EPERM ? .permissionDenied : .unreadable, String(describing: error))
                    cache(.excluded)
                    return nil
                }
                guard metadata.st_mode & S_IFMT == S_IFDIR else { throw StorageCatalogScanError.invalidNamespace }
                if writer?.excludes(url: url, identity: StorageFileMetadata.identity(metadata)) == true {
                    if !cacheReported { issue(prefix, .analysisCache, "This utility's analysis indexes were excluded"); cacheReported = true }
                    cache(.excluded); return nil
                }
                do {
                    hints = metadata.st_flags & UInt32(SF_DATALESS) != 0 ? StorageResourceHints(isCloudPlaceholder: true)
                        : try StorageDatalessPolicy.withMaterializationDisabled { _ in
                            try resourceReader.hints(at: url, isDirectory: true, mode: .volumeCatalog)
                        }
                }
                catch {
                    let code = (error as? POSIXError)?.code
                    issue(prefix, code == .EDEADLK ? .cloudPlaceholderDirectory
                        : code == .EACCES || code == .EPERM ? .permissionDenied : .unreadable, String(describing: error))
                    cache(.excluded)
                    return nil
                }
                let identity = StorageFileMetadata.identity(metadata)
                let item = ScanItem(name: component, relativePath: prefix,
                    kind: hints.isPackage ? .package : .directory, identity: identity, ancestors: ancestors)
                item.isCloudPlaceholder = metadata.st_flags & UInt32(SF_DATALESS) != 0 || hints.isCloudPlaceholder
                if hints.isVolumeRoot {
                    issue(prefix, .mountBoundary, "Another mounted volume root was not scanned")
                    cache(.mountExcluded)
                    return nil
                }
                let treeID: Int?
                if let writer {
                    let parentPath = components.prefix(index).joined(separator: "/")
                    guard let parentID = try writer.directoryID(relativePath: parentPath) else { throw StorageTreeIndexError.invalid("Missing directory context parent") }
                    treeID = try writer.ensureDirectory(name: component, relativePath: prefix, parentID: parentID,
                        identity: identity, kind: item.kind, isCloudPlaceholder: item.isCloudPlaceholder,
                        isIncomplete: item.isCloudPlaceholder)
                } else { treeID = nil }
                if writer == nil && index == 0 { try retain(item, in: &children, otherCount: packages.count) }
                if item.isCloudPlaceholder {
                    children[components[0]]?.isIncomplete = true
                    issue(prefix, .cloudPlaceholderDirectory, "Cloud-only folder contents were not downloaded or enumerated")
                    cache(.excluded)
                    return nil
                }
                if hints.isPackage && outerPackage == nil {
                    outerPackage = prefix
                    if writer == nil { try retain(children[prefix] ?? item, in: &packages, otherCount: children.count) }
                }
                let value = CatalogDirectoryContext(relativePath: prefix, url: url, identity: identity, ancestors: ancestors, package: outerPackage, treeID: treeID)
                cache(.visible(value))
                if index == components.count - 1 { return value }
                ancestors.append(StoragePathIdentity(relativePath: prefix, identity: identity))
            }
            return nil
        }
        await progress(StorageScanProgress(visitedItems: 0, currentPath: rootURL.path, logicalBytes: 0, allocatedBytes: 0,
            phase: .volumeCatalog, estimatedTotalItems: estimatedTotalItems))
        try Task.checkCancellation()
        if rootMetadata.st_flags & UInt32(SF_DATALESS) != 0 || rootHints.isCloudPlaceholder {
            root.isCloudPlaceholder = true
            issue("", .cloudPlaceholderDirectory, "Cloud-only folder contents were not downloaded or enumerated")
            let snapshot = try StorageSnapshotBuilder.build(rootURL: rootURL, grantID: grantID, root: root,
                overview: [], largest: [], issues: issues, omittedIssues: omittedIssues,
                authorizationRootPath: authorizationRootPath, authorizationRootIdentity: authorizationRootIdentity,
                rootAncestors: rootAncestors, scanMethod: .volumeCatalog, treeWriter: writer,
                maximumNodes: maximumNodes, largestLimit: largestLimit)
            try Task.checkCancellation()
            writer?.completeHandoff()
            return snapshot
        }
        for (volumeIndex, plan) in plans.enumerated() {
            let reader = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                guard enabled else { throw StorageDatalessPolicyError.unavailable }
                return try makeReader(plan.volumeURL)
            }
            let leafMetadata = StorageCatalogMetadataCache()
            var contexts: [UInt64: CatalogContextResult] = [:]
            var contextOrder: [UInt64] = []
            func parent(_ inode: UInt64) throws -> CatalogDirectoryContext? {
                func validate(_ value: CatalogDirectoryContext?) throws {
                    if let value, value.identity.inode != inode && !(value.relativePath.isEmpty && inode == 2) {
                        throw StorageCatalogScanError.changedItem(path: value.relativePath, reason: "parent inode differs from catalog PARENTID")
                    }
                }
                if let cached = contexts[inode] { try validate(cached.value); return cached.value }
                let native = try plan.resolve(inode: inode)
                let value: CatalogDirectoryContext?
                if let relative = plan.visibleRelativePath(nativePath: native.path) { value = try context(relative: relative) }
                else { value = nil }
                try validate(value)
                if contexts.count == 4_096 { contexts.removeValue(forKey: contextOrder.removeFirst()) }
                contexts[inode] = value.map(CatalogContextResult.visible) ?? .excluded
                contextOrder.append(inode)
                return value
            }
            var completed = false
            while !completed {
                try Task.checkCancellation()
                let batch = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                    guard enabled else { throw StorageDatalessPolicyError.unavailable }
                    return try reader.nextBatch()
                }
                completed = batch.isComplete
                for entry in batch.entries {
                    try Task.checkCancellation()
                    visited += 1
                    let currentRelative = try autoreleasepool { () throws -> String? in
                        if entry.type == UInt32(VDIR.rawValue) {
                            do {
                                let native = try plan.resolve(inode: entry.inode)
                                guard let relative = plan.visibleRelativePath(nativePath: native.path), !relative.isEmpty else { return nil }
                                let parts = relative.split(separator: "/")
                                guard try context(relative: parts.dropLast().joined(separator: "/")) != nil else { return nil }
                                _ = try context(relative: relative)
                                if case .mountExcluded? = prefixContexts[relative] { return nil }
                                let historical = StorageFileIdentity(device: entry.device, inode: entry.inode,
                                    birthSeconds: entry.birthSeconds, birthNanoseconds: entry.birthNanoseconds)
                                guard try StorageDatalessPolicy.withMaterializationDisabled({ _ in
                                    try StorageFileMetadata.identity(at: rootURL.appending(path: relative))
                                }) == historical else {
                                    throw StorageCatalogScanError.changedItem(path: relative, reason: "directory historical identity differs from current path")
                                }
                                if parts.count == 2 { children[String(parts[0])]?.childCount += 1 }
                            } catch let failure as StorageCatalogScanError { throw failure }
                            catch let failure as StorageCatalogReaderError { throw failure }
                            catch let failure as StorageTreeIndexError { throw failure }
                            catch { issue(entry.name, .unreadable, String(describing: error)) }
                            return nil
                        }
                        let parentContext: CatalogDirectoryContext
                        do { guard let value = try parent(entry.parentInode) else { return nil }; parentContext = value }
                        catch let failure as StorageCatalogScanError { throw failure }
                        catch let failure as StorageCatalogReaderError { throw failure }
                        catch let failure as StorageTreeIndexError { throw failure }
                        catch { issue(entry.name, .unreadable, String(describing: error)); return nil }
                        let relative = parentContext.relativePath.isEmpty ? entry.name : parentContext.relativePath + "/" + entry.name
                        guard !entry.name.contains("/"), entry.name != ".", entry.name != ".." else { throw StorageCatalogScanError.invalidNamespace }
                        let identity = StorageFileIdentity(device: entry.device, inode: entry.inode,
                            birthSeconds: entry.birthSeconds, birthNanoseconds: entry.birthNanoseconds)
                        // searchfs implementations may report VREG for every non-directory,
                        // including symlinks, sockets and FIFOs. Permission bits in ACCESSMASK
                        // do not identify the native file type. A no-follow metadata lookup is
                        // necessary after the parent/cloud checks; it never opens file contents.
                        let metadata: stat
                        do {
                            metadata = try leafMetadata.metadata(name: entry.name,
                                parentURL: parentContext.url, parentIdentity: parentContext.identity)
                        }
                        catch let failure as StorageCatalogScanError { throw failure }
                        catch let failure as StorageCatalogReaderError { throw failure }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            let code = (error as? POSIXError)?.code
                            issue(relative, code == .EDEADLK ? .cloudPlaceholderDirectory
                                : code == .EACCES || code == .EPERM ? .permissionDenied : .unreadable, String(describing: error))
                            return nil
                        }
                        guard StorageFileMetadata.identity(metadata) == identity else {
                            issue(relative, .changedDuringScan, "The leaf changed after its catalog metadata was read; its historical contribution was omitted")
                            return nil
                        }
                        let nativeType = metadata.st_mode & S_IFMT
                        guard nativeType != S_IFDIR else {
                            issue(relative, .changedDuringScan, "A non-directory catalog leaf became a directory; its historical contribution was omitted")
                            return nil
                        }
                        let kind: StorageNodeKind = nativeType == S_IFREG ? .file : nativeType == S_IFLNK ? .symbolicLink : .other
                        if writer == nil {
                            let key = CatalogLeafName(volume: volumeIndex, parentInode: entry.parentInode, name: Data(entry.name.utf8))
                            if let previous = compactLinkedRecords[key] {
                                guard previous == entry.indexSignature else {
                                    throw StorageCatalogScanError.changedItem(path: relative, reason: "a repeated hard-link catalog name has conflicting historical metadata")
                                }
                                return relative
                            }
                            if metadata.st_nlink > 1 || entry.linkCount > 1 { compactLinkedRecords[key] = entry.indexSignature }
                        }
                        let ancestors = writer == nil ? parentContext.ancestors + [StoragePathIdentity(relativePath: parentContext.relativePath, identity: parentContext.identity)] : []
                        let item = ScanItem(name: entry.name, relativePath: relative, kind: kind, identity: identity, ancestors: ancestors)
                        item.isCloudPlaceholder = metadata.st_flags & UInt32(SF_DATALESS) != 0
                        let linkIdentity = CatalogLinkIdentity(volume: volumeIndex, identity: identity)
                        let duplicate = kind == .file && metadata.st_nlink > 1 && links.contains(linkIdentity)
                        item.isHardLinkDuplicate = duplicate
                        if kind == .file || kind == .symbolicLink {
                            item.totals = StorageTotals(logicalBytes: duplicate ? 0 : entry.logicalBytes,
                                allocatedBytes: duplicate ? 0 : entry.allocatedBytes, apparentBytes: entry.logicalBytes,
                                fileCount: kind == .file ? 1 : 0)
                        }
                        if let writer, let parentID = parentContext.treeID {
                            let inserted: Bool
                            do {
                                inserted = try writer.appendLeaf(name: entry.name, parentID: parentID, kind: kind, identity: identity,
                                    totals: item.totals, isCloudPlaceholder: item.isCloudPlaceholder,
                                    isHardLinkDuplicate: duplicate, isIncomplete: item.isIncomplete,
                                    isInsidePackage: parentContext.package != nil, catalogRecord: entry.indexSignature)
                            } catch let changed as StorageTreeCatalogLeafReplacement {
                                try writer.markKnownLeafReplacement(changed)
                                issue(relative, .changedDuringScan, "The catalog returned a replacement for an already accepted leaf; its new contribution was omitted. \(changed)")
                                return relative
                            }
                            guard inserted else { return relative }
                        }
                        if kind == .file && metadata.st_nlink > 1 { links.insert(linkIdentity) }
                        try root.add(item.totals)
                        if writer != nil { return relative }
                        if parentContext.relativePath.isEmpty { try retain(item, in: &children, otherCount: packages.count) }
                        else {
                            let first = String(relative.split(separator: "/")[0])
                            try children[first]?.add(item.totals)
                            if relative.split(separator: "/").count == 2 { children[first]?.childCount += 1 }
                        }
                        if let package = parentContext.package {
                            let first = String(relative.split(separator: "/")[0])
                            if package != first { try packages[package]?.add(item.totals) }
                        }
                        else if kind == .file { largest.insert(item.reference()) }
                        return relative
                    }
                    if clock.now - lastProgress >= .milliseconds(120) {
                        await progress(StorageScanProgress(visitedItems: visited, currentPath: rootURL.appending(path: currentRelative ?? "").path,
                            logicalBytes: root.totals.logicalBytes, allocatedBytes: root.totals.allocatedBytes,
                            phase: .volumeCatalog, estimatedTotalItems: estimatedTotalItems))
                        lastProgress = clock.now
                    }
                }
                if clock.now - lastProgress >= .milliseconds(120) {
                    await progress(StorageScanProgress(visitedItems: visited, currentPath: rootURL.path,
                        logicalBytes: root.totals.logicalBytes, allocatedBytes: root.totals.allocatedBytes,
                        phase: .volumeCatalog, estimatedTotalItems: estimatedTotalItems))
                    lastProgress = clock.now
                }
            }
        }
        root.childCount = children.count
        var overview = DualTopItems(limit: maximumNodes - 1)
        if root.kind != .package {
            for child in children.values { overview.insert(child.reference()) }
            for package in packages.values { largest.insert(package.reference()) }
        }
        await progress(StorageScanProgress(visitedItems: visited, currentPath: rootURL.path,
            logicalBytes: root.totals.logicalBytes, allocatedBytes: root.totals.allocatedBytes,
            phase: .validatingResults, estimatedTotalItems: estimatedTotalItems))
        try Task.checkCancellation()
        // Catalog-derived references are actionable only after their identities and full
        // visible ancestor chain still match the filesystem. Any mismatch rejects this run.
        for item in overview.values + largest.values {
            guard try StorageDatalessPolicy.withMaterializationDisabled({ _ in
                try StorageFileMetadata.identity(at: rootURL.appending(path: item.relativePath))
            }) == item.identity else {
                throw StorageCatalogScanError.changedItem(path: item.relativePath, reason: "retained item identity changed during final validation")
            }
            for ancestor in item.ancestors {
                guard try StorageDatalessPolicy.withMaterializationDisabled({ _ in
                    try StorageFileMetadata.identity(at: rootURL.appending(path: ancestor.relativePath))
                }) == ancestor.identity else {
                    throw StorageCatalogScanError.changedItem(path: ancestor.relativePath, reason: "retained ancestor identity changed during final validation")
                }
            }
        }
        guard try StorageDatalessPolicy.withMaterializationDisabled({ _ in try StorageFileMetadata.identity(at: rootURL) }) == rootIdentity else {
            throw StorageCatalogScanError.changedItem(path: rootURL.path, reason: "selected root identity changed during final validation")
        }
        let snapshot = try StorageSnapshotBuilder.build(rootURL: rootURL, grantID: grantID, root: root,
            overview: overview.values, largest: largest.values, issues: issues, omittedIssues: omittedIssues,
            authorizationRootPath: authorizationRootPath, authorizationRootIdentity: authorizationRootIdentity,
            rootAncestors: rootAncestors, scanMethod: .volumeCatalog, treeWriter: writer,
            maximumNodes: maximumNodes, largestLimit: largestLimit)
        await progress(StorageScanProgress(visitedItems: visited, currentPath: rootURL.path,
            logicalBytes: root.totals.logicalBytes, allocatedBytes: root.totals.allocatedBytes,
            phase: .validatingResults, estimatedTotalItems: estimatedTotalItems))
        try Task.checkCancellation()
        writer?.completeHandoff()
        return snapshot
    }
}

private struct CatalogDirectoryContext {
    let relativePath: String
    let url: URL
    let identity: StorageFileIdentity
    let ancestors: [StoragePathIdentity]
    let package: String?
    let treeID: Int?
}
private enum CatalogContextResult {
    case visible(CatalogDirectoryContext)
    case excluded
    case mountExcluded
    var value: CatalogDirectoryContext? { if case let .visible(value) = self { value } else { nil } }
}
private struct CatalogLinkIdentity: Hashable {
    let volume: Int
    let identity: StorageFileIdentity
}
private struct CatalogLeafName: Hashable {
    let volume: Int
    let parentInode: UInt64
    let name: Data
}
