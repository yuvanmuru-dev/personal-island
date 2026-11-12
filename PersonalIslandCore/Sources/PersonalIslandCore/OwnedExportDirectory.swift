import Darwin
import Foundation

private final class DirectoryDescriptor {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { close(value) }
}

/// All mutations are relative to a verified directory descriptor. A file name
/// is either derived from a generated identifier or a readable name that
/// passed `ExportRecord.isReadableFileName`; no other catalog field or display
/// name becomes a path, and names never contain separators. Used only by its
/// owning ShelfStore.
final class OwnedExportDirectory {
    private static let catalogName = "catalog.json"
    private static let maximumCatalogBytes = 4 * 1_024 * 1_024
    let url: URL
    let storeID: UUID
    private let handle: DirectoryDescriptor
    private var descriptor: Int32 { handle.value }
    private let rootDevice: dev_t
    private let rootInode: ino_t
    let initialRecords: [ExportRecord]

    init(url: URL) throws {
        guard url.isFileURL, url.path != "/" else { throw ShelfError.invalidRoot }
        self.url = url.standardizedFileURL
        var created = false
        if mkdir(self.url.path, 0o700) == 0 {
            created = true
        } else if errno != EEXIST {
            throw Self.failure("create export directory")
        }

        let opened = open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw Self.failure("open export directory") }
        handle = DirectoryDescriptor(opened)
        do {
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                throw Self.failure("lock export directory")
            }
            var info = stat()
            guard fstat(opened, &info) == 0 else { throw Self.failure("inspect export directory") }
            guard info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                throw ShelfError.invalidRoot
            }
            rootDevice = info.st_dev
            rootInode = info.st_ino

            if created {
                storeID = UUID()
                initialRecords = []
                try Self.writeCatalog(ExportCatalog(storeID: storeID, records: []), descriptor: opened)
            } else {
                let catalog: ExportCatalog
                do { catalog = try Self.readCatalog(descriptor: opened) }
                catch { throw ShelfError.invalidCatalog }
                storeID = catalog.storeID
                initialRecords = catalog.records
            }
            try validateInventory(records: initialRecords)
        } catch {
            throw error
        }
    }

    func exportURL(for record: ExportRecord) -> URL {
        url.appendingPathComponent(record.storedFileName)
    }

    func validateInventory(records: [ExportRecord]) throws {
        try verifyRootIdentity()
        let allowed = Set(records.map(\.storedFileName)).union([Self.catalogName])
        // Use a separately opened descriptor so directory iteration does not
        // change the shared descriptor's offset on subsequent sweeps.
        let scanDescriptor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scanDescriptor >= 0 else { throw Self.failure("enumerate export directory") }
        guard let directory = fdopendir(scanDescriptor) else {
            close(scanDescriptor)
            throw Self.failure("enumerate export directory")
        }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard allowed.contains(name) else { throw ShelfError.unrecognizedRoot }
            _ = try regularFileInfo(name: name)
            errno = 0
        }
        guard errno == 0 else { throw Self.failure("enumerate export directory") }
    }

    func exists(_ record: ExportRecord) throws -> Bool {
        try regularFileInfo(name: record.storedFileName) != nil
    }

    func byteCount(_ record: ExportRecord) throws -> Int? {
        guard let info = try regularFileInfo(name: record.storedFileName) else { return nil }
        guard info.st_size >= 0, info.st_size <= Int.max else { throw ShelfError.unsafeFile(record.storedFileName) }
        return Int(info.st_size)
    }

    func createPNG(_ data: Data, for record: ExportRecord) throws {
        try verifyRootIdentity()
        try Self.writeNewFile(data, name: record.storedFileName, descriptor: descriptor)
    }

    func removePNG(_ record: ExportRecord) throws {
        try verifyRootIdentity()
        let name = record.storedFileName
        guard try regularFileInfo(name: name) != nil else { return }
        guard unlinkat(descriptor, name, 0) == 0 else { throw Self.failure("remove owned export") }
    }

    func commit(_ records: [ExportRecord]) throws {
        try verifyRootIdentity()
        try Self.writeCatalog(ExportCatalog(storeID: storeID, records: records), descriptor: descriptor)
    }

    private func verifyRootIdentity() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_dev == rootDevice, info.st_ino == rootInode,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw ShelfError.invalidRoot
        }
    }

    private func regularFileInfo(name: String) throws -> stat? {
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw Self.failure("inspect owned export")
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1 else { throw ShelfError.unsafeFile(name) }
        return info
    }

    private static func readCatalog(descriptor: Int32) throws -> ExportCatalog {
        let file = openat(descriptor, catalogName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw failure("read export catalog") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximumCatalogBytes else {
            throw ShelfError.invalidCatalog
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("read export catalog")
            }
            if count == 0 { break }
            guard data.count <= maximumCatalogBytes - count else { throw ShelfError.invalidCatalog }
            data.append(contentsOf: buffer.prefix(count))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(ExportCatalog.self, from: data)
    }

    private static func writeCatalog(_ catalog: ExportCatalog, descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        guard data.count <= maximumCatalogBytes else { throw ShelfError.invalidCatalog }
        let temporaryName = ".catalog-" + UUID().uuidString.lowercased() + ".tmp"
        try writeNewFile(data, name: temporaryName, descriptor: descriptor)
        if renameat(descriptor, temporaryName, descriptor, catalogName) != 0 {
            let error = failure("commit export catalog")
            _ = unlinkat(descriptor, temporaryName, 0)
            throw error
        }
    }

    private static func writeNewFile(_ data: Data, name: String, descriptor: Int32) throws {
        let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw failure("create owned file") }
        var succeeded = false
        defer {
            close(file)
            if !succeeded { _ = unlinkat(descriptor, name, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("write owned file")
                }
                guard count > 0 else { throw ShelfError.storageFailure(operation: "write owned file", code: EIO) }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw failure("flush owned file") }
        succeeded = true
    }

    private static func failure(_ operation: String) -> ShelfError {
        .storageFailure(operation: operation, code: errno)
    }
}
