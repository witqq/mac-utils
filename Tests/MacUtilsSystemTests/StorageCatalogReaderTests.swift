import Darwin
import Foundation
@testable import MacUtilsSystem
import Testing

@Test func storageCatalogReaderAcceptsPartialResultsAndRejectsChangedCatalogs() throws {
    try StorageCatalogReader.validateResult(status: 0, error: 0)
    try StorageCatalogReader.validateResult(status: -1, error: EAGAIN)
    #expect(throws: StorageCatalogReaderError.catalogChanged) {
        try StorageCatalogReader.validateResult(status: -1, error: EBUSY)
    }
    #expect(throws: StorageCatalogReaderError.unsupported) {
        try StorageCatalogReader.validateResult(status: -1, error: ENOTSUP)
    }
    #expect(throws: StorageCatalogReaderError.failed(EACCES)) {
        try StorageCatalogReader.validateResult(status: -1, error: EACCES)
    }
}

@Test func storageCatalogReaderRejectsTruncatedAndMalformedRecords() throws {
    let buffers: [[UInt8]] = [[], [0, 0, 0], Array(repeating: 0, count: 64), [255, 255, 255, 127]]
    for buffer in buffers {
        #expect(throws: StorageCatalogReaderError.invalidRecord) {
            try buffer.withUnsafeBytes { try StorageCatalogReader.decode($0, count: 1, device: 0) }
        }
    }
}

@Test func storageCatalogReaderDecodesTypeSpecificFieldsWithoutTruncatingIdentity() throws {
    func record(type: UInt32) -> Data {
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let file = type != UInt32(VDIR.rawValue)
        let fixedLength = file ? 72 : 52
        append(UInt32(fixedLength + 5))
        append(Int32(fixedLength - 4)); append(UInt32(5))
        append(type)
        append(Int64(123)); append(Int64(987_654_321))
        append(UInt32(SF_DATALESS))
        append(UInt64(0xfedcba9876543210)); append(UInt64(0x8765432112345678))
        if file { append(UInt32(3)); append(Int64(4_096)); append(Int64(9_999)) }
        data.append(contentsOf: Array("name\0".utf8))
        return data
    }
    for type in [UInt32(VDIR.rawValue), UInt32(VREG.rawValue), UInt32(VLNK.rawValue)] {
        let entries = try record(type: type).withUnsafeBytes { try StorageCatalogReader.decode($0, count: 1, device: 7) }
        let entry = try #require(entries.first)
        #expect(entry.name == "name")
        #expect(entry.inode == 0xfedcba9876543210)
        #expect(entry.parentInode == 0x8765432112345678)
        #expect(entry.birthNanoseconds == 987_654_321)
        #expect(entry.device == 7)
        #expect(entry.flags == UInt32(SF_DATALESS))
        #expect(entry.logicalBytes == (type == UInt32(VDIR.rawValue) ? 0 : 9_999))
        #expect(entry.allocatedBytes == (type == UInt32(VDIR.rawValue) ? 0 : 4_096))
        #expect(entry.linkCount == (type == UInt32(VDIR.rawValue) ? 0 : 3))
    }
    var invalidReference = record(type: UInt32(VREG.rawValue))
    withUnsafeBytes(of: Int32(-1)) { invalidReference.replaceSubrange(4..<8, with: $0) }
    #expect(throws: StorageCatalogReaderError.invalidRecord) {
        try invalidReference.withUnsafeBytes { try StorageCatalogReader.decode($0, count: 1, device: 7) }
    }
}

@Test(arguments: ["/", "/System/Volumes/Data"])
func storageCatalogReaderNativeFirstBatchMatchesFilesystemMetadata(volumePath: String) throws {
    let root = URL(fileURLWithPath: volumePath)
    let reader: StorageCatalogReader
    do { reader = try StorageCatalogReader(volumeURL: root, maximumMatches: 128) }
    catch StorageCatalogReaderError.unsupported { return }
    let batch = try reader.nextBatch()
    #expect(!batch.entries.isEmpty)
    #expect(batch.entries.count <= 128)
    var filesystem = statfs()
    #expect(statfs(root.path, &filesystem) == 0)
    var checked = 0
    var checkedFiles = 0
    for entry in batch.entries {
        if entry.flags & UInt32(SF_FIRMLINK) != 0 { continue }
        var pathBytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = pathBytes.withUnsafeMutableBufferPointer {
            fsgetpath($0.baseAddress!, $0.count, &filesystem.f_fsid, entry.inode)
        }
        if length < 0 { continue }
        let path = String(decoding: pathBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var metadata = stat()
        if lstat(path, &metadata) != 0 || UInt64(metadata.st_ino) != entry.inode { continue }
        #expect(entry.birthSeconds == Int64(metadata.st_birthtimespec.tv_sec))
        #expect(entry.birthNanoseconds == Int64(metadata.st_birthtimespec.tv_nsec))
        #expect(entry.flags == metadata.st_flags)
        #expect(entry.device == UInt64(UInt32(bitPattern: metadata.st_dev)))
        if metadata.st_mode & S_IFMT == S_IFREG {
            #expect(entry.type == UInt32(VREG.rawValue))
            #expect(entry.logicalBytes == UInt64(metadata.st_size))
            #expect(entry.allocatedBytes == UInt64(metadata.st_blocks) * 512)
            #expect(entry.linkCount == UInt32(metadata.st_nlink))
            checkedFiles += 1
        }
        checked += 1
        if checked >= 8 && checkedFiles >= 3 { break }
    }
    #expect(checked > 0)
    #expect(checkedFiles > 0)
}
