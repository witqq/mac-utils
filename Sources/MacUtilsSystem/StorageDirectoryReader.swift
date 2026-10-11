import Darwin
import Foundation

/// Owns one opened directory. Bulk records are metadata only and never follow symbolic links.
final class StorageDirectoryReader {
    enum MetadataMode { case full, identityAndType }
    private(set) var descriptor: CInt
    private var legacy: UnsafeMutablePointer<DIR>?
    private var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    private var records: [(String, stat?)] = []
    private var index = 0
    private var hasReadBulk = false
    private var ended = false
    private let metadataMode: MetadataMode
    var isUsingBulk: Bool { legacy == nil }

    init(descriptor: CInt, bulk: Bool, metadataMode: MetadataMode = .full) throws {
        self.descriptor = descriptor
        self.metadataMode = metadataMode
        if !bulk {
            guard let directory = fdopendir(descriptor) else {
                let code = errno; close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            legacy = directory
        }
    }
    deinit { if let legacy { closedir(legacy) } else { close(descriptor) } }

    func next() throws -> (name: String, metadata: stat?)? {
        if let legacy { return try nextLegacy(legacy) }
        if index < records.count { defer { index += 1 }; return records[index] }
        guard !ended else { return nil }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID))
        attributes.commonattr |= UInt32(ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
        attributes.fileattr = metadataMode == .full
            ? UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH | ATTR_FILE_ALLOCSIZE) : UInt32(ATTR_FILE_LINKCOUNT)
        let count = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            return buffer.withUnsafeMutableBytes {
                getattrlistbulk(descriptor, &attributes, $0.baseAddress!, $0.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
            }
        }
        if count < 0 {
            let code = errno
            // Never mix successful bulk iteration and readdir offsets. An unsupported filesystem
            // starts a fresh directory description before falling back to portable enumeration.
            if !hasReadBulk && [ENOTSUP, EINVAL, ENOSYS].contains(code) {
                let replacement = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
                    guard enabled else { throw StorageDatalessPolicyError.unavailable }
                    return openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard replacement >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard let directory = fdopendir(replacement) else {
                    let failure = errno; close(replacement)
                    throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
                }
                close(descriptor); descriptor = replacement; legacy = directory
                return try nextLegacy(directory)
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        hasReadBulk = true
        if count == 0 { ended = true; return nil }
        records = try buffer.withUnsafeBytes { raw in
            var result: [(String, stat?)] = []
            var start = 0
            for _ in 0..<count {
                guard start + 4 <= raw.count else { throw POSIXError(.EIO) }
                let length = Int(raw.loadUnaligned(fromByteOffset: start, as: UInt32.self))
                guard length >= 32, length <= raw.count - start else { throw POSIXError(.EIO) }
                let record = UnsafeRawBufferPointer(rebasing: raw[start..<(start + length)])
                result.append(try Self.decode(record, mode: metadataMode))
                start += length
            }
            return result
        }
        index = 0
        return try next()
    }

    private func nextLegacy(_ directory: UnsafeMutablePointer<DIR>) throws -> (String, stat?)? {
        errno = 0
        let entry = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            return readdir(directory)
        }
        guard let entry else {
            if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return nil
        }
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        return (name, nil)
    }

    private static func decode(_ bytes: UnsafeRawBufferPointer, mode: MetadataMode) throws -> (String, stat?) {
        var offset = 4
        func read<T>(_ type: T.Type) throws -> T {
            guard offset + MemoryLayout<T>.size <= bytes.count else { throw POSIXError(.EIO) }
            defer { offset += MemoryLayout<T>.size }
            return bytes.loadUnaligned(fromByteOffset: offset, as: type)
        }
        let returned = try read(attribute_set_t.self)
        let error = try read(UInt32.self)
        let nameOffset = offset
        let nameReference = try read(attrreference_t.self)
        let start = nameOffset + Int(nameReference.attr_dataoffset)
        let length = Int(nameReference.attr_length)
        guard start >= 0, length > 0, start <= bytes.count - length, bytes[start + length - 1] == 0 else { throw POSIXError(.EIO) }
        let nameBytes = bytes[start..<(start + length - 1)]
        guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            throw POSIXError(.EILSEQ)
        }
        let device = try read(dev_t.self)
        let type = try read(UInt32.self)
        let birth = try read(timespec.self)
        let flags = try read(UInt32.self)
        let inode = try read(UInt64.self)
        let required = UInt32(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
        let files = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH | ATTR_FILE_ALLOCSIZE)
        guard error == 0, returned.commonattr & required == required, flags & UInt32(SF_FIRMLINK) == 0 else { return (name, nil) }
        if mode == .identityAndType {
            var metadata = stat()
            switch type {
            case UInt32(VDIR.rawValue): metadata.st_mode = mode_t(S_IFDIR)
            case UInt32(VREG.rawValue): metadata.st_mode = mode_t(S_IFREG)
            case UInt32(VLNK.rawValue): metadata.st_mode = mode_t(S_IFLNK)
            case UInt32(VFIFO.rawValue): metadata.st_mode = mode_t(S_IFIFO)
            case UInt32(VSOCK.rawValue): metadata.st_mode = mode_t(S_IFSOCK)
            case UInt32(VCHR.rawValue): metadata.st_mode = mode_t(S_IFCHR)
            case UInt32(VBLK.rawValue): metadata.st_mode = mode_t(S_IFBLK)
            default: return (name, nil)
            }
            if type != UInt32(VDIR.rawValue) {
                guard returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT) != 0 else { return (name, nil) }
                let links = try read(UInt32.self)
                guard links <= UInt32(UInt16.max) else { return (name, nil) }
                metadata.st_nlink = UInt16(links)
            }
            metadata.st_dev = device; metadata.st_ino = inode; metadata.st_birthtimespec = birth; metadata.st_flags = flags
            return (name, metadata)
        }
        // Firmlink attributes describe the link, not its target; fstatat restores the same
        // identity used by the subsequent no-follow directory open. Directory mount roots
        // also return attributes of the underlying mountpoint, so use fstatat for all dirs.
        guard type != UInt32(VDIR.rawValue),
              returned.fileattr & files == files else { return (name, nil) }
        let links = try read(UInt32.self)
        let allocation = try read(off_t.self)
        let size = try read(off_t.self)
        guard size >= 0, allocation >= 0, allocation % 512 == 0,
              links <= UInt32(UInt16.max) else { return (name, nil) }
        var metadata = stat()
        switch type {
        case UInt32(VREG.rawValue): metadata.st_mode = mode_t(S_IFREG)
        case UInt32(VLNK.rawValue): metadata.st_mode = mode_t(S_IFLNK)
        default: return (name, nil)
        }
        metadata.st_dev = device; metadata.st_ino = inode; metadata.st_birthtimespec = birth
        metadata.st_flags = flags; metadata.st_nlink = UInt16(links)
        metadata.st_size = size; metadata.st_blocks = allocation / 512
        return (name, metadata)
    }
}
