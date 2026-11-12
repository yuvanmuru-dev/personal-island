import Darwin
import Foundation
import Testing
@testable import PersonalIslandCore

private final class BoundaryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_810_000_000)
    func now() -> Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
}

private final class BoundaryFixture {
    let base: URL
    let originalBytes = Data((0..<65_539).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ 19) })
    var exports: URL { base.appendingPathComponent("exports", isDirectory: true) }
    var catalog: URL { exports.appendingPathComponent("catalog.json") }
    var original: URL { base.appendingPathComponent("outside-original.bin") }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PersonalIslandBoundaryTests-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        try originalBytes.write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func store(
        clock: BoundaryClock,
        limits: ShelfLimits = try! ShelfLimits(),
        exportLimits: ExportLimits = try! ExportLimits()
    ) throws -> ShelfStore {
        try ShelfStore(exportRoot: exports, limits: limits, exportLimits: exportLimits, now: { clock.now() })
    }

    func assertOriginalIntact() throws {
        #expect(try Data(contentsOf: original) == originalBytes)
    }

    func exportNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: exports.path))
    }
}

private func persistBoundaryExports(
    fixture: BoundaryFixture, clock: BoundaryClock, payloads: [Data]
) async throws -> [URL] {
    let store = try fixture.store(clock: clock)
    var ids: [ShelfItemID] = []
    for payload in payloads { ids.append(try await store.addScreenshot(encodedPNG: payload)) }
    let drag = try await store.beginFileDrag(itemIDs: ids)
    try await store.endDrag(drag.id)
    await store.clear()
    return drag.items.map(\.url)
}

private func assertBatchAdmissionRollsBack(exportLimits: ExportLimits) async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let store = try fixture.store(clock: clock, exportLimits: exportLimits)
    let first = try await store.addScreenshot(encodedPNG: Data(repeating: 0x13, count: 7))
    let second = try await store.addScreenshot(encodedPNG: Data(repeating: 0xEF, count: 7))
    let before = await store.snapshot()
    let catalogBefore = try Data(contentsOf: fixture.catalog)

    await #expect(throws: ShelfError.exportCapacityExceeded) {
        try await store.beginFileDrag(itemIDs: [first, second])
    }

    #expect(await store.snapshot() == before)
    #expect(try Data(contentsOf: fixture.catalog) == catalogBefore)
    #expect(try fixture.exportNames() == ["catalog.json"])
    let retry = try await store.beginFileDrag(itemIDs: [second])
    #expect(try Data(contentsOf: retry.items[0].url) == Data(repeating: 0xEF, count: 7))
    try await store.endDrag(retry.id)
    try fixture.assertOriginalIntact()
}

@Test func batchByteQuotaFailureRollsBackFilesCatalogAndAdmission() async throws {
    try await assertBatchAdmissionRollsBack(exportLimits: ExportLimits(maximumFiles: 4, maximumBytes: 10))
}

@Test func batchFileQuotaFailureRollsBackFilesCatalogAndAdmission() async throws {
    try await assertBatchAdmissionRollsBack(exportLimits: ExportLimits(maximumFiles: 1, maximumBytes: 100))
}

@Test func failedBatchDoesNotRenewAnExistingExportsLease() async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let store = try fixture.store(clock: clock, exportLimits: ExportLimits(maximumFiles: 2, maximumBytes: 10))
    let first = try await store.addScreenshot(encodedPNG: Data(repeating: 1, count: 6))
    let firstDrag = try await store.beginFileDrag(itemIDs: [first])
    try await store.endDrag(firstDrag.id)
    let catalogBefore = try Data(contentsOf: fixture.catalog)
    clock.advance(12 * 60 * 60)
    let second = try await store.addScreenshot(encodedPNG: Data(repeating: 2, count: 6))

    await #expect(throws: ShelfError.exportCapacityExceeded) {
        try await store.beginFileDrag(itemIDs: [first, second])
    }

    #expect(try Data(contentsOf: fixture.catalog) == catalogBefore)
    await store.clear()
    clock.advance(12 * 60 * 60)
    #expect(try await store.sweepExpiredExports().removedExportCount == 1)
    #expect(!FileManager.default.fileExists(atPath: firstDrag.items[0].url.path))
    try fixture.assertOriginalIntact()
}

@Test func emptyAndRepeatedEndRequestsDoNotMutateStateOrExtendRetention() async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: Data([0, 1, 2, 255]))
    let drag = try await store.beginFileDrag(itemIDs: [id])
    try await store.endDrag(drag.id)
    let snapshotBefore = await store.snapshot()
    let catalogBefore = try Data(contentsOf: fixture.catalog)
    clock.advance(23 * 60 * 60)

    await #expect(throws: ShelfError.emptyDrag) { try await store.beginFileDrag(itemIDs: []) }
    await #expect(throws: ShelfError.unknownDragSession) { try await store.endDrag(drag.id) }
    await #expect(throws: ShelfError.unknownDragSession) { try await store.endDrag(DragSessionID()) }

    #expect(await store.snapshot() == snapshotBefore)
    #expect(try Data(contentsOf: fixture.catalog) == catalogBefore)
    #expect(try Data(contentsOf: drag.items[0].url) == Data([0, 1, 2, 255]))
    await store.clear()
    clock.advance(60 * 60)
    #expect(try await store.sweepExpiredExports().removedExportCount == 1)
}

private enum AdmissionOutcome: Equatable, Sendable { case admitted, capacityRejected, unexpectedFailure }

private func concurrentlyAdmitScreenshots(limits: ShelfLimits, expectedCount: Int) async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let store = try fixture.store(clock: clock, limits: limits)
    let outcomes = await withTaskGroup(of: AdmissionOutcome.self, returning: [AdmissionOutcome].self) { group in
        for _ in 0..<32 {
            group.addTask {
                do {
                    try await store.addScreenshot(encodedPNG: Data([0, 128, 255]))
                    return .admitted
                } catch ShelfError.capacityExceeded {
                    return .capacityRejected
                } catch { return .unexpectedFailure }
            }
        }
        var values: [AdmissionOutcome] = []
        for await value in group { values.append(value) }
        return values
    }
    #expect(outcomes.filter { $0 == .admitted }.count == expectedCount)
    #expect(outcomes.filter { $0 == .capacityRejected }.count == 32 - expectedCount)
    #expect(!outcomes.contains(.unexpectedFailure))
    let snapshot = await store.snapshot()
    #expect(snapshot.items.count == expectedCount)
    #expect(Set(snapshot.items.map(\.id)).count == expectedCount)
    #expect(snapshot.screenshotByteCount == expectedCount * 3)
    #expect(try fixture.exportNames() == ["catalog.json"])
    try fixture.assertOriginalIntact()
}

@Test func concurrentAdmissionCannotOversubscribeScreenshotCount() async throws {
    try await concurrentlyAdmitScreenshots(
        limits: ShelfLimits(maximumScreenshots: 5, maximumScreenshotBytes: 1_000), expectedCount: 5
    )
}

@Test func concurrentAdmissionCannotOversubscribeScreenshotBytes() async throws {
    try await concurrentlyAdmitScreenshots(
        limits: ShelfLimits(maximumScreenshots: 100, maximumScreenshotBytes: 10), expectedCount: 3
    )
}

@Test func concurrentDragsReuseOneExportAndProtectUntilEverySessionEnds() async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: fixture.originalBytes)
    let sessions = try await withThrowingTaskGroup(of: DragSession.self, returning: [DragSession].self) { group in
        for _ in 0..<16 { group.addTask { try await store.beginFileDrag(itemIDs: [id]) } }
        var values: [DragSession] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(Set(sessions.map(\.id)).count == 16)
    #expect(Set(sessions.map { $0.items[0].url }).count == 1)
    #expect(try fixture.exportNames().count == 2)
    let last = try #require(sessions.last)
    await store.clear()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for session in sessions.dropLast() { group.addTask { try await store.endDrag(session.id) } }
        try await group.waitForAll()
    }
    clock.advance(ShelfStore.exportGracePeriod + 1)
    #expect(try await store.sweepExpiredExports().removedExportCount == 0)
    #expect(try Data(contentsOf: last.items[0].url) == fixture.originalBytes)
    try await store.endDrag(last.id)
    clock.advance(ShelfStore.exportGracePeriod)
    #expect(try await store.sweepExpiredExports().removedExportCount == 1)
    try fixture.assertOriginalIntact()
}

@Test func variedBinaryPayloadsSurviveExportAndRestartExactly() async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let secondPayload = Data(fixture.originalBytes.reversed())
    let urls = try await persistBoundaryExports(
        fixture: fixture, clock: clock, payloads: [fixture.originalBytes, secondPayload]
    )
    let restarted = try fixture.store(clock: clock)
    #expect(await restarted.snapshot().items.isEmpty)
    #expect(urls[0] != urls[1])
    #expect(try Data(contentsOf: urls[0]) == fixture.originalBytes)
    #expect(try Data(contentsOf: urls[1]) == secondPayload)
    clock.advance(ShelfStore.exportGracePeriod)
    #expect(try await restarted.sweepExpiredExports().removedExportCount == 2)
    try fixture.assertOriginalIntact()
}

private enum CatalogDamage: String, CaseIterable, Sendable {
    case unsupportedVersion, duplicateExportID, duplicateSourceID, reversedTimestamp
    case traversalFileName, separatorFileName, catalogFileName, duplicateFileName, nullFileName
    case readableNameInVersionOneCatalog
}

@Test(arguments: CatalogDamage.allCases)
private func invalidCatalogSemanticsPreserveEveryExport(_ damage: CatalogDamage) async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let payloads = [Data([1, 2, 3]), Data([253, 254, 255])]
    let urls = try await persistBoundaryExports(fixture: fixture, clock: clock, payloads: payloads)
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.catalog)) as? [String: Any])
    var records = try #require(object["records"] as? [[String: Any]])
    switch damage {
    case .unsupportedVersion:
        object["version"] = 999
    case .duplicateExportID:
        records[1]["id"] = records[0]["id"]
    case .duplicateSourceID:
        records[1]["sourceID"] = records[0]["sourceID"]
    case .reversedTimestamp:
        let createdAt = try #require(records[0]["createdAt"] as? Double)
        records[0]["lastUsedAt"] = createdAt - 1_000
    case .traversalFileName:
        records[0]["fileName"] = "../original.txt"
    case .separatorFileName:
        records[0]["fileName"] = "Screenshot 2026-11-12 at 14.32.05/x.png"
    case .catalogFileName:
        records[0]["fileName"] = "catalog.json"
    case .duplicateFileName:
        records[1]["fileName"] = records[0]["fileName"]
    case .nullFileName:
        records[0]["fileName"] = NSNull()
    case .readableNameInVersionOneCatalog:
        object["version"] = 1
    }
    object["records"] = records
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.catalog)

    #expect(throws: ShelfError.invalidCatalog) { try fixture.store(clock: clock) }

    for (url, payload) in zip(urls, payloads) { #expect(try Data(contentsOf: url) == payload) }
    try fixture.assertOriginalIntact()
}

@Test func oversizedButValidJSONCatalogIsRejectedWithoutDeletingExports() async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let payload = Data([0, 255])
    let urls = try await persistBoundaryExports(fixture: fixture, clock: clock, payloads: [payload])
    let validCatalog = try Data(contentsOf: fixture.catalog)
    var oversized = Data(repeating: 0x20, count: 4 * 1_024 * 1_024)
    oversized.append(validCatalog) // leading whitespace keeps the JSON semantically valid
    try oversized.write(to: fixture.catalog)
    #expect(throws: ShelfError.invalidCatalog) { try fixture.store(clock: clock) }
    #expect(try Data(contentsOf: urls[0]) == payload)
    try fixture.assertOriginalIntact()
}

@Test func hardLinkedExportIsRefusedWithoutUnlinkingItsEntryOrOriginal() async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: Data([7, 8, 9]))
    let drag = try await store.beginFileDrag(itemIDs: [id])
    try await store.endDrag(drag.id)
    await store.clear()
    let export = drag.items[0].url
    try FileManager.default.removeItem(at: export)
    try FileManager.default.linkItem(at: fixture.original, to: export)
    clock.advance(ShelfStore.exportGracePeriod)

    await #expect(throws: ShelfError.unsafeFile(export.lastPathComponent)) {
        try await store.sweepExpiredExports()
    }

    #expect(FileManager.default.fileExists(atPath: export.path))
    #expect(try Data(contentsOf: export) == fixture.originalBytes)
    try fixture.assertOriginalIntact()
}

@Test func replacingLiveRootCannotRedirectCleanupOrMutateReplacement() async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: Data([11, 22, 33]))
    let drag = try await store.beginFileDrag(itemIDs: [id])
    try await store.endDrag(drag.id)
    await store.clear()
    let oldRoot = fixture.base.appendingPathComponent("preserved-root", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.exports, to: oldRoot)
    try FileManager.default.createDirectory(
        at: fixture.exports, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    let replacementSentinel = fixture.exports.appendingPathComponent("replacement.bin")
    try fixture.originalBytes.write(to: replacementSentinel)
    clock.advance(ShelfStore.exportGracePeriod)

    await #expect(throws: ShelfError.invalidRoot) { try await store.sweepExpiredExports() }

    #expect(try Data(contentsOf: oldRoot.appendingPathComponent(drag.items[0].url.lastPathComponent)) == Data([11, 22, 33]))
    #expect(try Data(contentsOf: replacementSentinel) == fixture.originalBytes)
    #expect(try fixture.exportNames() == ["replacement.bin"])
    try fixture.assertOriginalIntact()
}

@Test func alreadyMissingExportCanRetireMetadataAndAdmitNewPayload() async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let urls = try await persistBoundaryExports(fixture: fixture, clock: clock, payloads: [Data([1])])
    try FileManager.default.removeItem(at: urls[0]) // model an OS-purged temporary file
    let restarted = try fixture.store(clock: clock, exportLimits: ExportLimits(maximumFiles: 1, maximumBytes: 4))
    clock.advance(ShelfStore.exportGracePeriod)
    #expect(try await restarted.sweepExpiredExports().removedExportCount == 1)
    let id = try await restarted.addScreenshot(encodedPNG: Data([5, 6, 7, 8]))
    let newDrag = try await restarted.beginFileDrag(itemIDs: [id])
    #expect(try Data(contentsOf: newDrag.items[0].url) == Data([5, 6, 7, 8]))
    try await restarted.endDrag(newDrag.id)
    try fixture.assertOriginalIntact()
}

@Test func backwardsClockCannotShortenAnExistingExportsLatestUse() async throws {
    let fixture = try BoundaryFixture()
    let clock = BoundaryClock()
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: Data([42]))
    let first = try await store.beginFileDrag(itemIDs: [id])
    try await store.endDrag(first.id)
    clock.advance(10 * 60 * 60)
    let second = try await store.beginFileDrag(itemIDs: [id])
    clock.advance(-20 * 60 * 60)
    try await store.endDrag(second.id)
    await store.clear()
    clock.advance(34 * 60 * 60) // now 24h after creation, only 14h after latest use
    #expect(try await store.sweepExpiredExports().removedExportCount == 0)
    clock.advance(10 * 60 * 60)
    #expect(try await store.sweepExpiredExports().removedExportCount == 1)
    try fixture.assertOriginalIntact()
}
