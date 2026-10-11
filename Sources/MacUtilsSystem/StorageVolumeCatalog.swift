import Foundation

public struct StorageVolume: Hashable, Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let totalBytes: UInt64?
    public let availableBytes: UInt64?

    public var id: String { url.path }

    public init(url: URL, name: String, totalBytes: UInt64? = nil, availableBytes: UInt64? = nil) {
        self.url = url
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

/// User-visible mounted volumes; hidden APFS implementation volumes are not separate scan targets.
public enum StorageVolumeCatalog {
    public static func mountedVolumes() async -> [StorageVolume] {
        await Task.detached(priority: .utility) {
            StorageDatalessPolicy.withMaterializationDisabled { enabled -> [StorageVolume] in
                // Enumeration also fetches URL properties. Do not start metadata I/O
                // unless the synchronous worker-thread opt-out is available.
                guard enabled else { return [] }
                let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
                let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                    options: [.skipHiddenVolumes]) ?? []
                return urls.map { url in
                    let values = try? url.resourceValues(forKeys: keys)
                    return StorageVolume(url: url, name: values?.volumeName ?? url.lastPathComponent,
                        totalBytes: values?.volumeTotalCapacity.map { UInt64(max(0, $0)) },
                        availableBytes: values?.volumeAvailableCapacity.map { UInt64(max(0, $0)) })
                }.sorted { left, right in
                    if left.url.path == "/" { return right.url.path != "/" }
                    if right.url.path == "/" { return false }
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
            }
        }.value
    }
}
