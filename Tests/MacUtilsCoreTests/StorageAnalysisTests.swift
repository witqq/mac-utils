import Foundation
import MacUtilsCore
import Testing

private func storageIdentity(_ inode: UInt64) -> StorageFileIdentity {
    StorageFileIdentity(device: 1, inode: inode, birthSeconds: 1, birthNanoseconds: 0)
}

@Test func flatStorageSnapshotsEncodeAndValidateDeepHierarchyWithoutRecursiveNodes() throws {
    let count = 2_000
    var nodes: [StorageNode] = []
    var path = ""
    for index in 0..<count {
        if index > 0 { path = path.isEmpty ? "d" : path + "/d" }
        nodes.append(StorageNode(id: index, parentID: index == 0 ? nil : index - 1,
            name: index == 0 ? "Root" : "d", relativePath: path,
            kind: index == count - 1 ? .file : .directory, identity: storageIdentity(UInt64(index)),
            logicalBytes: 1, allocatedBytes: 4_096, apparentBytes: 1, fileCount: 1))
    }
    let expected = StorageSnapshot(grantID: UUID(), rootPath: "/fixture", rootIdentity: storageIdentity(0), nodes: nodes, issues: [])
    try expected.validate()
    let bytes = try JSONEncoder().encode(expected)
    let restored = try JSONDecoder().decode(StorageSnapshot.self, from: bytes)
    try restored.validate()
    #expect(restored.nodes == nodes)
    #expect(restored.breadcrumbs(to: count - 1).count == count)
    #expect(restored.children(of: count - 2).first?.id == count - 1)
}

@Test func storageSnapshotValidationRejectsEscapingPathsCyclesAndIncorrectSubtreeTotals() throws {
    let root = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: storageIdentity(0), logicalBytes: 3, allocatedBytes: 4_096, apparentBytes: 3, fileCount: 1)
    let file = StorageNode(id: 1, parentID: 0, name: "a", relativePath: "a", kind: .file,
        identity: storageIdentity(1), logicalBytes: 3, allocatedBytes: 4_096, apparentBytes: 3, fileCount: 1)
    let good = StorageSnapshot(grantID: UUID(), rootPath: "/fixture", rootIdentity: root.identity, nodes: [root, file], issues: [])
    try good.validate()
    let escaping = StorageNode(id: 1, parentID: 0, name: "../other", relativePath: "../other", kind: .file,
        identity: file.identity, logicalBytes: 3, allocatedBytes: 4_096, apparentBytes: 3, fileCount: 1)
    let cycle = StorageNode(id: 1, parentID: 1, name: "a", relativePath: "a", kind: .file,
        identity: file.identity, logicalBytes: 3, allocatedBytes: 4_096, apparentBytes: 3, fileCount: 1)
    let wrongTotals = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: root.identity, logicalBytes: 30, allocatedBytes: 4_096, apparentBytes: 3, fileCount: 1)
    for nodes in [[root, escaping], [root, cycle], [wrongTotals, file]] {
        let invalid = StorageSnapshot(grantID: UUID(), rootPath: "/fixture", rootIdentity: root.identity, nodes: nodes, issues: [])
        #expect(throws: StorageSnapshotValidationError.self) { try invalid.validate() }
    }
}

@Test func storageSizeMetricsSortIndependentlyAndKeepLargestUInt64SizesExact() throws {
    let root = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: storageIdentity(0), logicalBytes: UInt64.max, allocatedBytes: 20, apparentBytes: UInt64.max, fileCount: 2)
    let sparse = StorageNode(id: 1, parentID: 0, name: "sparse", relativePath: "sparse", kind: .file,
        identity: storageIdentity(1), logicalBytes: UInt64.max - 1, allocatedBytes: 0, apparentBytes: UInt64.max - 1, fileCount: 1)
    let ordinary = StorageNode(id: 2, parentID: 0, name: "ordinary", relativePath: "ordinary", kind: .file,
        identity: storageIdentity(2), logicalBytes: 1, allocatedBytes: 20, apparentBytes: 1, fileCount: 1)
    let snapshot = StorageSnapshot(grantID: UUID(), rootPath: "/fixture", rootIdentity: root.identity, nodes: [root, sparse, ordinary], issues: [])
    try snapshot.validate()
    #expect(snapshot.children(of: 0, metric: .logical).map(\.id) == [1, 2])
    #expect(snapshot.children(of: 0, metric: .allocated).map(\.id) == [2, 1])
    #expect(snapshot.largestFiles(metric: .logical, limit: 1).map(\.id) == [1])
    #expect(snapshot.root?.bytes(for: .logical) == UInt64.max)
    #expect(snapshot.largestFiles(limit: 0).isEmpty)
}

@Test func legacyStorageSnapshotBytesDecodeWithoutOverviewFields() throws {
    let root = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: storageIdentity(0), logicalBytes: 0, allocatedBytes: 0, apparentBytes: 0, fileCount: 0)
    let original = StorageSnapshot(grantID: UUID(), rootPath: "/fixture", rootIdentity: root.identity, nodes: [root], issues: [])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    for key in ["savedLargestCatalog", "savedAuthorizationRootPath", "savedAuthorizationRootIdentity", "savedRootAncestors", "savedScanMethod"] { object.removeValue(forKey: key) }
    var nodeObjects = try #require(object["nodes"] as? [[String: Any]])
    nodeObjects[0].removeValue(forKey: "unlistedTotals")
    nodeObjects[0].removeValue(forKey: "unlistedCount")
    object["nodes"] = nodeObjects
    let decoded = try JSONDecoder().decode(StorageSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    try decoded.validate()
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.root?.unlistedChildren == .zero)
    #expect(decoded.authorizationRootPath == decoded.rootPath)
    #expect(decoded.authorizationRootIdentity == decoded.rootIdentity)
    #expect(decoded.largestCatalog.isEmpty)
    #expect(decoded.scanMethod == .directoryTraversal)
    #expect(!decoded.hasUnverifiedCoverage)
    #expect(decoded.isComplete)
    #expect(decoded.id == original.id)
}

@Test func storageOverviewValidationChecksOmittedTotalsAndFullCatalogProof() throws {
    let totals = StorageTotals(logicalBytes: 100, allocatedBytes: 4_096, apparentBytes: 100, fileCount: 1)
    let root = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: storageIdentity(0), logicalBytes: 100, allocatedBytes: 4_096, apparentBytes: 100, fileCount: 1,
        unlistedChildren: totals, unlistedChildCount: 1)
    let proof = [StoragePathIdentity(relativePath: "", identity: root.identity), StoragePathIdentity(relativePath: "deep", identity: storageIdentity(1))]
    let file = StorageItemReference(id: 1, name: "large", relativePath: "deep/large", kind: .file,
        identity: storageIdentity(2), totals: totals, ancestors: proof)
    let good = StorageSnapshot(grantID: UUID(), rootPath: "/fixture", rootIdentity: root.identity, nodes: [root], issues: [], schemaVersion: 2, largestCatalog: [file], scanMethod: .volumeCatalog)
    try good.validate()
    #expect(!good.isComplete)
    #expect(good.hasUnverifiedCoverage)
    #expect(good.itemReference(id: 1) == file)
    #expect(good.largestItems().first == file)
    let decodedCatalog = try JSONDecoder().decode(StorageSnapshot.self, from: JSONEncoder().encode(good))
    #expect(decodedCatalog.scanMethod == .volumeCatalog)
    #expect(decodedCatalog.hasUnverifiedCoverage)
    #expect(!decodedCatalog.isComplete)
    let badProof = StorageItemReference(id: 1, name: "large", relativePath: "deep/large", kind: .file,
        identity: file.identity, totals: totals, ancestors: Array(proof.prefix(1)))
    let invalid = StorageSnapshot(grantID: good.grantID, rootPath: good.rootPath, rootIdentity: root.identity,
        nodes: [root], issues: [], schemaVersion: 2, largestCatalog: [badProof])
    #expect(throws: StorageSnapshotValidationError.self) { try invalid.validate() }
    let wrong = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: root.identity, logicalBytes: 101, allocatedBytes: 4_096, apparentBytes: 100, fileCount: 1,
        unlistedChildren: totals, unlistedChildCount: 1)
    #expect(throws: StorageSnapshotValidationError.self) {
        try StorageSnapshot(grantID: good.grantID, rootPath: good.rootPath, rootIdentity: root.identity, nodes: [wrong], issues: [], schemaVersion: 2).validate()
    }
    let inconsistentOmissions = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: root.identity, logicalBytes: 100, allocatedBytes: 4_096, apparentBytes: 100, fileCount: 1,
        unlistedChildren: totals, unlistedChildCount: 0)
    #expect(throws: StorageSnapshotValidationError.self) {
        try StorageSnapshot(grantID: good.grantID, rootPath: good.rootPath, rootIdentity: root.identity,
            nodes: [inconsistentOmissions], issues: [], schemaVersion: 2).validate()
    }
    let invalidIdentity = StorageFileIdentity(device: 1, inode: 2, birthSeconds: 1, birthNanoseconds: 1_000_000_000)
    for (itemTotals, identity) in [
        (StorageTotals(logicalBytes: 101, allocatedBytes: 4_096, apparentBytes: 100, fileCount: 1), file.identity),
        (StorageTotals(logicalBytes: 100, allocatedBytes: 4_097, apparentBytes: 100, fileCount: 1), file.identity),
        (StorageTotals(logicalBytes: 100, allocatedBytes: 4_096, apparentBytes: 101, fileCount: 1), file.identity),
        (StorageTotals(logicalBytes: 100, allocatedBytes: 4_096, apparentBytes: 100, fileCount: 2), file.identity),
        (totals, invalidIdentity),
    ] {
        let invalidItem = StorageItemReference(id: 1, name: "large", relativePath: "deep/large", kind: .file,
            identity: identity, totals: itemTotals, ancestors: proof)
        #expect(throws: StorageSnapshotValidationError.self) {
            try StorageSnapshot(grantID: good.grantID, rootPath: good.rootPath, rootIdentity: root.identity,
                nodes: [root], issues: [], schemaVersion: 2, largestCatalog: [invalidItem]).validate()
        }
    }
    // Omitted empty directories can contribute no bytes and no regular files.
    let emptyDirectories = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: root.identity, logicalBytes: 0, allocatedBytes: 0, apparentBytes: 0, fileCount: 0,
        unlistedChildren: .zero, unlistedChildCount: 2)
    try StorageSnapshot(grantID: good.grantID, rootPath: good.rootPath, rootIdentity: root.identity,
        nodes: [emptyDirectories], issues: [], schemaVersion: 2).validate()
}

@Test(arguments: [StorageScanMethod.directoryTraversal, .volumeCatalog])
func storageZeroIssueSnapshotCompletenessRetainsItsCoverageMeaningAfterRoundTrip(method: StorageScanMethod) throws {
    let root = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: storageIdentity(0), logicalBytes: 0, allocatedBytes: 0, apparentBytes: 0, fileCount: 0)
    let snapshot = StorageSnapshot(grantID: UUID(), rootPath: "/fixture", rootIdentity: root.identity,
        nodes: [root], issues: [], scanMethod: method)
    let restored = try JSONDecoder().decode(StorageSnapshot.self, from: JSONEncoder().encode(snapshot))
    try restored.validate()
    #expect(restored.issues.isEmpty)
    #expect(restored.omittedIssueCount == 0)
    #expect(restored.nodes.allSatisfy { !$0.isIncomplete })
    #expect(restored.hasUnverifiedCoverage == (method == .volumeCatalog))
    #expect(restored.isComplete == (method == .directoryTraversal))
}

@Test func storageTreeManifestRetainsSparseCanonicalIDsAndExactSizesAcrossReopen() throws {
    let id = UUID()
    let root = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: storageIdentity(0), logicalBytes: UInt64.max, allocatedBytes: 8,
        apparentBytes: UInt64.max, fileCount: 1)
    let leaf = StorageNode(id: 91, parentID: 0, name: "large", relativePath: "large", kind: .file,
        identity: storageIdentity(91), logicalBytes: UInt64.max, allocatedBytes: 8,
        apparentBytes: UInt64.max, fileCount: 1)
    let tree = StorageTreeDescriptor(id: id, nodeCount: 100, rootChildCount: 1)
    let source = StorageSnapshot(id: id, grantID: UUID(), rootPath: "/fixture", rootIdentity: root.identity,
        nodes: [root, leaf], issues: [], schemaVersion: 3, scanMethod: .volumeCatalog, tree: tree)
    let restored = try JSONDecoder().decode(StorageSnapshot.self, from: JSONEncoder().encode(source))
    try restored.validate()
    #expect(restored.tree == tree)
    #expect(restored.node(id: 91) == leaf)
    #expect(restored.node(id: 1) == nil)
    #expect(restored.itemReference(id: 91)?.logicalBytes == UInt64.max)
    #expect(restored.itemReference(id: 91)?.ancestors == [StoragePathIdentity(relativePath: "", identity: root.identity)])
    #expect(restored.hasUnverifiedCoverage && !restored.isComplete)
}

@Test func storageTreeManifestRejectsAnotherGenerationAndInvalidSparseBindings() throws {
    let id = UUID()
    let root = StorageNode(id: 0, parentID: nil, name: "Root", relativePath: "", kind: .directory,
        identity: storageIdentity(0), logicalBytes: 0, allocatedBytes: 0, apparentBytes: 0, fileCount: 0)
    for descriptor in [
        StorageTreeDescriptor(id: UUID(), nodeCount: 1, rootChildCount: 0),
        StorageTreeDescriptor(id: id, formatVersion: 3, nodeCount: 1, rootChildCount: 0),
        StorageTreeDescriptor(id: id, nodeCount: 0, rootChildCount: 0),
        StorageTreeDescriptor(id: id, nodeCount: 2, rootChildCount: 1),
    ] {
        #expect(throws: StorageSnapshotValidationError.self) {
            try StorageSnapshot(id: id, grantID: UUID(), rootPath: "/fixture", rootIdentity: root.identity,
                nodes: [root], issues: [], schemaVersion: 3, tree: descriptor).validate()
        }
    }
    #expect(throws: StorageSnapshotValidationError.self) {
        try StorageSnapshot(id: id, grantID: UUID(), rootPath: "/fixture", rootIdentity: root.identity,
            nodes: [root], issues: [], schemaVersion: 3).validate()
    }
}

@Test func storagePackageMembershipSurvivesCanonicalReferenceSerializationWithoutChangingLegacyDefaults() throws {
    let reference = StorageItemReference(id: 7, name: "asset", relativePath: "Sample.app/asset", kind: .file,
        identity: storageIdentity(7), totals: .zero, ancestors: [], isInsidePackage: true)
    let restored = try JSONDecoder().decode(StorageItemReference.self, from: JSONEncoder().encode(reference))
    #expect(restored.isInsidePackage)
    let legacy = StorageItemReference(id: 1, name: "file", relativePath: "file", kind: .file,
        identity: storageIdentity(1), totals: .zero, ancestors: [])
    let legacyBytes = try JSONEncoder().encode(legacy)
    let object = try #require(JSONSerialization.jsonObject(with: legacyBytes) as? [String: Any])
    #expect(object["savedInsidePackage"] == nil)
    #expect(try JSONDecoder().decode(StorageItemReference.self, from: legacyBytes) == legacy)
}
