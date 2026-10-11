import Foundation
@testable import MacUtilsSystem
import Testing

@Test func storageCatalogVolumePlanMapsWholeComponentsAndSuppressesSystemShadows() throws {
    let root = URL(fileURLWithPath: "/")
    let system = try StorageCatalogVolumePlan(mountPath: root, rootURL: root,
        mappings: [.init(nativePrefix: "/", visiblePrefix: "/")], excludedVisiblePrefixes: ["/Users"])
    #expect(system.visibleRelativePath(nativePath: "/System/Library") == "System/Library")
    #expect(system.visibleRelativePath(nativePath: "/Users/mike") == nil)
    #expect(system.visibleRelativePath(nativePath: "/UsersOther") == "UsersOther")
    let data = try StorageCatalogVolumePlan(mountPath: root, rootURL: root,
        mappings: [.init(nativePrefix: "/System/Volumes/Data/Users", visiblePrefix: "/Users")])
    #expect(data.visibleRelativePath(nativePath: "/System/Volumes/Data/Users") == "Users")
    #expect(data.visibleRelativePath(nativePath: "/System/Volumes/Data/Users/mike/file") == "Users/mike/file")
    #expect(data.visibleRelativePath(nativePath: "/System/Volumes/Data/UsersOther") == nil)
    #expect(data.visibleRelativePath(nativePath: "/System/Volumes/Data/.Spotlight-V100") == nil)
    #expect(data.visibleRelativePath(nativePath: "/System/Volumes/Data/Users/../private") == nil)
}

@Test func storageCatalogVolumePlanRejectsAmbiguousOrTraversingFirmlinks() throws {
    let parsed = try StorageCatalogVolumePlan.parseFirmlinks("/Users\tUsers\n/usr/local\tusr/local\n")
    #expect(parsed.count == 2)
    #expect(parsed[0].nativePrefix == "/System/Volumes/Data/Users")
    for invalid in ["", "/\tUsers", "/Users\t../Users", "/Users\t/Users", "/Users\tUsers\n/Users\tOther", "/Users\tUsers\n/Other\tUsers", "/Users\tUsers\textra", "/Users//a\tUsers"] {
        #expect(throws: StorageCatalogVolumePlanError.self) { try StorageCatalogVolumePlan.parseFirmlinks(invalid) }
    }
}

@Test func storageCatalogVolumePlanRejectsOrdinaryFolderAsVolume() throws {
    #expect(throws: StorageCatalogVolumePlanError.unsupported) {
        try StorageCatalogVolumePlan.plans(for: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
    }
}

@Test func storageCatalogVolumePlanNativeStartupMapsUsersAndApplicationsExactlyOnce() throws {
    let plans = try StorageCatalogVolumePlan.plans(for: URL(fileURLWithPath: "/"))
    #expect(plans.count == 2)
    for path in ["/Users", "/Applications", "/private"] {
        let identity = try StorageFileMetadata.identity(at: URL(fileURLWithPath: path))
        let resolved = plans.compactMap { plan -> String? in
            let native = try? plan.resolve(inode: identity.inode)
            return native.flatMap { plan.visibleRelativePath(nativePath: $0.path) }
        }
        #expect(resolved == [String(path.dropFirst())])
    }
}
