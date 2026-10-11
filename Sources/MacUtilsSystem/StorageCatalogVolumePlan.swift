import Darwin
import Foundation

struct StorageCatalogPathMapping: Sendable, Equatable {
    let nativePrefix: String
    let visiblePrefix: String
}

enum StorageCatalogVolumePlanError: Error, Equatable {
    case unsupported
    case invalidMapping
    case failed(Int32)
}

/// Translates a kernel catalog's namespace into the selected visible volume.
/// Native identities establish live firmlinks; names from the mapping file alone do not.
struct StorageCatalogVolumePlan: Sendable {
    let volumeURL: URL
    let rootURL: URL
    let mappings: [StorageCatalogPathMapping]
    let excludedVisiblePrefixes: [String]
    let estimatedTotalItems: Int?
    private let filesystemFirst: Int32
    private let filesystemSecond: Int32

    init(mountPath: URL, rootURL: URL, mappings: [StorageCatalogPathMapping],
         excludedVisiblePrefixes: [String] = []) throws {
        var filesystem = statfs()
        guard statfs(mountPath.path, &filesystem) == 0 else { throw StorageCatalogVolumePlanError.failed(errno) }
        self.volumeURL = mountPath.standardizedFileURL
        self.rootURL = rootURL.standardizedFileURL
        self.mappings = mappings.sorted { $0.nativePrefix.count > $1.nativePrefix.count }
        self.excludedVisiblePrefixes = excludedVisiblePrefixes
        filesystemFirst = filesystem.f_fsid.val.0
        filesystemSecond = filesystem.f_fsid.val.1
        var countAttributes = attrlist()
        countAttributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        countAttributes.volattr = ATTR_VOL_INFO | UInt32(ATTR_VOL_FILECOUNT | ATTR_VOL_DIRCOUNT)
        var countBytes = [UInt8](repeating: 0, count: 12)
        let countStatus = countBytes.withUnsafeMutableBytes {
            getattrlist(mountPath.path, &countAttributes, $0.baseAddress!, $0.count, 0)
        }
        estimatedTotalItems = countStatus == 0 ? countBytes.withUnsafeBytes {
            guard $0.loadUnaligned(as: UInt32.self) == countBytes.count else { return nil }
            let count = Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                + Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            return count > 0 ? count : nil
        } : nil
    }

    func resolve(inode: UInt64) throws -> URL {
        var filesystem = fsid_t(val: (filesystemFirst, filesystemSecond))
        var bytes = [CChar](repeating: 0, count: 8_192)
        let count = bytes.withUnsafeMutableBufferPointer {
            fsgetpath($0.baseAddress!, $0.count, &filesystem, inode)
        }
        guard count > 0, count <= bytes.count else { throw StorageCatalogVolumePlanError.failed(errno) }
        let raw = bytes.prefix(count - 1).map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: raw, encoding: .utf8), path.hasPrefix("/"), !path.contains("\0") else {
            throw StorageCatalogVolumePlanError.invalidMapping
        }
        return URL(fileURLWithPath: path)
    }

    func visibleRelativePath(nativePath: String) -> String? {
        guard nativePath.hasPrefix("/"), !nativePath.contains("\0"),
              nativePath == "/" || nativePath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        guard let mapping = mappings.first(where: { Self.contains(nativePath, under: $0.nativePrefix) }) else { return nil }
        let suffix = nativePath == mapping.nativePrefix ? ""
            : String(nativePath.dropFirst(mapping.nativePrefix == "/" ? 1 : mapping.nativePrefix.count + 1))
        let visible = suffix.isEmpty ? mapping.visiblePrefix
            : (mapping.visiblePrefix == "/" ? "/" + suffix : mapping.visiblePrefix + "/" + suffix)
        guard !excludedVisiblePrefixes.contains(where: { Self.contains(visible, under: $0) }),
              Self.contains(visible, under: rootURL.path) else { return nil }
        return visible == rootURL.path ? "" : String(visible.dropFirst(rootURL.path == "/" ? 1 : rootURL.path.count + 1))
    }

    static func plans(for rootURL: URL) throws -> [Self] {
        let root = rootURL.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isVolumeKey])
        guard values.isVolume == true else { throw StorageCatalogVolumePlanError.unsupported }
        var filesystem = statfs()
        guard statfs(root.path, &filesystem) == 0 else { throw StorageCatalogVolumePlanError.failed(errno) }
        let type = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        // APFS has no directory hardlinks. Other formats keep the existing traversal path.
        guard type == "apfs" else { throw StorageCatalogVolumePlanError.unsupported }
        var ordinaryMappings = [StorageCatalogPathMapping(nativePrefix: root.path, visiblePrefix: root.path)]
        if root.path == "/System/Volumes/Data" {
            ordinaryMappings.append(StorageCatalogPathMapping(nativePrefix: "/", visiblePrefix: root.path))
        }
        let ordinary = try Self(mountPath: root, rootURL: root, mappings: ordinaryMappings)
        guard root.path == "/" else { return [ordinary] }

        let data = URL(fileURLWithPath: "/System/Volumes/Data")
        var dataFilesystem = statfs()
        guard statfs(data.path, &dataFilesystem) == 0,
              dataFilesystem.f_fsid.val != filesystem.f_fsid.val else { return [ordinary] }
        guard try data.resourceValues(forKeys: [.isVolumeKey]).isVolume == true else {
            throw StorageCatalogVolumePlanError.unsupported
        }
        let text = try String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)
        let pairs = try parseFirmlinks(text)
        var dataMappings: [StorageCatalogPathMapping] = []
        for pair in pairs {
            let source = URL(fileURLWithPath: pair.visiblePrefix)
            let target = URL(fileURLWithPath: pair.nativePrefix)
            var sourceStat = stat(), targetStat = stat()
            let sourceStatus = lstat(source.path, &sourceStat)
            let sourceError = sourceStatus == 0 ? 0 : errno
            let targetStatus = lstat(target.path, &targetStat)
            let targetError = targetStatus == 0 ? 0 : errno
            // A listed firmlink can be absent from the live visible namespace (for example /pkg).
            // Its Data target is not part of the user's selected visible startup disk.
            if sourceStatus != 0 && sourceError == ENOENT { continue }
            var sourceFilesystem = statfs()
            if sourceStatus == 0, statfs(source.path, &sourceFilesystem) == 0,
               sourceFilesystem.f_fsid.val != dataFilesystem.f_fsid.val { continue }
            guard sourceStatus == 0, targetStatus == 0, targetError == 0,
                  sourceStat.st_mode & S_IFMT == S_IFDIR, targetStat.st_mode & S_IFMT == S_IFDIR,
                  StorageFileMetadata.identity(sourceStat) == StorageFileMetadata.identity(targetStat),
                  sourceFilesystem.f_fsid.val == dataFilesystem.f_fsid.val else {
                throw StorageCatalogVolumePlanError.invalidMapping
            }
            dataMappings.append(pair)
        }
        guard !dataMappings.isEmpty else { throw StorageCatalogVolumePlanError.unsupported }
        let system = try Self(mountPath: root, rootURL: root,
            mappings: ordinary.mappings, excludedVisiblePrefixes: dataMappings.map(\.visiblePrefix))
        // fsgetpath may already return the visible firmlink path, even for the Data fsid.
        // Both spellings refer to the same identities verified above.
        let visibleDataMappings = dataMappings.map {
            StorageCatalogPathMapping(nativePrefix: $0.visiblePrefix, visiblePrefix: $0.visiblePrefix)
        }
        let userData = try Self(mountPath: data, rootURL: root, mappings: dataMappings + visibleDataMappings)
        return [system, userData]
    }

    static func parseFirmlinks(_ text: String) throws -> [StorageCatalogPathMapping] {
        var results: [StorageCatalogPathMapping] = []
        var sources: Set<String> = []
        var destinations: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { throw StorageCatalogVolumePlanError.invalidMapping }
            let source = fields[0], target = fields[1]
            guard source.hasPrefix("/"), source != "/", !target.hasPrefix("/"), !target.isEmpty,
                  !source.contains("\0"), !target.contains("\0"),
                  source.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  target.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  sources.insert(source).inserted, destinations.insert(target).inserted else {
                throw StorageCatalogVolumePlanError.invalidMapping
            }
            results.append(StorageCatalogPathMapping(nativePrefix: "/System/Volumes/Data/" + target, visiblePrefix: source))
        }
        guard !results.isEmpty else { throw StorageCatalogVolumePlanError.invalidMapping }
        return results
    }

    private static func contains(_ path: String, under prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix == "/" ? "/" : prefix + "/")
    }
}
