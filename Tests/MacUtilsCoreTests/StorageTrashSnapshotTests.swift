import Foundation
import MacUtilsCore
import Testing

@Test(arguments: [1, 2])
func storageTreeDescriptorFormatsPreserveSparseIdentityBoundsAndRoundTrip(format: Int) throws {
    let identity = StorageFileIdentity(device: 1, inode: 2, birthSeconds: 3, birthNanoseconds: 4)
    let id = UUID()
    let snapshot = StorageSnapshot(id: id, grantID: UUID(), rootPath: "/fixture", rootIdentity: identity,
        scannedAt: Date(timeIntervalSince1970: 100), nodes: [
            StorageNode(id: 0, parentID: nil, name: "fixture", relativePath: "", kind: .directory,
                identity: identity, logicalBytes: 5, allocatedBytes: 0, apparentBytes: 5, fileCount: 1),
            StorageNode(id: 2, parentID: 0, name: "kept", relativePath: "kept", kind: .file,
                identity: identity, logicalBytes: 5, allocatedBytes: 0, apparentBytes: 5, fileCount: 1)
        ], issues: [], schemaVersion: 3,
        tree: StorageTreeDescriptor(id: id, formatVersion: format, nodeCount: 3, rootChildCount: 1))
    try snapshot.validate()
    #expect(snapshot.node(id: 1) == nil && snapshot.node(id: 2)?.name == "kept")
    let restored = try JSONDecoder().decode(StorageSnapshot.self, from: JSONEncoder().encode(snapshot))
    try restored.validate()
    #expect(restored == snapshot)
    let altered = StorageSnapshot(id: id, grantID: snapshot.grantID, rootPath: snapshot.rootPath,
        rootIdentity: identity, scannedAt: snapshot.scannedAt, nodes: snapshot.nodes,
        issues: [StorageScanIssue(path: "kept", reason: .unreadable, message: "changed")],
        schemaVersion: 3, tree: snapshot.tree)
    #expect(altered.id == snapshot.id && altered != snapshot)
}
