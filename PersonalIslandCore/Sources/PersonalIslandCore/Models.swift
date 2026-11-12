import Foundation

public struct ShelfItemID: Hashable, Codable, Sendable {
    public let value: UUID
    public init(value: UUID = UUID()) { self.value = value }
}

public struct ExportID: Hashable, Codable, Sendable {
    public let value: UUID
    public init(value: UUID = UUID()) { self.value = value }
}

public struct DragSessionID: Hashable, Sendable {
    public let value: UUID
    public init(value: UUID = UUID()) { self.value = value }
}

/// A reference only. The core never opens, moves, copies, or deletes its target.
public struct FileReference: Equatable, Sendable {
    public let url: URL
    public let bookmarkData: Data?

    public init(url: URL, bookmarkData: Data? = nil) throws {
        guard url.isFileURL else { throw ShelfError.invalidFileReference }
        self.url = url.standardizedFileURL
        self.bookmarkData = bookmarkData
    }
}

public enum ShelfPayload: Equatable, Sendable {
    /// Opaque, already encoded bytes. The capture adapter must validate PNG data.
    case screenshot(encodedPNG: Data)
    case fileReference(FileReference)
}

public struct ShelfItem: Equatable, Sendable {
    public let id: ShelfItemID
    public let createdAt: Date
    public let payload: ShelfPayload
}

public struct ShelfSnapshot: Equatable, Sendable {
    public let items: [ShelfItem]
    public let screenshotByteCount: Int
}

public struct ShelfLimits: Equatable, Sendable {
    public let maximumScreenshots: Int
    public let maximumScreenshotBytes: Int

    public init(maximumScreenshots: Int = 20, maximumScreenshotBytes: Int = 128 * 1_024 * 1_024) throws {
        guard maximumScreenshots > 0, maximumScreenshotBytes > 0 else {
            throw ShelfError.invalidLimits
        }
        self.maximumScreenshots = maximumScreenshots
        self.maximumScreenshotBytes = maximumScreenshotBytes
    }
}

public struct DragItem: Equatable, Sendable {
    public let itemID: ShelfItemID
    public let url: URL
    /// Nil means this is the original reference, outside the export cleanup domain.
    public let exportID: ExportID?
}

public struct ExportLimits: Equatable, Sendable {
    public let maximumFiles: Int
    public let maximumBytes: Int

    public init(maximumFiles: Int = 256, maximumBytes: Int = 512 * 1_024 * 1_024) throws {
        guard maximumFiles > 0, maximumBytes > 0 else { throw ShelfError.invalidLimits }
        self.maximumFiles = maximumFiles
        self.maximumBytes = maximumBytes
    }
}

public struct DragSession: Equatable, Sendable {
    public let id: DragSessionID
    public let items: [DragItem]
}

public struct CleanupReport: Equatable, Sendable {
    public let removedExportCount: Int
}

public enum ShelfError: Error, Equatable, Sendable {
    case invalidFileReference
    case invalidLimits
    case capacityExceeded
    case exportCapacityExceeded
    case emptyDrag
    case duplicateDragItems
    case missingItem(ShelfItemID)
    case unknownDragSession
    case invalidRoot
    case unrecognizedRoot
    case invalidCatalog
    case unsafeFile(String)
    case storageFailure(operation: String, code: Int32)
}

struct ExportRecord: Codable, Equatable, Sendable {
    let id: ExportID
    let sourceID: ShelfItemID
    let createdAt: Date
    var lastUsedAt: Date
    /// Readable name chosen when the export was created. nil for exports
    /// written before readable names (catalog version 1), which use the
    /// generated identifier name. Only names matching `isReadableFileName`
    /// are accepted from a catalog, so this can never express a path.
    let fileName: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, sourceID, createdAt, lastUsedAt, fileName
    }

    init(id: ExportID, sourceID: ShelfItemID, createdAt: Date, lastUsedAt: Date, fileName: String? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.fileName = fileName
    }

    init(from decoder: any Decoder) throws {
        let legacyKeys = Set(CodingKeys.allCases.map(\.rawValue)).subtracting([CodingKeys.fileName.rawValue])
        let isLegacy = (try? requireExactKeys(decoder, expected: legacyKeys)) != nil
        if !isLegacy {
            try requireExactKeys(decoder, expected: Set(CodingKeys.allCases.map(\.rawValue)))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ExportID.self, forKey: .id)
        sourceID = try values.decode(ShelfItemID.self, forKey: .sourceID)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try values.decode(Date.self, forKey: .lastUsedAt)
        fileName = isLegacy ? nil : try values.decode(String.self, forKey: .fileName)
        guard createdAt.timeIntervalSince1970.isFinite,
              lastUsedAt.timeIntervalSince1970.isFinite,
              lastUsedAt >= createdAt,
              fileName.map(Self.isReadableFileName) ?? true else { throw ShelfError.invalidCatalog }
    }

    /// The single file this record owns inside the export directory.
    var storedFileName: String {
        fileName ?? id.value.uuidString.lowercased() + ".png"
    }

    /// `Screenshot YYYY-MM-DD at HH.MM.SS.png`, optionally with ` (2)`…` (9999)`.
    /// Only ASCII digits, spaces, letters of the fixed words, dots and
    /// parentheses: no separators, no leading dot, no traversal.
    static func isReadableFileName(_ name: String) -> Bool {
        name.wholeMatch(of: readableFileNamePattern) != nil
    }

    nonisolated(unsafe) private static let readableFileNamePattern =
        /Screenshot [0-9]{4}-[0-9]{2}-[0-9]{2} at [0-9]{2}\.[0-9]{2}\.[0-9]{2}(?: \((?:[2-9]|[1-9][0-9]{1,3})\))?\.png/
}

struct ExportCatalog: Codable, Sendable {
    let version: Int
    let storeID: UUID
    let records: [ExportRecord]

    enum CodingKeys: String, CodingKey, CaseIterable { case version, storeID, records }

    /// Version 2 adds readable export names; version 1 catalogs still load.
    static let currentVersion = 2

    init(storeID: UUID, records: [ExportRecord]) {
        version = Self.currentVersion
        self.storeID = storeID
        self.records = records
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, expected: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        storeID = try values.decode(UUID.self, forKey: .storeID)
        records = try values.decode([ExportRecord].self, forKey: .records)
        guard version == 1 || version == Self.currentVersion,
              version != 1 || records.allSatisfy({ $0.fileName == nil }),
              Set(records.map(\.id)).count == records.count,
              Set(records.map(\.sourceID)).count == records.count,
              Set(records.map(\.storedFileName)).count == records.count else {
            throw ShelfError.invalidCatalog
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireExactKeys(_ decoder: any Decoder, expected: Set<String>) throws {
    let values = try decoder.container(keyedBy: AnyCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == expected else {
        throw ShelfError.invalidCatalog
    }
}
