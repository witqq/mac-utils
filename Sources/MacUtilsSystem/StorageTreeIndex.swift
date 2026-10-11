import Darwin
import Foundation
import MacUtilsCore
import SQLite3

public enum StorageTreeIndexError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    case io(String)
    case collision(path: String, existing: String, incoming: String)
    public var description: String {
        switch self {
        case let .invalid(message): "Invalid storage tree: \(message)"
        case let .io(message): "Storage tree cache: \(message)"
        case let .collision(path, existing, incoming): "Storage tree name collision at \(path); existing={\(existing)}; incoming={\(incoming)}"
        }
    }
}

private enum TreeValue {
    case integer(Int64), text(String), bytes(Data), null
}
private let treeTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private struct TreeUniqueConstraint: Error {
    let message: String
}

/// A scanner-only historical name conflict, distinct from SQL failures and
/// contradictory metadata for the same object. The first accepted row is retained.
struct StorageTreeCatalogLeafReplacement: Error, CustomStringConvertible {
    let id: Int
    let path: String
    let existingIdentity: StorageFileIdentity
    let incomingIdentity: StorageFileIdentity
    var description: String { "Catalog leaf was replaced at \(path): \(existingIdentity) → \(incomingIdentity)" }
}

private struct TreeCatalogRecordProof {
    let identity: StorageFileIdentity
    let parentInode: UInt64
    init?(_ data: Data) {
        guard data.count == 80 else { return nil }
        let values = data.withUnsafeBytes { bytes in
            (0..<10).map { UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self)) }
        }
        let nanoseconds = Int64(bitPattern: values[5])
        guard values[3] > 0, values[3] <= UInt64(UInt32.max), values[3] != UInt64(VDIR.rawValue),
              nanoseconds >= 0, nanoseconds < 1_000_000_000, values[6] <= UInt64(UInt32.max),
              values[7] <= UInt64(Int64.max), values[8] <= UInt64(Int64.max), values[9] <= UInt64(UInt32.max) else { return nil }
        identity = StorageFileIdentity(device: values[2], inode: values[0], birthSeconds: Int64(bitPattern: values[4]), birthNanoseconds: nanoseconds)
        parentInode = values[1]
    }
}

/// Overlapping Service/writer leases protect the close-before-publish handoff from
/// orphan cleanup in another process. This never locks the scanned source volume.
public final class StorageTreeScanLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: CInt
    public init(directoryURL: URL) throws {
        descriptor = try StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            let parent = try treeDirectoryFD(directoryURL, create: true)
            defer { Darwin.close(parent) }
            return openat(parent, ".scans.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        }
        guard descriptor >= 0 else { throw StorageTreeIndexError.io("Cannot open analysis-generation lock") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw StorageTreeIndexError.invalid("Analysis-generation lock is not privately owned")
        }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw StorageTreeIndexError.io("Analysis cache cleanup is currently active")
        }
    }
    public func close() { lock.withLock { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } } }
    deinit { close() }
}

private final class TreeDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private(set) var lockFD: CInt = -1
    private var leaseFD: CInt = -1
    private var progressCalls = 0
    private var reserveViolated = false
    private var checksReserve = false
    var hasTombstones = false
    var visiblePredicate: String { hasTombstones ? "NOT EXISTS(SELECT 1 FROM tombstones WHERE tombstones.id=nodes.id)" : "1" }
    init(url: URL, writable: Bool) throws {
        lockFD = open(url.path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard lockFD >= 0 else { throw StorageTreeIndexError.io(String(cString: strerror(errno))) }
        var initial = stat()
        guard fstat(lockFD, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_uid == geteuid(), initial.st_mode & 0o077 == 0 else {
            Darwin.close(lockFD); lockFD = -1; throw StorageTreeIndexError.invalid("Index file is not private, regular and owned")
        }
        let suffix = url.lastPathComponent.hasSuffix(".building.sqlite") ? ".building.sqlite" : ".sqlite"
        let identifier = String(url.lastPathComponent.dropLast(suffix.count))
        guard let uuid = UUID(uuidString: identifier), uuid.uuidString == identifier else {
            close(); throw StorageTreeIndexError.invalid("Noncanonical index filename")
        }
        let lease = url.deletingLastPathComponent().appending(path: identifier + ".lease")
        leaseFD = open(lease.path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        var leaseMetadata = stat()
        guard leaseFD >= 0, fstat(leaseFD, &leaseMetadata) == 0, leaseMetadata.st_mode & S_IFMT == S_IFREG,
              leaseMetadata.st_uid == geteuid(), leaseMetadata.st_mode & 0o077 == 0 else {
            close(); throw StorageTreeIndexError.invalid("Missing private index lease")
        }
        guard flock(leaseFD, (writable ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(); throw StorageTreeIndexError.io("The index is in use.")
        }
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open SQLite index."
            close(); throw StorageTreeIndexError.io(message)
        }
        var actual = stat(), named = stat()
        guard fstat(lockFD, &actual) == 0, lstat(url.path, &named) == 0,
              actual.st_mode & S_IFMT == S_IFREG, actual.st_dev == named.st_dev, actual.st_ino == named.st_ino else {
            close(); throw StorageTreeIndexError.invalid("Index path changed while opening.")
        }
        checksReserve = writable
        sqlite3_progress_handler(handle, 10_000, { context in
            guard let context else { return 1 }
            return Unmanaged<TreeDatabase>.fromOpaque(context).takeUnretainedValue().progress()
        }, Unmanaged.passUnretained(self).toOpaque())
        try execute("PRAGMA cache_size=-8192")
        if writable {
            try execute("PRAGMA temp_store=FILE")
            try execute("PRAGMA journal_mode=MEMORY")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
        }
        hasTombstones = try integer("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='tombstones'") == 1
    }
    deinit { close() }
    func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let handle { sqlite3_close(handle) }; handle = nil
        if leaseFD >= 0 { Darwin.close(leaseFD); leaseFD = -1 }
        if lockFD >= 0 { closeDescriptor(lockFD); lockFD = -1 }
    }
    private func closeDescriptor(_ descriptor: CInt) { Darwin.close(descriptor) }
    private func progress() -> Int32 {
        if withUnsafeCurrentTask(body: { $0?.isCancelled == true }) { return 1 }
        progressCalls += 1
        if checksReserve && progressCalls % 64 == 0 {
            do { try checkSpace() }
            catch { reserveViolated = true; return 1 }
        }
        return 0
    }
    func statement(_ sql: String, _ bindings: [TreeValue] = []) throws -> OpaquePointer {
        guard let handle else { throw StorageTreeIndexError.io("Index is closed.") }
        let statement: OpaquePointer
        if let existing = statements[sql] { statement = existing }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                throw StorageTreeIndexError.io(String(cString: sqlite3_errmsg(handle)))
            }
            statement = prepared; statements[sql] = prepared
        }
        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .integer(value): result = sqlite3_bind_int64(statement, index, value)
            case let .text(value): result = sqlite3_bind_text(statement, index, value, -1, treeTransient)
            case let .bytes(value): result = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), treeTransient) }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw StorageTreeIndexError.io(String(cString: sqlite3_errmsg(handle))) }
        }
        return statement
    }
    func step(_ statement: OpaquePointer, recoverUnique: Bool = false) throws -> Bool {
        let code = sqlite3_step(statement)
        let extendedCode = code == SQLITE_ROW || code == SQLITE_DONE ? code
            : handle.map { sqlite3_extended_errcode($0) } ?? code
        if code == SQLITE_ROW { return true }
        if code == SQLITE_INTERRUPT {
            try Task.checkCancellation()
            if reserveViolated { throw StorageTreeIndexError.io("The 512 MiB free-space reserve could not be maintained") }
        }
        guard code == SQLITE_DONE else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Closed index"
            // Only INSERT's UNIQUE failure is recoverable. Trigger, disk, locking,
            // cancellation and other failures must not turn into successful deduplication.
            if recoverUnique && extendedCode == 2_067 { throw TreeUniqueConstraint(message: message) }
            throw StorageTreeIndexError.io(message)
        }
        return false
    }
    func execute(_ sql: String, _ bindings: [TreeValue] = [], recoverUnique: Bool = false) throws {
        let statement = try statement(sql, bindings)
        while try step(statement, recoverUnique: recoverUnique) {}
    }
    func integer(_ sql: String, _ bindings: [TreeValue] = []) throws -> Int {
        let statement = try statement(sql, bindings)
        defer { sqlite3_reset(statement) }
        guard try step(statement) else { throw StorageTreeIndexError.invalid("Missing scalar value") }
        return Int(try treeInteger(statement, 0))
    }
    var lastID: Int { Int(sqlite3_last_insert_rowid(handle)) }
    func resetStatements() { for statement in statements.values { sqlite3_reset(statement) } }
    func checkSpace() throws {
        var filesystem = statfs()
        guard fstatfs(lockFD, &filesystem) == 0 else { throw StorageTreeIndexError.io("Cannot check free cache space.") }
        let available = UInt64(filesystem.f_bavail).multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
        guard !available.overflow, available.partialValue >= 512 * 1_024 * 1_024 else {
            throw StorageTreeIndexError.io("Less than 512 MiB remains available; the new analysis was stopped.")
        }
    }
}

private func treeBytes(_ value: UInt64) -> Data {
    var encoded = value.bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}
private func treeUnsigned(_ statement: OpaquePointer, _ column: Int32) throws -> UInt64 {
    guard sqlite3_column_type(statement, column) == SQLITE_BLOB, sqlite3_column_bytes(statement, column) == 8,
          let bytes = sqlite3_column_blob(statement, column) else {
        throw StorageTreeIndexError.invalid("Invalid unsigned value")
    }
    return UInt64(bigEndian: bytes.loadUnaligned(as: UInt64.self))
}
private func treeText(_ statement: OpaquePointer, _ column: Int32) throws -> String {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let text = sqlite3_column_text(statement, column) else {
        throw StorageTreeIndexError.invalid("Missing text")
    }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count <= 1_048_576, let value = String(bytes: UnsafeBufferPointer(start: text, count: count), encoding: .utf8), !value.contains("\0") else {
        throw StorageTreeIndexError.invalid("Malformed UTF-8 text")
    }
    return value
}
private func treeInteger(_ statement: OpaquePointer, _ column: Int32) throws -> Int64 {
    guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { throw StorageTreeIndexError.invalid("Malformed integer") }
    return sqlite3_column_int64(statement, column)
}
private func treeFlag(_ statement: OpaquePointer, _ column: Int32) throws -> Bool {
    let value = try treeInteger(statement, column)
    guard value == 0 || value == 1 else {
        throw StorageTreeIndexError.invalid("Malformed flag")
    }
    return value == 1
}
private func treeDirectoryFD(_ url: URL, create: Bool, allowMissing: Bool = false) throws -> CInt {
    try StorageDatalessPolicy.withMaterializationDisabled { enabled in
        guard enabled else { throw StorageDatalessPolicyError.unavailable }
        guard url.isFileURL, url.path == url.standardizedFileURL.path, !url.path.contains("\0") else {
            throw StorageTreeIndexError.invalid("Noncanonical cache directory")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageTreeIndexError.io("Cannot open cache root") }
        do {
            for component in url.pathComponents.dropFirst() {
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && allowMissing {
                    Darwin.close(descriptor)
                    return -1
                }
                if next < 0 && errno == ENOENT && create {
                    var parent = stat()
                    guard fstat(descriptor, &parent) == 0, parent.st_uid == geteuid() else {
                        throw StorageTreeIndexError.invalid("Cannot create a cache below an unowned directory")
                    }
                    let created = mkdirat(descriptor, component, 0o700) == 0
                    guard created || errno == EEXIST else {
                        throw StorageTreeIndexError.io("Cannot create private cache directory")
                    }
                    if created && fsync(descriptor) != 0 {
                        throw StorageTreeIndexError.io("Cannot persist private cache directory creation")
                    }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw StorageTreeIndexError.invalid("Cache parent is missing, inaccessible or a symbolic link") }
                Darwin.close(descriptor); descriptor = next
            }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid() else {
                throw StorageTreeIndexError.invalid("Cache directory is not owned by this account")
            }
            if create && metadata.st_mode & 0o077 != 0 {
                guard fchmod(descriptor, 0o700) == 0 else { throw StorageTreeIndexError.io("Cannot make owned cache directory private") }
            } else if metadata.st_mode & 0o077 != 0 {
                throw StorageTreeIndexError.invalid("Cache directory is not private")
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
}
private func treePrivateDirectory(_ url: URL) throws {
    let descriptor = try treeDirectoryFD(url, create: false)
    Darwin.close(descriptor)
}

private func treeValidateSupersededMarker(_ descriptor: CInt) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600,
          metadata.st_size == 0, metadata.st_nlink == 1 else {
        throw StorageTreeIndexError.invalid("Generation invalidation marker is not a private owned empty file")
    }
    return metadata
}
private struct TreeRecord {
    let row: StorageTreeRow
    let identity: StorageFileIdentity
    let depth: Int
}
private let treeColumns = "id,parent,name,kind,device,inode,birth,birthns,logical,allocated,apparent,files,children,cloud,duplicate,incomplete,inside,depth"
private func treeRecord(_ statement: OpaquePointer) throws -> TreeRecord {
    guard let kind = StorageNodeKind(rawValue: try treeText(statement, 3)) else { throw StorageTreeIndexError.invalid("Unknown node type") }
    let identity = StorageFileIdentity(device: try treeUnsigned(statement, 4), inode: try treeUnsigned(statement, 5),
        birthSeconds: try treeInteger(statement, 6), birthNanoseconds: try treeInteger(statement, 7))
    let record = TreeRecord(row: StorageTreeRow(id: Int(try treeInteger(statement, 0)),
        parentID: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : Int(try treeInteger(statement, 1)),
        name: try treeText(statement, 2), kind: kind,
        totals: StorageTotals(logicalBytes: try treeUnsigned(statement, 8), allocatedBytes: try treeUnsigned(statement, 9),
            apparentBytes: try treeUnsigned(statement, 10), fileCount: Int(try treeInteger(statement, 11))),
        childCount: Int(try treeInteger(statement, 12)), isCloudPlaceholder: try treeFlag(statement, 13),
        isHardLinkDuplicate: try treeFlag(statement, 14), isIncomplete: try treeFlag(statement, 15),
        isInsidePackage: try treeFlag(statement, 16)), identity: identity, depth: Int(try treeInteger(statement, 17)))
    let row = record.row
    guard row.id >= 0, row.childCount >= 0, row.totals.fileCount >= 0, record.depth >= 0,
          identity.birthNanoseconds >= 0, identity.birthNanoseconds < 1_000_000_000,
          !row.name.isEmpty, !row.name.contains("\0"),
          row.name.utf8.count <= 4_096,
          (row.id == 0 ? row.parentID == nil && !row.isInsidePackage && record.depth == 0
            && (row.kind == .directory || row.kind == .package)
            : (row.parentID.map { $0 >= 0 && $0 < row.id } == true
            && !row.name.contains("/") && row.name != "." && row.name != "..")) else {
        throw StorageTreeIndexError.invalid("Malformed node")
    }
    return record
}
private func treeLookup(_ database: TreeDatabase, _ id: Int, includeHidden: Bool = false) throws -> TreeRecord? {
    let statement = try database.statement("SELECT \(treeColumns) FROM nodes WHERE id=? AND \(includeHidden ? "1" : database.visiblePredicate)", [.integer(Int64(id))])
    defer { sqlite3_reset(statement) }
    return try database.step(statement) ? treeRecord(statement) : nil
}
private func treeReference(_ database: TreeDatabase, _ id: Int) throws -> StorageItemReference? {
    guard let item = try treeLookup(database, id) else { return nil }
    var chain: [TreeRecord] = [], current = item
    while let parent = current.row.parentID {
        guard parent < current.row.id, let value = try treeLookup(database, parent),
              value.row.kind == .directory || value.row.kind == .package else { throw StorageTreeIndexError.invalid("Broken parent chain") }
        chain.append(value); current = value
    }
    guard current.row.id == 0 else { throw StorageTreeIndexError.invalid("Disconnected node") }
    var path = "", ancestors: [StoragePathIdentity] = [], inside = false
    for value in chain.reversed() {
        guard value.row.isInsidePackage == inside else { throw StorageTreeIndexError.invalid("Package ancestry flag differs") }
        if value.row.id != 0 { path = path.isEmpty ? value.row.name : path + "/" + value.row.name }
        ancestors.append(StoragePathIdentity(relativePath: path, identity: value.identity))
        inside = inside || value.row.kind == .package
    }
    guard item.row.isInsidePackage == inside else { throw StorageTreeIndexError.invalid("Item package ancestry flag differs") }
    let relative = id == 0 ? "" : path.isEmpty ? item.row.name : path + "/" + item.row.name
    return StorageItemReference(id: id, name: item.row.name, relativePath: relative, kind: item.row.kind,
        identity: item.identity, totals: item.row.totals, ancestors: ancestors,
        isCloudPlaceholder: item.row.isCloudPlaceholder, isHardLinkDuplicate: item.row.isHardLinkDuplicate,
        isIncomplete: item.row.isIncomplete, unlistedChildCount: item.row.kind == .directory ? item.row.childCount : 0,
        isInsidePackage: item.row.isInsidePackage)
}

struct StorageTreeSummary {
    let descriptor: StorageTreeDescriptor
    let root: StorageItemReference
    let overview: [StorageItemReference]
    let largest: [StorageItemReference]
}

final class StorageTreeWriter {
    let id: UUID
    let directoryURL: URL
    let directoryIdentity: StorageFileIdentity
    private let temporaryURL: URL
    private var database: TreeDatabase?
    private var scanLease: StorageTreeScanLease?
    private var directoryFD: CInt = -1
    private var createdTemporary = false
    private var createdLease = false
    private let grantID: UUID
    private let rootPath: String
    private let rootIdentity: StorageFileIdentity
    private var published = false
    private var handedOff = false
    private var writes = 0
    private var hasKnownLeafReplacements = false
    init(directoryURL: URL, snapshotID: UUID, grantID: UUID, rootURL: URL,
         rootIdentity: StorageFileIdentity, rootKind: StorageNodeKind = .directory, rootCloud: Bool = false) throws {
        self.id = snapshotID; self.grantID = grantID; rootPath = rootURL.path; self.rootIdentity = rootIdentity
        self.directoryURL = directoryURL.standardizedFileURL
        let prepared = try treeDirectoryFD(directoryURL, create: true)
        var metadata = stat()
        guard fstat(prepared, &metadata) == 0 else { Darwin.close(prepared); throw StorageTreeIndexError.io("Cannot identify cache directory") }
        directoryIdentity = StorageFileMetadata.identity(metadata)
        temporaryURL = directoryURL.appending(path: snapshotID.uuidString + ".building.sqlite")
        directoryFD = prepared
        do {
            scanLease = try StorageTreeScanLease(directoryURL: directoryURL)
            let descriptor = openat(directoryFD, temporaryURL.lastPathComponent, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw StorageTreeIndexError.io(String(cString: strerror(errno))) }
            createdTemporary = true
            Darwin.close(descriptor)
            let lease = openat(directoryFD, id.uuidString + ".lease", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lease >= 0 else { throw StorageTreeIndexError.io("Cannot create private index lease") }
            createdLease = true; Darwin.close(lease)
            let database = try TreeDatabase(url: temporaryURL, writable: true); self.database = database
            try database.checkSpace()
            try database.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY,value BLOB NOT NULL)")
            try database.execute("INSERT INTO metadata VALUES('owner',?)", [.text("com.witqq.mac-utils.storage-tree")])
            try database.execute("INSERT INTO metadata VALUES('id',?)", [.text(id.uuidString)])
            try database.execute("CREATE TABLE nodes(id INTEGER PRIMARY KEY,parent INTEGER REFERENCES nodes(id),name TEXT NOT NULL,kind TEXT NOT NULL,device BLOB NOT NULL,inode BLOB NOT NULL,birth INTEGER NOT NULL,birthns INTEGER NOT NULL,logical BLOB NOT NULL,allocated BLOB NOT NULL,apparent BLOB NOT NULL,files INTEGER NOT NULL,children INTEGER NOT NULL DEFAULT 0,cloud INTEGER NOT NULL,duplicate INTEGER NOT NULL,incomplete INTEGER NOT NULL,inside INTEGER NOT NULL,depth INTEGER NOT NULL,path TEXT UNIQUE,catalog BLOB,UNIQUE(parent,name))")
            try database.execute("CREATE INDEX build_parent ON nodes(parent)")
            try database.execute("CREATE TABLE tombstones(id INTEGER PRIMARY KEY REFERENCES nodes(id))")
            database.hasTombstones = true
            try database.execute("CREATE TRIGGER validate_parent BEFORE INSERT ON nodes WHEN NEW.parent IS NOT NULL AND (NOT EXISTS(SELECT 1 FROM nodes WHERE id=NEW.parent AND kind IN ('directory','package')) OR NEW.inside<>(SELECT CASE WHEN inside=1 OR kind='package' THEN 1 ELSE 0 END FROM nodes WHERE id=NEW.parent)) BEGIN SELECT RAISE(ABORT,'invalid parent/package ancestry'); END")
            try database.execute("BEGIN")
            _ = try insert(id: 0, name: rootURL.lastPathComponent.isEmpty ? "/" : rootURL.lastPathComponent,
                parentID: nil, identity: rootIdentity, kind: rootKind, totals: .zero, cloud: rootCloud,
                duplicate: false, incomplete: false, inside: false, depth: 0, path: "")
        } catch { abort(); throw error }
    }
    deinit { if !handedOff { abort() } }
    private func db() throws -> TreeDatabase {
        guard let database else { throw StorageTreeIndexError.io("Writer is closed") }; return database
    }
    private func insert(id: Int? = nil, name: String, parentID: Int?, identity: StorageFileIdentity,
                        kind: StorageNodeKind, totals: StorageTotals, cloud: Bool, duplicate: Bool,
                        incomplete: Bool, inside: Bool, depth: Int, path: String?, catalogRecord: Data? = nil) throws -> Bool {
        guard !name.isEmpty, (parentID == nil || (!name.contains("/") && name != "." && name != "..")),
              !name.contains("\0"), totals.fileCount >= 0, identity.birthNanoseconds >= 0,
              identity.birthNanoseconds < 1_000_000_000 else { throw StorageTreeIndexError.invalid("Invalid entry") }
        let database = try db()
        do { try database.execute("INSERT INTO nodes(id,parent,name,kind,device,inode,birth,birthns,logical,allocated,apparent,files,cloud,duplicate,incomplete,inside,depth,path,catalog) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            id.map { .integer(Int64($0)) } ?? .null, parentID.map { .integer(Int64($0)) } ?? .null,
            .text(name), .text(kind.rawValue), .bytes(treeBytes(identity.device)), .bytes(treeBytes(identity.inode)),
            .integer(identity.birthSeconds), .integer(identity.birthNanoseconds), .bytes(treeBytes(totals.logicalBytes)),
            .bytes(treeBytes(totals.allocatedBytes)), .bytes(treeBytes(totals.apparentBytes)), .integer(Int64(totals.fileCount)),
            .integer(cloud ? 1 : 0), .integer(duplicate ? 1 : 0), .integer(incomplete ? 1 : 0), .integer(inside ? 1 : 0),
            .integer(Int64(depth)), path.map(TreeValue.text) ?? .null, catalogRecord.map(TreeValue.bytes) ?? .null], recoverUnique: true) }
        catch {
            guard let failure = error as? TreeUniqueConstraint else { throw error }
            let original = StorageTreeIndexError.io(failure.message)
            if let parentID {
                let statement = try database.statement("SELECT \(treeColumns) FROM nodes WHERE parent=? AND name=?", [.integer(Int64(parentID)), .text(name)])
                defer { sqlite3_reset(statement) }
                if try database.step(statement) {
                    let existing = try treeRecord(statement)
                    var sameIncomplete = existing.row.isIncomplete == incomplete
                    if !sameIncomplete && existing.row.isIncomplete {
                        sameIncomplete = try isKnownLeafReplacement(id: existing.row.id)
                    }
                    if let catalogRecord, existing.identity == identity, existing.row.kind == kind,
                       existing.row.isCloudPlaceholder == cloud, existing.row.isInsidePackage == inside,
                       sameIncomplete {
                        let saved = try database.statement("SELECT catalog FROM nodes WHERE id=?", [.integer(Int64(existing.row.id))])
                        defer { sqlite3_reset(saved) }
                        if try database.step(saved), sqlite3_column_type(saved, 0) == SQLITE_BLOB,
                           let bytes = sqlite3_column_blob(saved, 0),
                           Data(bytes: bytes, count: Int(sqlite3_column_bytes(saved, 0))) == catalogRecord {
                            // searchfs can repeat a hard-link catalog record. Only its exact
                            // historical record may be reused; never adopt a replacement.
                            return false
                        }
                    }
                    let parent = try database.statement("SELECT path FROM nodes WHERE id=?", [.integer(Int64(parentID))])
                    defer { sqlite3_reset(parent) }
                    let parentPath = try database.step(parent) ? treeText(parent, 0) : "<parent \(parentID)>"
                    let relativePath = parentPath.isEmpty ? name : parentPath + "/" + name
                    if let catalogRecord, let incoming = TreeCatalogRecordProof(catalogRecord),
                       incoming.identity == identity, existing.identity != identity,
                       existing.row.kind != .directory, existing.row.kind != .package,
                       kind != .directory, kind != .package,
                       let parentRow = try treeLookup(database, parentID) {
                        let saved = try database.statement("SELECT catalog FROM nodes WHERE id=?", [.integer(Int64(existing.row.id))])
                        defer { sqlite3_reset(saved) }
                        if try database.step(saved), sqlite3_column_type(saved, 0) == SQLITE_BLOB,
                           let bytes = sqlite3_column_blob(saved, 0),
                           let previous = TreeCatalogRecordProof(Data(bytes: bytes, count: Int(sqlite3_column_bytes(saved, 0)))),
                           previous.identity == existing.identity,
                           previous.parentInode == incoming.parentInode,
                           previous.identity.device == incoming.identity.device,
                           parentRow.identity.device == incoming.identity.device,
                           parentRow.identity.inode == incoming.parentInode || (parentID == 0 && incoming.parentInode == 2) {
                            throw StorageTreeCatalogLeafReplacement(id: existing.row.id, path: relativePath,
                                existingIdentity: existing.identity, incomingIdentity: identity)
                        }
                    }
                    func diagnostic(_ kind: StorageNodeKind, _ identity: StorageFileIdentity, _ totals: StorageTotals,
                                    _ cloud: Bool, _ duplicate: Bool, _ inside: Bool) -> String {
                        "kind=\(kind.rawValue),device=\(identity.device),inode=\(identity.inode),birth=\(identity.birthSeconds).\(identity.birthNanoseconds),logical=\(totals.logicalBytes),allocated=\(totals.allocatedBytes),apparent=\(totals.apparentBytes),files=\(totals.fileCount),cloud=\(cloud),duplicate=\(duplicate),inside=\(inside)"
                    }
                    throw StorageTreeIndexError.collision(path: relativePath,
                        existing: diagnostic(existing.row.kind, existing.identity, existing.row.totals,
                            existing.row.isCloudPlaceholder, existing.row.isHardLinkDuplicate, existing.row.isInsidePackage),
                        incoming: diagnostic(kind, identity, totals, cloud, duplicate, inside))
                }
            }
            throw original
        }
        writes += 1
        if writes % 4_096 == 0 {
            try Task.checkCancellation(); try database.execute("COMMIT"); try database.checkSpace(); try database.execute("BEGIN")
        }
        return true
    }
    func directoryID(relativePath: String) throws -> Int? {
        let database = try db(), statement = try database.statement("SELECT id FROM nodes WHERE path=?", [.text(relativePath)])
        defer { sqlite3_reset(statement) }
        return try database.step(statement) ? Int(sqlite3_column_int64(statement, 0)) : nil
    }
    func ensureDirectory(name: String, relativePath: String, parentID: Int, identity: StorageFileIdentity,
                         kind: StorageNodeKind, isCloudPlaceholder: Bool, isIncomplete: Bool) throws -> Int {
        let database = try db()
        guard kind == .directory || kind == .package, let parent = try treeLookup(database, parentID),
              parent.row.kind == .directory || parent.row.kind == .package else { throw StorageTreeIndexError.invalid("Invalid directory parent") }
        let pathStatement = try database.statement("SELECT path FROM nodes WHERE id=?", [.integer(Int64(parentID))])
        guard try database.step(pathStatement) else { throw StorageTreeIndexError.invalid("Missing directory path") }
        let parentPath = try treeText(pathStatement, 0)
        sqlite3_reset(pathStatement)
        guard relativePath == (parentPath.isEmpty ? name : parentPath + "/" + name) else { throw StorageTreeIndexError.invalid("Directory path differs from parent") }
        if let existing = try directoryID(relativePath: relativePath) {
            guard let row = try treeLookup(database, existing), row.identity == identity, row.row.parentID == parentID,
                  row.row.name == name, row.row.kind == kind else { throw StorageTreeIndexError.invalid("Directory identity conflict") }
            if isIncomplete { try markIncomplete(directoryID: existing) }; return existing
        }
        _ = try insert(name: name, parentID: parentID, identity: identity, kind: kind, totals: .zero,
            cloud: isCloudPlaceholder, duplicate: false, incomplete: isIncomplete,
            inside: parent.row.isInsidePackage || parent.row.kind == .package, depth: parent.depth + 1, path: relativePath)
        return database.lastID
    }
    func appendLeaf(name: String, parentID: Int, kind: StorageNodeKind, identity: StorageFileIdentity,
                    totals: StorageTotals, isCloudPlaceholder: Bool, isHardLinkDuplicate: Bool,
                    isIncomplete: Bool, isInsidePackage: Bool, catalogRecord: Data? = nil) throws -> Bool {
        guard kind != .directory && kind != .package else { throw StorageTreeIndexError.invalid("Leaf is a directory") }
        return try insert(name: name, parentID: parentID, identity: identity, kind: kind, totals: totals,
            cloud: isCloudPlaceholder, duplicate: isHardLinkDuplicate, incomplete: isIncomplete,
            inside: isInsidePackage, depth: 0, path: nil, catalogRecord: catalogRecord)
    }
    func markIncomplete(directoryID: Int) throws { try db().execute("UPDATE nodes SET incomplete=1 WHERE id=?", [.integer(Int64(directoryID))]) }
    func markKnownLeafReplacement(_ replacement: StorageTreeCatalogLeafReplacement) throws {
        let database = try db()
        guard let row = try treeLookup(database, replacement.id), row.identity == replacement.existingIdentity,
              row.row.kind != .directory, row.row.kind != .package else { throw StorageTreeIndexError.invalid("Known leaf replacement differs from its historical row") }
        if !hasKnownLeafReplacements {
            try database.execute("CREATE TEMP TABLE known_leaf_replacements(id INTEGER PRIMARY KEY)")
            hasKnownLeafReplacements = true
        }
        try database.execute("INSERT INTO known_leaf_replacements VALUES(?) ON CONFLICT(id) DO NOTHING", [.integer(Int64(replacement.id))])
        try database.execute("UPDATE nodes SET incomplete=1 WHERE id=?", [.integer(Int64(replacement.id))])
    }
    func isKnownLeafReplacement(id: Int) throws -> Bool {
        guard hasKnownLeafReplacements else { return false }
        return try db().integer("SELECT COUNT(*) FROM known_leaf_replacements WHERE id=?", [.integer(Int64(id))]) == 1
    }
    func excludes(url: URL, identity: StorageFileIdentity? = nil) -> Bool {
        let path = url.standardizedFileURL.path, cache = directoryURL.path
        return path == cache || path.hasPrefix(cache + "/") || identity == directoryIdentity
    }
    func finish(expectedRootTotals: StorageTotals, maximumNodes: Int, largestLimit: Int) throws -> StorageTreeSummary {
        let database = try db()
        database.resetStatements()
        try Task.checkCancellation(); try database.execute("COMMIT")
        try database.execute("PRAGMA temp_store=FILE")
        try database.checkSpace()
        try database.execute("CREATE TABLE rollup AS SELECT id,depth FROM nodes WHERE kind IN ('directory','package')")
        try database.execute("CREATE INDEX rollup_depth ON rollup(depth DESC,id DESC)")
        try database.execute("UPDATE nodes SET children=(SELECT COUNT(*) FROM nodes child WHERE child.parent=nodes.id) WHERE kind IN ('directory','package')")
        try database.execute("BEGIN")
        let cursor = try database.statement("SELECT id FROM rollup ORDER BY depth DESC,id DESC")
        var processed = 0
        while try database.step(cursor) {
            try Task.checkCancellation()
            let id = Int(sqlite3_column_int64(cursor, 0))
            guard let item = try treeLookup(database, id) else { throw StorageTreeIndexError.invalid("Missing directory") }
            // Child directories are already finalized; files retain their original contributions.
            let children = try database.statement("SELECT logical,allocated,apparent,files,incomplete FROM nodes WHERE parent=?", [.integer(Int64(id))])
            var totals = StorageTotals.zero, incomplete = item.row.isIncomplete
            while try database.step(children) {
                totals = try StorageScanner.sum(totals, StorageTotals(logicalBytes: treeUnsigned(children, 0),
                    allocatedBytes: treeUnsigned(children, 1), apparentBytes: treeUnsigned(children, 2),
                    fileCount: Int(sqlite3_column_int64(children, 3))), path: "index node \(id)")
                incomplete = incomplete || sqlite3_column_int(children, 4) != 0
            }
            try database.execute("UPDATE nodes SET logical=?,allocated=?,apparent=?,files=?,incomplete=? WHERE id=?", [
                .bytes(treeBytes(totals.logicalBytes)), .bytes(treeBytes(totals.allocatedBytes)), .bytes(treeBytes(totals.apparentBytes)),
                .integer(Int64(totals.fileCount)), .integer(incomplete ? 1 : 0), .integer(Int64(id))])
            processed += 1
            if processed % 4_096 == 0 { try database.execute("COMMIT"); try database.checkSpace(); try database.execute("BEGIN") }
        }
        database.resetStatements()
        try database.execute("COMMIT")
        guard let root = try treeReference(database, 0), root.totals == expectedRootTotals else { throw StorageTreeIndexError.invalid("Root totals differ from enumeration") }
        guard try database.integer("SELECT COUNT(*) FROM nodes WHERE id<>0 AND (parent IS NULL OR parent>=id)") == 0 else { throw StorageTreeIndexError.invalid("Invalid graph") }
        database.resetStatements()
        try database.execute("CREATE INDEX sorted_logical ON nodes(parent,logical DESC,name,id)")
        try database.checkSpace()
        try database.execute("CREATE INDEX sorted_allocated ON nodes(parent,allocated DESC,name,id)")
        try database.checkSpace()
        try database.execute("DROP TABLE rollup")
        try treeCreateMutationIndices(database)
        return try treeSummary(database, id: id, maximumNodes: maximumNodes, largestLimit: largestLimit)
    }
    func publish(snapshot: StorageSnapshot) throws {
        guard snapshot.id == id, snapshot.grantID == grantID, snapshot.rootPath == rootPath,
              snapshot.rootIdentity == rootIdentity, snapshot.tree?.id == id else { throw StorageTreeIndexError.invalid("Manifest binding differs") }
        let database = try db()
        try snapshot.validate()
        try database.execute("INSERT INTO metadata VALUES('manifest',?)", [.bytes(try JSONEncoder().encode(snapshot))])
        try database.execute("INSERT INTO metadata VALUES('complete',?)", [.integer(1)])
        database.close(); self.database = nil
        let target = StorageTreeReader.indexURL(directoryURL: directoryURL, id: id)
        guard renameatx_np(directoryFD, temporaryURL.lastPathComponent, directoryFD, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw StorageTreeIndexError.io("Cannot publish completed index")
        }
        published = true
    }
    func abort() {
        database?.close(); database = nil
        if !handedOff && createdTemporary && directoryFD >= 0 {
            let name = published ? StorageTreeReader.indexURL(directoryURL: directoryURL, id: id).lastPathComponent : temporaryURL.lastPathComponent
            _ = unlinkat(directoryFD, name, 0)
        }
        if !handedOff && createdLease && directoryFD >= 0 { _ = unlinkat(directoryFD, id.uuidString + ".lease", 0) }
        if directoryFD >= 0 { Darwin.close(directoryFD); directoryFD = -1 }
        scanLease?.close(); scanLease = nil
    }
    func completeHandoff() {
        handedOff = true
        if directoryFD >= 0 { Darwin.close(directoryFD); directoryFD = -1 }
        scanLease?.close(); scanLease = nil
    }
}

private func treeCreateMutationIndices(_ database: TreeDatabase) throws {
    try database.execute("CREATE INDEX IF NOT EXISTS duplicate_identity ON nodes(device,inode,birth,birthns,id) WHERE kind='file' AND duplicate=1")
    for metric in ["logical", "allocated"] {
        try database.checkSpace()
        try database.execute("CREATE INDEX IF NOT EXISTS largest_\(metric) ON nodes(\(metric) DESC,name,id) WHERE kind IN ('file','package') AND inside=0")
    }
}
private func treeSummary(_ database: TreeDatabase, id: UUID, maximumNodes: Int, largestLimit: Int) throws -> StorageTreeSummary {
        guard let root = try treeReference(database, 0) else { throw StorageTreeIndexError.invalid("Missing visible root") }
        let descriptor = StorageTreeDescriptor(id: id, formatVersion: database.hasTombstones ? 2 : 1, nodeCount: try database.integer("SELECT COUNT(*) FROM nodes"),
            rootChildCount: try database.integer("SELECT children FROM nodes WHERE id=0"))
        var overview = DualTopItems(limit: max(0, maximumNodes - 1)), largest = DualTopItems(limitPerMetric: max(0, largestLimit))
        if root.kind != .package {
            for metric in ["logical", "allocated"] {
                let children = try database.statement("SELECT id FROM nodes WHERE parent=0 AND \(database.visiblePredicate) ORDER BY \(metric) DESC,name,id LIMIT ?", [.integer(Int64(max(0, maximumNodes - 1)))])
                while try database.step(children) { if let item = try treeReference(database, Int(sqlite3_column_int64(children, 0))) { overview.insert(item) } }
                let files = try database.statement("SELECT id FROM nodes WHERE kind IN ('file','package') AND inside=0 AND \(database.visiblePredicate) ORDER BY \(metric) DESC,name,id LIMIT ?", [.integer(Int64(max(0, largestLimit)))])
                while try database.step(files) { if let item = try treeReference(database, Int(sqlite3_column_int64(files, 0))) { largest.insert(item) } }
            }
        }
        return StorageTreeSummary(descriptor: descriptor, root: root, overview: overview.values, largest: largest.values)
}

private func treeAdjustedSnapshot(_ summary: StorageTreeSummary, original: StorageSnapshot) throws -> StorageSnapshot {
    let root = summary.root
    var listed = StorageTotals.zero
    for item in summary.overview { listed = try StorageScanner.sum(listed, item.totals, path: "cached root") }
    guard listed.logicalBytes <= root.logicalBytes, listed.allocatedBytes <= root.allocatedBytes,
          listed.apparentBytes <= root.apparentBytes, listed.fileCount <= root.fileCount,
          summary.overview.count <= summary.descriptor.rootChildCount else { throw StorageTreeIndexError.invalid("Adjusted overview exceeds root") }
    let omitted = StorageTotals(logicalBytes: root.logicalBytes - listed.logicalBytes,
        allocatedBytes: root.allocatedBytes - listed.allocatedBytes, apparentBytes: root.apparentBytes - listed.apparentBytes,
        fileCount: root.fileCount - listed.fileCount)
    var nodes = [StorageNode(id: 0, parentID: nil, name: root.name, relativePath: "", kind: root.kind,
        identity: root.identity, logicalBytes: root.logicalBytes, allocatedBytes: root.allocatedBytes,
        apparentBytes: root.apparentBytes, fileCount: root.fileCount, isCloudPlaceholder: root.isCloudPlaceholder,
        isIncomplete: root.isIncomplete, unlistedChildren: root.kind == .directory ? omitted : .zero,
        unlistedChildCount: root.kind == .directory ? summary.descriptor.rootChildCount - summary.overview.count : 0)]
    for item in summary.overview.sorted(by: { $0.relativePath < $1.relativePath }) {
        nodes.append(StorageNode(id: item.id, parentID: 0, name: item.name, relativePath: item.relativePath,
            kind: item.kind, identity: item.identity, logicalBytes: item.logicalBytes, allocatedBytes: item.allocatedBytes,
            apparentBytes: item.apparentBytes, fileCount: item.fileCount, isCloudPlaceholder: item.isCloudPlaceholder,
            isHardLinkDuplicate: item.isHardLinkDuplicate, isIncomplete: item.isIncomplete,
            unlistedChildren: item.kind == .directory ? item.totals : .zero,
            unlistedChildCount: item.kind == .directory ? item.unlistedChildCount : 0))
    }
    let snapshot = StorageSnapshot(id: summary.descriptor.id, grantID: original.grantID, rootPath: original.rootPath,
        rootIdentity: original.rootIdentity, scannedAt: original.scannedAt, nodes: nodes, issues: original.issues,
        omittedIssueCount: original.omittedIssueCount, volume: original.volume, schemaVersion: 3,
        largestCatalog: summary.largest, authorizationRootPath: original.authorizationRootPath,
        authorizationRootIdentity: original.authorizationRootIdentity, rootAncestors: original.rootAncestors,
        scanMethod: original.scanMethod, tree: summary.descriptor)
    try snapshot.validate()
    return snapshot
}

public actor StorageTreeReader {
    private var database: TreeDatabase?
    private let directoryURL: URL
    private let snapshot: StorageSnapshot
    public nonisolated static func indexURL(directoryURL: URL, id: UUID, building: Bool = false) -> URL {
        directoryURL.appending(path: id.uuidString + (building ? ".building.sqlite" : ".sqlite"))
    }
    /// Metadata-only authority is scoped to one canonical cache generation. A missing
    /// marker is distinct from an unsafe existing name: symlinks/foreign files throw.
    public nonisolated static func isSuperseded(directoryURL: URL, id: UUID) throws -> Bool {
        try StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            let directory = try treeDirectoryFD(directoryURL, create: false, allowMissing: true)
            if directory < 0 { return false }
            defer { Darwin.close(directory) }
            let descriptor = openat(directory, id.uuidString + ".superseded", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if descriptor < 0 {
                if errno == ENOENT { return false }
                throw StorageTreeIndexError.invalid("Cannot safely read generation invalidation marker")
            }
            defer { Darwin.close(descriptor) }
            _ = try treeValidateSupersededMarker(descriptor)
            return true
        }
    }
    /// Returns true only for this operation's newly created provisional marker. The
    /// caller may undo those markers only when this generation was not affected
    /// by any successful physical move.
    public nonisolated static func markSuperseded(directoryURL: URL, id: UUID) throws -> Bool {
        try StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            let directory = try treeDirectoryFD(directoryURL, create: true)
            defer { Darwin.close(directory) }
            let name = id.uuidString + ".superseded"
            var descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            let created = descriptor >= 0
            if descriptor < 0 {
                guard errno == EEXIST else { throw StorageTreeIndexError.io("Cannot create generation invalidation marker") }
                descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard descriptor >= 0 else { throw StorageTreeIndexError.invalid("Unsafe existing generation invalidation marker") }
            }
            defer { Darwin.close(descriptor) }
            do {
                _ = try treeValidateSupersededMarker(descriptor)
                // Existing markers may come from a crashed provisional operation; make
                // their durability explicit before allowing any native file move.
                guard fsync(descriptor) == 0, fsync(directory) == 0 else {
                    throw StorageTreeIndexError.io("Cannot persist generation invalidation marker")
                }
                return created
            } catch {
                if created {
                    var opened = stat(), named = stat()
                    if fstat(descriptor, &opened) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                       named.st_mode & S_IFMT == S_IFREG, named.st_dev == opened.st_dev, named.st_ino == opened.st_ino {
                        _ = unlinkat(directory, name, 0); _ = fsync(directory)
                    }
                }
                throw error
            }
        }
    }
    /// Call only for a marker newly created by the caller's provisional operation,
    /// when this generation was not affected by any successful physical move.
    /// Existing invalidations must never be undone.
    public nonisolated static func unmarkSuperseded(directoryURL: URL, id: UUID) throws {
        try StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            let directory = try treeDirectoryFD(directoryURL, create: false)
            defer { Darwin.close(directory) }
            let name = id.uuidString + ".superseded"
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if descriptor < 0 {
                if errno == ENOENT { return }
                throw StorageTreeIndexError.invalid("Unsafe generation invalidation rollback")
            }
            defer { Darwin.close(descriptor) }
            let opened = try treeValidateSupersededMarker(descriptor)
            var named = stat()
            guard fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
                  unlinkat(directory, name, 0) == 0 else { throw StorageTreeIndexError.io("Generation marker changed during rollback") }
            guard fsync(directory) == 0 else { throw StorageTreeIndexError.io("Cannot persist generation marker rollback") }
        }
    }
    public init(directoryURL: URL, snapshot: StorageSnapshot) throws {
        guard snapshot.schemaVersion == 3, let descriptor = snapshot.tree, descriptor.id == snapshot.id,
              (1...2).contains(descriptor.formatVersion) else { throw StorageTreeIndexError.invalid("Refresh this historical scan to create a full tree") }
        self.directoryURL = directoryURL
        self.snapshot = snapshot
        try snapshot.validate()
        try treePrivateDirectory(directoryURL)
        let database = try TreeDatabase(url: Self.indexURL(directoryURL: directoryURL, id: descriptor.id), writable: false)
        do {
            guard (descriptor.formatVersion == 2) == database.hasTombstones else { throw StorageTreeIndexError.invalid("Tree format and tombstones differ") }
            let saved = try Self.manifest(database, id: descriptor.id)
            guard saved.grantID == snapshot.grantID, saved.rootPath == snapshot.rootPath,
                  saved.rootIdentity == snapshot.rootIdentity, saved.tree == snapshot.tree,
                  saved.authorizationRootPath == snapshot.authorizationRootPath,
                  saved.authorizationRootIdentity == snapshot.authorizationRootIdentity,
                  saved.rootAncestors == snapshot.rootAncestors, saved.nodes == snapshot.nodes,
                  saved.largestCatalog == snapshot.largestCatalog, saved.scannedAt == snapshot.scannedAt,
                  saved.scanMethod == snapshot.scanMethod, saved.issues == snapshot.issues,
                  saved.omittedIssueCount == snapshot.omittedIssueCount, saved.volume == snapshot.volume else {
                throw StorageTreeIndexError.invalid("Index belongs to another manifest")
            }
            self.database = database
        } catch { database.close(); throw error }
    }
    private static func manifest(_ database: TreeDatabase, id: UUID) throws -> StorageSnapshot {
        let ownership = try database.statement("SELECT value FROM metadata WHERE key='owner'")
        defer { sqlite3_reset(ownership) }
        guard try database.step(ownership), try treeText(ownership, 0) == "com.witqq.mac-utils.storage-tree" else { throw StorageTreeIndexError.invalid("Unowned index") }
        let identifier = try database.statement("SELECT value FROM metadata WHERE key='id'")
        defer { sqlite3_reset(identifier) }
        guard try database.step(identifier), try treeText(identifier, 0) == id.uuidString,
              try database.integer("SELECT value FROM metadata WHERE key='complete'") == 1 else { throw StorageTreeIndexError.invalid("Incomplete index") }
        let statement = try database.statement("SELECT value FROM metadata WHERE key='manifest'")
        defer { sqlite3_reset(statement) }
        guard try database.step(statement), let bytes = sqlite3_column_blob(statement, 0) else { throw StorageTreeIndexError.invalid("Missing manifest") }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, count <= 32 * 1_024 * 1_024 else { throw StorageTreeIndexError.invalid("Invalid manifest length") }
        let snapshot = try JSONDecoder().decode(StorageSnapshot.self, from: Data(bytes: bytes, count: count))
        try snapshot.validate()
        guard snapshot.id == id, snapshot.tree?.nodeCount == (try database.integer("SELECT COUNT(*) FROM nodes")),
              let root = try treeLookup(database, 0), root.identity == snapshot.rootIdentity,
              root.row.totals.logicalBytes == snapshot.root?.logicalBytes,
              root.row.totals.allocatedBytes == snapshot.root?.allocatedBytes,
              root.row.totals.apparentBytes == snapshot.root?.apparentBytes,
              root.row.totals.fileCount == snapshot.root?.fileCount,
              root.row.kind == snapshot.root?.kind,
              root.row.isCloudPlaceholder == snapshot.root?.isCloudPlaceholder,
              root.row.isIncomplete == snapshot.root?.isIncomplete,
              !root.row.isHardLinkDuplicate,
              root.row.childCount == (try database.integer("SELECT COUNT(*) FROM nodes WHERE parent=0 AND \(database.visiblePredicate)")),
              root.row.childCount == snapshot.tree?.rootChildCount else { throw StorageTreeIndexError.invalid("Index root/count differs") }
        return snapshot
    }
    public func children(parentID: Int, metric: StorageSizeMetric, descending: Bool = true, offset: Int, limit: Int) throws -> StorageTreePage {
        guard let database, offset >= 0, limit > 0, let parent = try treeLookup(database, parentID),
              parent.row.kind == .directory || parent.row.kind == .package else { throw StorageTreeIndexError.invalid("Invalid parent/page") }
        guard let parentReference = try treeReference(database, parentID),
              parent.row.childCount == (try database.integer("SELECT COUNT(*) FROM nodes WHERE parent=? AND \(database.visiblePredicate)", [.integer(Int64(parentID))])) else {
            throw StorageTreeIndexError.invalid("Child count differs")
        }
        let inside = parentReference.isInsidePackage || parentReference.kind == .package
        let column = metric == .logical ? "logical" : "allocated", direction = descending ? "DESC" : "ASC"
        let statement = try database.statement("SELECT \(treeColumns) FROM nodes WHERE parent=? AND \(database.visiblePredicate) ORDER BY \(column) \(direction),name,id LIMIT ? OFFSET ?",
            [.integer(Int64(parentID)), .integer(Int64(min(limit, 4_096))), .integer(Int64(offset))])
        var rows: [StorageTreeRow] = []
        while try database.step(statement) {
            try Task.checkCancellation()
            let row = try treeRecord(statement).row
            guard row.parentID == parentID, row.isInsidePackage == inside else { throw StorageTreeIndexError.invalid("Child package ancestry differs") }
            rows.append(row)
        }
        return StorageTreePage(rows: rows, offset: offset, totalCount: parent.row.childCount)
    }
    public func item(id: Int) throws -> StorageItemReference? {
        guard let database else { throw StorageTreeIndexError.io("Index is closed") }
        return try treeReference(database, id)
    }
    /// Applies known successful removals to historical metadata. No source path is
    /// queried, and the original immutable generation remains usable by its readers.
    public func prunedSnapshot(removing nodeIDs: [Int], maximumNodes: Int = 1_001,
                               largestLimit: Int = 200) throws -> StorageSnapshot {
        try Task.checkCancellation()
        guard let original = database, !nodeIDs.isEmpty, !nodeIDs.contains(0), maximumNodes > 0, largestLimit >= 0 else {
            throw StorageTreeIndexError.invalid("Invalid cached-tree removal")
        }
        let selected = Set(nodeIDs)
        var roots: [TreeRecord] = []
        for id in selected.sorted() {
            guard let item = try treeLookup(original, id) else { throw StorageTreeIndexError.invalid("Removal is absent from this generation") }
            var ancestor = item.row.parentID, covered = false
            while let parent = ancestor {
                if selected.contains(parent) { covered = true; break }
                guard let row = try treeLookup(original, parent) else { throw StorageTreeIndexError.invalid("Removal has a hidden parent") }
                ancestor = row.row.parentID
            }
            if !covered { roots.append(item) }
        }
        let generation = UUID(), scanLease = try StorageTreeScanLease(directoryURL: directoryURL)
        defer { scanLease.close() }
        let directory = try treeDirectoryFD(directoryURL, create: false)
        defer { Darwin.close(directory) }
        let building = Self.indexURL(directoryURL: directoryURL, id: generation, building: true)
        let leaseName = generation.uuidString + ".lease"
        var cloned = false, leased = false, published = false
        var update: TreeDatabase?
        defer {
            update?.close()
            if !published {
                if cloned { _ = unlinkat(directory, building.lastPathComponent, 0) }
                if leased { _ = unlinkat(directory, leaseName, 0) }
            }
        }
        try StorageDatalessPolicy.withMaterializationDisabled { enabled in
            guard enabled else { throw StorageDatalessPolicyError.unavailable }
            let lease = openat(directory, leaseName, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lease >= 0 else { throw StorageTreeIndexError.io("Cannot create update lease") }
            leased = true; Darwin.close(lease)
            guard fclonefileat(original.lockFD, directory, building.lastPathComponent, 0) == 0 else {
                throw StorageTreeIndexError.io("Cannot clone the cached analysis without copying its contents: \(String(cString: strerror(errno)))")
            }
            cloned = true
        }
        // A crash immediately after clone may leave an unclaimed private building file;
        // cleanup deliberately does not treat its copied source UUID as disposal authority.
        let db = try TreeDatabase(url: building, writable: true); update = db
        try db.execute("UPDATE metadata SET value=? WHERE key='id'", [.text(generation.uuidString)])
        try db.execute("UPDATE metadata SET value=0 WHERE key='complete'")
        if !db.hasTombstones { try db.execute("CREATE TABLE tombstones(id INTEGER PRIMARY KEY REFERENCES nodes(id))"); db.hasTombstones = true }
        try db.execute("PRAGMA temp_store=FILE")
        try treeCreateMutationIndices(db)
        try db.execute("CREATE TEMP TABLE removed(id INTEGER PRIMARY KEY)")
        try db.execute("BEGIN")
        var subtract: [Int: StorageTotals] = [:], add: [Int: StorageTotals] = [:], childRemovals: [Int: Int] = [:]
        func contribute(_ item: TreeRecord, _ totals: StorageTotals, to deltas: inout [Int: StorageTotals]) throws {
            var ancestor = item.row.parentID
            while let id = ancestor {
                try Task.checkCancellation()
                deltas[id] = try StorageScanner.sum(deltas[id] ?? .zero, totals, path: "cached node \(id)")
                guard let parent = try treeLookup(db, id, includeHidden: true) else { throw StorageTreeIndexError.invalid("Missing update ancestor") }
                ancestor = parent.row.parentID
            }
        }
        for item in roots {
            try contribute(item, item.row.totals, to: &subtract)
            if let parent = item.row.parentID { childRemovals[parent, default: 0] += 1 }
            try db.execute("WITH RECURSIVE subtree(id) AS (SELECT ? UNION ALL SELECT nodes.id FROM nodes JOIN subtree ON nodes.parent=subtree.id WHERE \(db.visiblePredicate)) INSERT INTO removed SELECT id FROM subtree", [.integer(Int64(item.row.id))])
        }
        try db.execute("INSERT INTO tombstones SELECT id FROM removed")
        let owners = try db.statement("SELECT \(treeColumns.split(separator: ",").map { "nodes." + String($0) }.joined(separator: ",")) FROM nodes JOIN removed ON removed.id=nodes.id WHERE kind='file' AND duplicate=0")
        while try db.step(owners) {
            try Task.checkCancellation()
            let owner = try treeRecord(owners)
            let survivors = try db.statement("SELECT id FROM nodes WHERE kind='file' AND duplicate=1 AND device=? AND inode=? AND birth=? AND birthns=? AND \(db.visiblePredicate) ORDER BY id LIMIT 1", [
                .bytes(treeBytes(owner.identity.device)), .bytes(treeBytes(owner.identity.inode)),
                .integer(owner.identity.birthSeconds), .integer(owner.identity.birthNanoseconds)])
            if try db.step(survivors) {
                let id = Int(sqlite3_column_int64(survivors, 0)); sqlite3_reset(survivors)
                guard let survivor = try treeLookup(db, id) else { throw StorageTreeIndexError.invalid("Missing surviving hard link") }
                let bytes = StorageTotals(logicalBytes: owner.row.totals.logicalBytes,
                    allocatedBytes: owner.row.totals.allocatedBytes, apparentBytes: 0, fileCount: 0)
                try contribute(survivor, bytes, to: &add)
                try db.execute("UPDATE nodes SET logical=?,allocated=?,duplicate=0 WHERE id=?", [
                    .bytes(treeBytes(bytes.logicalBytes)), .bytes(treeBytes(bytes.allocatedBytes)), .integer(Int64(id))])
            } else { sqlite3_reset(survivors) }
        }
        sqlite3_reset(owners)
        for id in Set(subtract.keys).union(add.keys) {
            guard let row = try treeLookup(db, id) else { throw StorageTreeIndexError.invalid("Hidden adjusted ancestor") }
            let minus = subtract[id] ?? .zero, plus = add[id] ?? .zero, totals = row.row.totals
            guard minus.logicalBytes <= totals.logicalBytes, minus.allocatedBytes <= totals.allocatedBytes,
                  minus.apparentBytes <= totals.apparentBytes, minus.fileCount <= totals.fileCount,
                  (childRemovals[id] ?? 0) <= row.row.childCount else { throw StorageTreeIndexError.invalid("Removal exceeds cached totals") }
            let adjusted = try StorageScanner.sum(StorageTotals(logicalBytes: totals.logicalBytes - minus.logicalBytes,
                allocatedBytes: totals.allocatedBytes - minus.allocatedBytes, apparentBytes: totals.apparentBytes - minus.apparentBytes,
                fileCount: totals.fileCount - minus.fileCount), plus, path: "cached node \(id)")
            try db.execute("UPDATE nodes SET logical=?,allocated=?,apparent=?,files=?,children=? WHERE id=?", [
                .bytes(treeBytes(adjusted.logicalBytes)), .bytes(treeBytes(adjusted.allocatedBytes)), .bytes(treeBytes(adjusted.apparentBytes)),
                .integer(Int64(adjusted.fileCount)), .integer(Int64(row.row.childCount - (childRemovals[id] ?? 0))), .integer(Int64(id))])
        }
        db.resetStatements(); try db.execute("COMMIT")
        let summary = try treeSummary(db, id: generation, maximumNodes: maximumNodes, largestLimit: largestLimit)
        let result = try treeAdjustedSnapshot(summary, original: snapshot)
        try db.execute("UPDATE metadata SET value=? WHERE key='manifest'", [.bytes(try JSONEncoder().encode(result))])
        try db.execute("UPDATE metadata SET value=1 WHERE key='complete'")
        try Task.checkCancellation()
        db.close(); update = nil
        guard renameatx_np(directory, building.lastPathComponent, directory,
            Self.indexURL(directoryURL: directoryURL, id: generation).lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw StorageTreeIndexError.io("Cannot publish updated analysis")
        }
        published = true
        return result
    }
    public func close() { database?.close(); database = nil }
    public nonisolated static func removeIfUnused(directoryURL: URL, id: UUID, building: Bool = false) throws -> Bool {
        if !FileManager.default.fileExists(atPath: directoryURL.path) { return true }
        try treePrivateDirectory(directoryURL)
        let generationLock = open(directoryURL.appending(path: ".scans.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        if generationLock < 0 { if errno == ENOENT { return true }; throw StorageTreeIndexError.io("Cannot open cleanup lock") }
        defer { Darwin.close(generationLock) }
        var lockMetadata = stat()
        guard fstat(generationLock, &lockMetadata) == 0, lockMetadata.st_mode & S_IFMT == S_IFREG,
              lockMetadata.st_uid == geteuid(), lockMetadata.st_mode & 0o077 == 0 else { throw StorageTreeIndexError.invalid("Unowned cleanup lock") }
        guard flock(generationLock, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return false }; throw StorageTreeIndexError.io("Cannot lock analysis cache for cleanup")
        }
        let url = indexURL(directoryURL: directoryURL, id: id, building: building)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 { if errno == ENOENT { return true }; throw StorageTreeIndexError.io(String(cString: strerror(errno))) }
        defer { Darwin.close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_uid == geteuid(), initial.st_mode & 0o077 == 0 else { throw StorageTreeIndexError.invalid("Unowned cleanup file") }
        let lease = directoryURL.appending(path: id.uuidString + ".lease")
        let leaseFD = open(lease.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard leaseFD >= 0 else { throw StorageTreeIndexError.invalid("Missing index cleanup lease") }
        defer { Darwin.close(leaseFD) }
        var leaseMetadata = stat()
        guard fstat(leaseFD, &leaseMetadata) == 0, leaseMetadata.st_mode & S_IFMT == S_IFREG,
              leaseMetadata.st_uid == geteuid(), leaseMetadata.st_mode & 0o077 == 0 else { throw StorageTreeIndexError.invalid("Unowned cleanup lease") }
        guard flock(leaseFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return false }; throw StorageTreeIndexError.io("Cannot lock index for cleanup")
        }
        // SQLite owns its data-file locking. The separate native lease prevents cleanup
        // without conflicting with SQLite's locking implementation on macOS.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }; throw StorageTreeIndexError.invalid("Cannot verify cleanup ownership")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT key,value FROM metadata WHERE key IN ('owner','id')", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StorageTreeIndexError.invalid("Unowned cleanup target") }
        defer { sqlite3_finalize(statement) }
        var owner = false, identifier = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = try treeText(statement, 0), value = try treeText(statement, 1)
            if key == "owner" { owner = value == "com.witqq.mac-utils.storage-tree" }
            if key == "id" { identifier = value == id.uuidString }
        }
        var opened = stat(), named = stat()
        guard owner, identifier, fstat(descriptor, &opened) == 0, lstat(url.path, &named) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { throw StorageTreeIndexError.invalid("Cleanup target changed") }
        let removeMarker: Bool
        do { removeMarker = try isSuperseded(directoryURL: directoryURL, id: id) }
        catch StorageTreeIndexError.invalid(_) { removeMarker = false } // Preserve foreign marker names/symlinks.
        guard unlink(url.path) == 0 else { throw StorageTreeIndexError.io(String(cString: strerror(errno))) }
        guard unlink(lease.path) == 0 else { throw StorageTreeIndexError.io("Index removed, but its lease could not be cleaned") }
        if removeMarker { try unmarkSuperseded(directoryURL: directoryURL, id: id) }
        return true
    }
}
