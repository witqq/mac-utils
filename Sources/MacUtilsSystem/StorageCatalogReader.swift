import Darwin
import Foundation

struct StorageCatalogEntry: Sendable, Equatable {
    let name: String
    let inode: UInt64
    let parentInode: UInt64
    let device: UInt64
    let type: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let flags: UInt32
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let linkCount: UInt32

    /// The parent/name key lives in SQLite; retain the complete remaining historical
    /// record there so repeated kernel matches can be distinguished from live changes.
    var indexSignature: Data {
        var result = Data()
        for value in [inode, parentInode, device, UInt64(type), UInt64(bitPattern: birthSeconds),
                      UInt64(bitPattern: birthNanoseconds), UInt64(flags), logicalBytes, allocatedBytes, UInt64(linkCount)] {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { result.append(contentsOf: $0) }
        }
        return result
    }
}

enum StorageCatalogReaderError: Error, Equatable, CustomStringConvertible {
    case unsupported
    /// Previously returned batches must be discarded; the kernel cannot resume this catalog.
    case catalogChanged
    case invalidRecord
    case failed(Int32)
    var description: String {
        switch self {
        case .unsupported: "The volume does not support the requested catalog API."
        case .catalogChanged: "searchfs could not resume: the filesystem catalog generation changed (EBUSY)."
        case .invalidRecord: "The catalog API returned an invalid or truncated metadata record."
        case let .failed(code): "Catalog API error \(code): \(String(cString: strerror(code)))"
        }
    }
}

struct StorageCatalogBatch: Sendable {
    let entries: [StorageCatalogEntry]
    let isComplete: Bool
}

/// Reads the mounted volume's catalog through the public kernel interface. It never opens
/// file contents or devices. Callers own namespace reconstruction and must discard partial
/// batches if a later call reports `catalogChanged` or another error.
protocol StorageCatalogReading: AnyObject {
    func nextBatch() throws -> StorageCatalogBatch
}

final class StorageCatalogReader: StorageCatalogReading {
    private let path: String
    private let device: UInt64
    private let maximumMatches: UInt32
    private var state = searchstate()
    private var started = false
    private var complete = false
    private var terminalError: StorageCatalogReaderError?
    private var bytes = [UInt8](repeating: 0, count: 1_024 * 1_024)

    init(volumeURL: URL, maximumMatches: UInt32 = 4_096) throws {
        let volumePath = volumeURL.path
        path = volumePath
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = ATTR_VOL_INFO | UInt32(ATTR_VOL_CAPABILITIES)
        var capabilities = [UInt8](repeating: 0, count: 4 + MemoryLayout<vol_capabilities_attr_t>.size)
        let status = capabilities.withUnsafeMutableBytes {
            getattrlist(volumePath, &attributes, $0.baseAddress!, $0.count, 0)
        }
        guard status == 0 else { throw StorageCatalogReaderError.failed(errno) }
        let supported = capabilities.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        let valid = capabilities.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }
        guard supported & valid & UInt32(VOL_CAP_INT_SEARCHFS) != 0 else { throw StorageCatalogReaderError.unsupported }
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { throw StorageCatalogReaderError.failed(errno) }
        device = UInt64(UInt32(bitPattern: metadata.st_dev))
        self.maximumMatches = max(1, min(maximumMatches, 4_096))
    }

    func nextBatch() throws -> StorageCatalogBatch {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        if complete { return StorageCatalogBatch(entries: [], isComplete: true) }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_FLAGS)
        attributes.commonattr |= UInt32(ATTR_CMN_FILEID | ATTR_CMN_PARENTID)
        attributes.fileattr = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
        var lower: UInt32 = 4
        var upper: UInt32 = 4
        var request = fssearchblock()
        request.maxmatches = UInt(maximumMatches)
        request.timelimit.tv_usec = 100_000
        request.searchattrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.sizeofsearchparams1 = 4
        request.sizeofsearchparams2 = 4
        var count: UInt = 0
        var options = UInt32(SRCHFS_MATCHFILES | SRCHFS_MATCHDIRS)
        if !started { options |= UInt32(SRCHFS_START) }
        let status = withUnsafeMutablePointer(to: &attributes) { attributesPointer in
            withUnsafeMutablePointer(to: &lower) { lowerPointer in
                withUnsafeMutablePointer(to: &upper) { upperPointer in
                    bytes.withUnsafeMutableBytes { buffer in
                        request.returnattrs = attributesPointer
                        request.searchparams1 = UnsafeMutableRawPointer(lowerPointer)
                        request.searchparams2 = UnsafeMutableRawPointer(upperPointer)
                        request.returnbuffer = buffer.baseAddress!
                        request.returnbuffersize = buffer.count
                        return searchfs(path, &request, &count, 0x08000103, options, &state)
                    }
                }
            }
        }
        let error = status == 0 ? 0 : errno
        do {
            try Self.validateResult(status: status, error: error)
            started = true
            let entries = try bytes.withUnsafeBytes { try Self.decode($0, count: Int(count), device: device) }
            try Task.checkCancellation()
            complete = status == 0
            return StorageCatalogBatch(entries: entries, isComplete: complete)
        } catch let failure as StorageCatalogReaderError {
            terminalError = failure
            throw failure
        }
    }

    static func validateResult(status: Int32, error: Int32) throws {
        guard status != 0 else { return }
        switch error {
        case EAGAIN: return // Partial matches are valid even when the time limit expires.
        case EBUSY: throw StorageCatalogReaderError.catalogChanged
        case ENOTSUP: throw StorageCatalogReaderError.unsupported
        default: throw StorageCatalogReaderError.failed(error)
        }
    }

    static func decode(_ buffer: UnsafeRawBufferPointer, count: Int, device: UInt64) throws -> [StorageCatalogEntry] {
        guard count >= 0, count <= 4_096 else { throw StorageCatalogReaderError.invalidRecord }
        var entries: [StorageCatalogEntry] = []
        entries.reserveCapacity(count)
        var start = 0
        for _ in 0..<count {
            guard start + 4 <= buffer.count else { throw StorageCatalogReaderError.invalidRecord }
            let length = Int(buffer.loadUnaligned(fromByteOffset: start, as: UInt32.self))
            guard length >= 52, length <= buffer.count - start else { throw StorageCatalogReaderError.invalidRecord }
            let record = UnsafeRawBufferPointer(rebasing: buffer[start..<(start + length)])
            var offset = 4
            func read<T>(_ type: T.Type) throws -> T {
                guard offset + MemoryLayout<T>.size <= record.count else { throw StorageCatalogReaderError.invalidRecord }
                defer { offset += MemoryLayout<T>.size }
                return record.loadUnaligned(fromByteOffset: offset, as: type)
            }
            let referenceOffset = offset
            let reference = try read(attrreference_t.self)
            let type = try read(UInt32.self)
            let birth = try read(timespec.self)
            let flags = try read(UInt32.self)
            let inode = try read(UInt64.self)
            let parent = try read(UInt64.self)
            var links: UInt32 = 0
            var allocation: off_t = 0
            var logical: off_t = 0
            if type != UInt32(VDIR.rawValue) {
                links = try read(UInt32.self)
                allocation = try read(off_t.self)
                logical = try read(off_t.self)
            }
            let nameStart = referenceOffset + Int(reference.attr_dataoffset)
            let nameLength = Int(reference.attr_length)
            guard nameStart >= offset, nameLength > 0, nameLength <= record.count,
                  nameStart <= record.count - nameLength, record[nameStart + nameLength - 1] == 0,
                  allocation >= 0, logical >= 0, birth.tv_nsec >= 0, birth.tv_nsec < 1_000_000_000,
                  let name = String(bytes: record[nameStart..<(nameStart + nameLength - 1)], encoding: .utf8),
                  !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw StorageCatalogReaderError.invalidRecord
            }
            entries.append(StorageCatalogEntry(name: name, inode: inode, parentInode: parent, device: device,
                type: type, birthSeconds: Int64(birth.tv_sec), birthNanoseconds: Int64(birth.tv_nsec), flags: flags,
                logicalBytes: UInt64(logical), allocatedBytes: UInt64(allocation), linkCount: links))
            start += length
        }
        return entries
    }
}
