import Foundation

/// One shared model for all presenters. The caller supplies a dedicated export
/// root; initialization never selects or scans a user's screenshot folders.
public actor ShelfStore {
    public static let exportGracePeriod: TimeInterval = 24 * 60 * 60
    private let directory: OwnedExportDirectory
    private let limits: ShelfLimits
    private let exportLimits: ExportLimits
    private let now: @Sendable () -> Date
    private var items: [ShelfItem] = []
    private var records: [ExportRecord]
    private var activeDrags: [DragSessionID: Set<ExportID>] = [:]

    public init(
        exportRoot: URL,
        limits: ShelfLimits = try! ShelfLimits(),
        exportLimits: ExportLimits = try! ExportLimits(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let directory = try OwnedExportDirectory(url: exportRoot)
        self.directory = directory
        self.records = directory.initialRecords
        self.limits = limits
        self.exportLimits = exportLimits
        self.now = now
    }

    public func snapshot() -> ShelfSnapshot {
        ShelfSnapshot(items: items, screenshotByteCount: screenshotByteCount)
    }

    /// Capacity failures leave every existing item intact. No silent eviction.
    @discardableResult
    public func addScreenshot(encodedPNG: Data) throws -> ShelfItemID {
        let screenshotCount = items.reduce(0) { count, item in
            if case .screenshot = item.payload { return count + 1 }
            return count
        }
        guard screenshotCount < limits.maximumScreenshots,
              encodedPNG.count <= limits.maximumScreenshotBytes - screenshotByteCount else {
            throw ShelfError.capacityExceeded
        }
        return append(.screenshot(encodedPNG: encodedPNG))
    }

    @discardableResult
    public func addFileReference(_ reference: FileReference) -> ShelfItemID {
        append(.fileReference(reference))
    }

    public func remove(_ ids: [ShelfItemID]) {
        let removed = Set(ids)
        items.removeAll { removed.contains($0.id) }
    }

    public func clear() { items.removeAll() }

    /// Materializes screenshot files only when a file representation is needed.
    /// Every screenshot export and catalog update succeeds before any URL is
    /// published. Original references are returned without filesystem access.
    public func beginFileDrag(itemIDs: [ShelfItemID]) throws -> DragSession {
        guard !itemIDs.isEmpty else { throw ShelfError.emptyDrag }
        guard Set(itemIDs).count == itemIDs.count else { throw ShelfError.duplicateDragItems }
        let requested = try itemIDs.map { id in
            guard let item = items.first(where: { $0.id == id }) else { throw ShelfError.missingItem(id) }
            return item
        }
        try directory.validateInventory(records: records)
        var exportCount = 0
        var exportBytes = 0
        for record in records {
            if let count = try directory.byteCount(record.id) {
                guard count <= Int.max - exportBytes else { throw ShelfError.exportCapacityExceeded }
                exportCount += 1
                exportBytes += count
            }
        }
        var nextRecords = records
        var created: [ExportID] = []
        var dragItems: [DragItem] = []
        do {
            for item in requested {
                switch item.payload {
                case .fileReference(let reference):
                    dragItems.append(DragItem(itemID: item.id, url: reference.url, exportID: nil))
                case .screenshot(let data):
                    let index = nextRecords.firstIndex { $0.sourceID == item.id }
                    let record: ExportRecord
                    if let index, try directory.exists(nextRecords[index].id) {
                        nextRecords[index].lastUsedAt = max(now(), nextRecords[index].lastUsedAt)
                        record = nextRecords[index]
                    } else {
                        guard exportCount < exportLimits.maximumFiles,
                              exportBytes <= exportLimits.maximumBytes,
                              data.count <= exportLimits.maximumBytes - exportBytes else {
                            throw ShelfError.exportCapacityExceeded
                        }
                        if let index { nextRecords.remove(at: index) }
                        let timestamp = now()
                        record = ExportRecord(id: ExportID(), sourceID: item.id, createdAt: timestamp, lastUsedAt: timestamp)
                        try directory.createPNG(data, id: record.id)
                        created.append(record.id)
                        nextRecords.append(record)
                        exportCount += 1
                        exportBytes += data.count
                    }
                    dragItems.append(DragItem(itemID: item.id, url: directory.exportURL(for: record.id), exportID: record.id))
                }
            }
            try directory.commit(nextRecords)
        } catch {
            // Only UUID files just created by this operation are eligible.
            // Failure to remove one leaves an unknown file and a fail-closed
            // next launch, never a broad orphan-deletion sweep.
            for id in created { try? directory.removePNG(id) }
            throw error
        }
        records = nextRecords
        let session = DragSession(id: DragSessionID(), items: dragItems)
        activeDrags[session.id] = Set(dragItems.compactMap(\.exportID))
        return session
    }

    /// Use this for cancellation too. It means the drag ended, not that a send
    /// or upload completed. The grace period renews before protection releases.
    public func endDrag(_ id: DragSessionID) throws {
        guard let exports = activeDrags[id] else { throw ShelfError.unknownDragSession }
        try directory.validateInventory(records: records)
        var nextRecords = records
        for index in nextRecords.indices where exports.contains(nextRecords[index].id) {
            nextRecords[index].lastUsedAt = max(now(), nextRecords[index].lastUsedAt)
        }
        try directory.commit(nextRecords)
        records = nextRecords
        activeDrags.removeValue(forKey: id)
    }

    /// Run periodically and after launch. A closed app cannot enforce a timer.
    /// Unknown files or unsafe directory contents abort cleanup without deletion.
    public func sweepExpiredExports() throws -> CleanupReport {
        try directory.validateInventory(records: records)
        let liveSources = Set(items.map(\.id))
        let activeExports = activeDrags.values.reduce(into: Set<ExportID>()) { $0.formUnion($1) }
        let timestamp = now()
        let expired = records.filter {
            !liveSources.contains($0.sourceID) && !activeExports.contains($0.id)
                && timestamp.timeIntervalSince($0.lastUsedAt) >= Self.exportGracePeriod
        }
        for record in expired { try directory.removePNG(record.id) }
        let removed = Set(expired.map(\.id))
        let nextRecords = records.filter { !removed.contains($0.id) }
        try directory.commit(nextRecords)
        records = nextRecords
        return CleanupReport(removedExportCount: expired.count)
    }

    private var screenshotByteCount: Int {
        items.reduce(0) { total, item in
            if case .screenshot(let data) = item.payload { return total + data.count }
            return total
        }
    }

    private func append(_ payload: ShelfPayload) -> ShelfItemID {
        let item = ShelfItem(id: ShelfItemID(), createdAt: now(), payload: payload)
        items.append(item)
        return item.id
    }
}
