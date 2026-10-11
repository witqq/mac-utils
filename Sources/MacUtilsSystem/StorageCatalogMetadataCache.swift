import Darwin
import Foundation
import MacUtilsCore

/// Thread policy never spans suspension: callers supply a synchronous operation and the
/// original worker-thread policy is restored on success, error and cancellation.
enum StorageDatalessPolicy {
    static func withMaterializationDisabled<T>(_ operation: (Bool) throws -> T) rethrows -> T {
        let incomingError = errno
        let original = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        if original == IOPOL_MATERIALIZE_DATALESS_FILES_OFF {
            errno = incomingError
            return try operation(true)
        }
        guard original >= 0, setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            errno = incomingError
            return try operation(false)
        }
        errno = incomingError
        defer {
            let operationError = errno
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, original)
            errno = operationError
        }
        return try operation(true)
    }
}

enum StorageDatalessPolicyError: Error, CustomStringConvertible {
    case unavailable
    var description: String { "Dataless materialization protection could not be enabled; storage metadata I/O was not started." }
}

/// Supplementary metadata only: searchfs remains the sole source of catalog entries and
/// byte totals. Complete small-parent maps avoid individual leaf syscalls. Oversized,
/// unreadable and unsupported parents use the original no-follow leaf lookup instead.
final class StorageCatalogMetadataCache {
    private enum Parent {
        case metadata([String: stat])
        var count: Int { if case let .metadata(values) = self { values.count } else { 0 } }
    }
    private let maximumParents: Int
    private let maximumEntries: Int
    private let maximumParentEntries: Int
    private let maximumBypassedParents: Int
    private let openDirectory: (String) -> CInt
    private var parents: [StorageFileIdentity: Parent] = [:]
    private var order: [StorageFileIdentity] = []
    // Two million 32-byte identities cover large developer disks. Swift Set bucket
    // capacity adds overhead; history remains bounded and does not retain file names.
    private var bypassed: Set<StorageFileIdentity> = []
    private var populateBulkCache = true
    private(set) var cachedEntryCount = 0
    var cachedParentCount: Int { parents.count }
    var bypassedParentCount: Int { bypassed.count }

    init(maximumParents: Int = 64, maximumEntries: Int = 32_768, maximumParentEntries: Int = 4_096,
         maximumBypassedParents: Int = 2_000_000,
         openDirectory: @escaping (String) -> CInt = { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }) {
        self.maximumParents = max(1, maximumParents); self.maximumEntries = max(1, maximumEntries)
        self.maximumParentEntries = max(1, min(maximumParentEntries, maximumEntries))
        self.maximumBypassedParents = max(1, maximumBypassedParents)
        self.openDirectory = openDirectory
    }

    func metadata(name: String, parentURL: URL, parentIdentity: StorageFileIdentity) throws -> stat {
        try Task.checkCancellation()
        if case let .metadata(values)? = parents[parentIdentity], let metadata = values[name] { return metadata }
        return try StorageDatalessPolicy.withMaterializationDisabled { disabled in
            // TN3150 documents getattrlistbulk materialization. Never call it without the
            // documented opt-out; a smaller attribute request is not a safety guarantee.
            guard disabled else { throw StorageDatalessPolicyError.unavailable }
            if parents[parentIdentity] == nil, populateBulkCache, !bypassed.contains(parentIdentity) {
                guard let values = try readParent(parentURL, identity: parentIdentity) else {
                    markBypassed(parentIdentity)
                    return try StorageFileMetadata.read(at: parentURL.appending(path: name))
                }
                let parent = Parent.metadata(values)
                while parents.count >= maximumParents || cachedEntryCount + parent.count > maximumEntries {
                    let removed = order.removeFirst()
                    cachedEntryCount -= parents.removeValue(forKey: removed)?.count ?? 0
                    markBypassed(removed)
                }
                parents[parentIdentity] = parent; order.append(parentIdentity); cachedEntryCount += parent.count
            }
            if case let .metadata(values)? = parents[parentIdentity], let metadata = values[name] { return metadata }
            return try StorageFileMetadata.read(at: parentURL.appending(path: name))
        }
    }

    private func markBypassed(_ identity: StorageFileIdentity) {
        guard !bypassed.contains(identity) else { return }
        guard bypassed.count < maximumBypassedParents else {
            // Evicting bypass markers would make cyclic workloads enumerate large parents
            // repeatedly. Once the bounded history fills, use protected individual metadata.
            populateBulkCache = false
            return
        }
        bypassed.insert(identity)
    }

    private func readParent(_ url: URL, identity: StorageFileIdentity) throws -> [String: stat]? {
        let descriptor = openDirectory(url.path)
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { close(descriptor); return nil }
        guard metadata.st_mode & S_IFMT == S_IFDIR, StorageFileMetadata.identity(metadata) == identity else {
            close(descriptor)
            throw StorageCatalogScanError.changedItem(path: url.path, reason: "opened metadata-cache parent identity differs from checked ancestor")
        }
        let reader = try StorageDirectoryReader(descriptor: descriptor, bulk: true, metadataMode: .identityAndType)
        var values: [String: stat] = [:]
        do {
            while let entry = try reader.next() {
                try Task.checkCancellation()
                guard reader.isUsingBulk else { return nil }
                if entry.name == "." || entry.name == ".." { continue }
                guard values.count < maximumParentEntries else { return nil }
                if let metadata = entry.metadata { values[entry.name] = metadata }
                else {
                    var fallback = stat()
                    if fstatat(reader.descriptor, entry.name, &fallback, AT_SYMLINK_NOFOLLOW) != 0 { return nil }
                    values[entry.name] = fallback
                }
            }
            return values
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
        // The reader owns its descriptor and closes it on every exit; no FD is cached.
    }
}
