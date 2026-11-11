import Darwin
import Foundation
import Testing
@testable import PersonalIslandCore

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private final class Fixture {
    let base: URL
    var exports: URL { base.appendingPathComponent("exports", isDirectory: true) }
    var original: URL { base.appendingPathComponent("original.txt") }
    let originalBytes = Data("Synthetic original: preserve me".utf8)

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalIslandCoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try originalBytes.write(to: original)
    }
    deinit { try? FileManager.default.removeItem(at: base) }

    func store(clock: TestClock = TestClock(), limits: ShelfLimits = try! ShelfLimits()) throws -> ShelfStore {
        try ShelfStore(exportRoot: exports, limits: limits, now: { clock.now() })
    }

    func assertOriginalIntact() throws {
        #expect(try Data(contentsOf: original) == originalBytes)
    }
}

private func syntheticPNG(_ size: Int = 8) -> Data { Data(repeating: 0xA5, count: size) }

@Test func screenshotsStayInMemoryUntilFileDrag() async throws {
    let fixture = try Fixture()
    let store = try fixture.store()
    let id = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path)
    #expect(contents == ["catalog.json"])
    #expect(await store.snapshot().items.map(\.id) == [id])
    #expect(await store.snapshot().screenshotByteCount == 8)
}

@Test func capacityFailureNeverEvictsExistingItems() async throws {
    let fixture = try Fixture()
    let store = try fixture.store(limits: ShelfLimits(maximumScreenshots: 2, maximumScreenshotBytes: 10))
    let first = try await store.addScreenshot(encodedPNG: syntheticPNG(6))
    await #expect(throws: ShelfError.capacityExceeded) {
        try await store.addScreenshot(encodedPNG: syntheticPNG(5))
    }
    let second = try await store.addScreenshot(encodedPNG: syntheticPNG(4))
    await #expect(throws: ShelfError.capacityExceeded) {
        try await store.addScreenshot(encodedPNG: Data())
    }
    let snapshot = await store.snapshot()
    #expect(snapshot.items.map(\.id) == [first, second])
    #expect(snapshot.screenshotByteCount == 10)
}

@Test func exportBudgetRejectsNewFilesWithoutEvictingProtectedExports() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let store = try ShelfStore(
        exportRoot: fixture.exports,
        exportLimits: ExportLimits(maximumFiles: 2, maximumBytes: 10),
        now: { clock.now() }
    )
    let firstID = try await store.addScreenshot(encodedPNG: syntheticPNG(8))
    let first = try await store.beginFileDrag(itemIDs: [firstID])
    try await store.endDrag(first.id)
    await store.clear()
    let secondID = try await store.addScreenshot(encodedPNG: syntheticPNG(8))
    await #expect(throws: ShelfError.exportCapacityExceeded) {
        try await store.beginFileDrag(itemIDs: [secondID])
    }
    #expect(try Data(contentsOf: first.items[0].url) == syntheticPNG(8))
    #expect(await store.snapshot().items.map(\.id) == [secondID])
    clock.advance(ShelfStore.exportGracePeriod)
    #expect(try await store.sweepExpiredExports().removedExportCount == 1)
    let second = try await store.beginFileDrag(itemIDs: [secondID])
    try await store.endDrag(second.id)
}

@Test func exportFileCountLimitAlsoBoundsTinyPayloads() async throws {
    let fixture = try Fixture()
    let store = try ShelfStore(exportRoot: fixture.exports, exportLimits: ExportLimits(maximumFiles: 1, maximumBytes: 100))
    let firstID = try await store.addScreenshot(encodedPNG: Data())
    let first = try await store.beginFileDrag(itemIDs: [firstID])
    try await store.endDrag(first.id)
    await store.clear()
    let secondID = try await store.addScreenshot(encodedPNG: Data())
    await #expect(throws: ShelfError.exportCapacityExceeded) {
        try await store.beginFileDrag(itemIDs: [secondID])
    }
    #expect(FileManager.default.fileExists(atPath: first.items[0].url.path))
}

@Test func originalReferencesSurviveClearAndExpiry() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let store = try fixture.store(clock: clock)
    let reference = try FileReference(url: fixture.original)
    let originalID = await store.addFileReference(reference)
    let screenshotID = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let drag = try await store.beginFileDrag(itemIDs: [originalID, screenshotID])
    #expect(drag.items[0].url == fixture.original)
    #expect(drag.items[0].exportID == nil)
    try await store.endDrag(drag.id)
    await store.clear()
    clock.advance(ShelfStore.exportGracePeriod + 1)
    #expect(try await store.sweepExpiredExports().removedExportCount == 1)
    try fixture.assertOriginalIntact()
    #expect(await store.snapshot().items.isEmpty)
}

@Test func canceledDragRetainsExportAndRepeatedDragReusesIt() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let first = try await store.beginFileDrag(itemIDs: [id])
    try await store.endDrag(first.id) // cancellation uses exactly this same API
    clock.advance(10)
    let second = try await store.beginFileDrag(itemIDs: [id])
    #expect(first.items[0].exportID == second.items[0].exportID)
    #expect(first.items[0].url == second.items[0].url)
    #expect(try Data(contentsOf: second.items[0].url) == syntheticPNG())
    try await store.endDrag(second.id)
    clock.advance(ShelfStore.exportGracePeriod + 1)
    #expect(try await store.sweepExpiredExports().removedExportCount == 0) // source still lives
}

@Test func overlappingDragsProtectRemovedSourceAndRenewGraceAtEnd() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let first = try await store.beginFileDrag(itemIDs: [id])
    let second = try await store.beginFileDrag(itemIDs: [id])
    await store.remove([id])
    try await store.endDrag(first.id)
    clock.advance(ShelfStore.exportGracePeriod + 1)
    #expect(try await store.sweepExpiredExports().removedExportCount == 0)
    try await store.endDrag(second.id)
    #expect(try await store.sweepExpiredExports().removedExportCount == 0)
    clock.advance(ShelfStore.exportGracePeriod - 1)
    #expect(try await store.sweepExpiredExports().removedExportCount == 0)
    clock.advance(1)
    #expect(try await store.sweepExpiredExports().removedExportCount == 1)
    #expect(!FileManager.default.fileExists(atPath: first.items[0].url.path))
}

private func createRetiredExport(fixture: Fixture, clock: TestClock) async throws -> URL {
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let drag = try await store.beginFileDrag(itemIDs: [id])
    try await store.endDrag(drag.id)
    await store.clear()
    return drag.items[0].url
}

@Test func restartRestoresOnlyExportLeasesAndHonorsGrace() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let export = try await createRetiredExport(fixture: fixture, clock: clock)
    clock.advance(ShelfStore.exportGracePeriod - 1)
    let restarted = try fixture.store(clock: clock)
    #expect(await restarted.snapshot().items.isEmpty)
    #expect(try await restarted.sweepExpiredExports().removedExportCount == 0)
    #expect(try Data(contentsOf: export) == syntheticPNG())
    clock.advance(1)
    #expect(try await restarted.sweepExpiredExports().removedExportCount == 1)
    try fixture.assertOriginalIntact()
}

@Test func exportsAndCatalogHavePrivatePermissionsAndGeneratedNames() async throws {
    let fixture = try Fixture()
    let store = try fixture.store()
    let id = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let drag = try await store.beginFileDrag(itemIDs: [id])
    let export = drag.items[0].url
    #expect(UUID(uuidString: export.deletingPathExtension().lastPathComponent) != nil)
    #expect(export.pathExtension == "png")
    #expect(export.deletingLastPathComponent() == fixture.exports)
    let rootMode = try FileManager.default.attributesOfItem(atPath: fixture.exports.path)[.posixPermissions] as? Int
    let fileMode = try FileManager.default.attributesOfItem(atPath: export.path)[.posixPermissions] as? Int
    let catalogMode = try FileManager.default.attributesOfItem(atPath: fixture.exports.appendingPathComponent("catalog.json").path)[.posixPermissions] as? Int
    #expect(rootMode == 0o700)
    #expect(fileMode == 0o600)
    #expect(catalogMode == 0o600)
    try await store.endDrag(drag.id)
}

@Test func corruptCatalogPreservesExportAndOutsideOriginal() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let export = try await createRetiredExport(fixture: fixture, clock: clock)
    try Data("not JSON".utf8).write(to: fixture.exports.appendingPathComponent("catalog.json"))
    #expect(throws: ShelfError.invalidCatalog) { try fixture.store(clock: clock) }
    #expect(try Data(contentsOf: export) == syntheticPNG())
    try fixture.assertOriginalIntact()
}

@Test func missingCatalogDoesNotSweepUntrackedFiles() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let export = try await createRetiredExport(fixture: fixture, clock: clock)
    try FileManager.default.removeItem(at: fixture.exports.appendingPathComponent("catalog.json"))
    #expect(throws: ShelfError.invalidCatalog) { try fixture.store(clock: clock) }
    #expect(FileManager.default.fileExists(atPath: export.path))
    try fixture.assertOriginalIntact()
}

@Test func forgedCatalogPathIsRejectedWithoutFollowingIt() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let export = try await createRetiredExport(fixture: fixture, clock: clock)
    let catalog = fixture.exports.appendingPathComponent("catalog.json")
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
    var records = try #require(object["records"] as? [[String: Any]])
    records[0]["path"] = "../original.txt"
    object["records"] = records
    try JSONSerialization.data(withJSONObject: object).write(to: catalog)
    #expect(throws: ShelfError.invalidCatalog) { try fixture.store(clock: clock) }
    #expect(try Data(contentsOf: export) == syntheticPNG())
    try fixture.assertOriginalIntact()
}

@Test func unknownFileAbortsCleanupWithoutDeletingAnything() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let drag = try await store.beginFileDrag(itemIDs: [id])
    try await store.endDrag(drag.id)
    await store.clear()
    let unknown = fixture.exports.appendingPathComponent("untracked-original.txt")
    try fixture.originalBytes.write(to: unknown)
    clock.advance(ShelfStore.exportGracePeriod + 1)
    await #expect(throws: ShelfError.unrecognizedRoot) { try await store.sweepExpiredExports() }
    #expect(FileManager.default.fileExists(atPath: drag.items[0].url.path))
    #expect(try Data(contentsOf: unknown) == fixture.originalBytes)
    try fixture.assertOriginalIntact()
}

@Test func symlinkedExportCannotDeleteOutsideTarget() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let store = try fixture.store(clock: clock)
    let id = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let drag = try await store.beginFileDrag(itemIDs: [id])
    try await store.endDrag(drag.id)
    await store.clear()
    let export = drag.items[0].url
    try FileManager.default.removeItem(at: export)
    try FileManager.default.createSymbolicLink(at: export, withDestinationURL: fixture.original)
    clock.advance(ShelfStore.exportGracePeriod + 1)
    await #expect(throws: ShelfError.unsafeFile(export.lastPathComponent)) {
        try await store.sweepExpiredExports()
    }
    try fixture.assertOriginalIntact()
}

@Test func symlinkedOrUnrecognizedRootsAreRefused() throws {
    let fixture = try Fixture()
    let unknownRoot = fixture.base.appendingPathComponent("unknown", isDirectory: true)
    try FileManager.default.createDirectory(at: unknownRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let sentinel = unknownRoot.appendingPathComponent("sentinel")
    try fixture.originalBytes.write(to: sentinel)
    #expect(throws: ShelfError.invalidCatalog) { try ShelfStore(exportRoot: unknownRoot) }
    try FileManager.default.createSymbolicLink(at: fixture.exports, withDestinationURL: unknownRoot)
    #expect(throws: (any Error).self) { try fixture.store() }
    #expect(try Data(contentsOf: sentinel) == fixture.originalBytes)
    try fixture.assertOriginalIntact()
}

@Test func invalidDragDoesNotCreateExports() async throws {
    let fixture = try Fixture()
    let store = try fixture.store()
    let id = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let absent = ShelfItemID()
    await #expect(throws: ShelfError.missingItem(absent)) {
        try await store.beginFileDrag(itemIDs: [id, absent])
    }
    await #expect(throws: ShelfError.duplicateDragItems) {
        try await store.beginFileDrag(itemIDs: [id, id])
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.exports.path) == ["catalog.json"])
}

@Test func sameRootCannotHaveConcurrentOwners() async throws {
    let fixture = try Fixture()
    let store = try fixture.store()
    #expect(throws: (any Error).self) { try fixture.store() }
    let id = try await store.addScreenshot(encodedPNG: syntheticPNG())
    let drag = try await store.beginFileDrag(itemIDs: [id])
    #expect(try Data(contentsOf: drag.items[0].url) == syntheticPNG())
    try await store.endDrag(drag.id)
    try fixture.assertOriginalIntact()
}

@Test func failedInitializationReleasesItsDirectoryLock() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    _ = try await createRetiredExport(fixture: fixture, clock: clock)
    let unknown = fixture.exports.appendingPathComponent("unknown")
    try Data("unexpected".utf8).write(to: unknown)
    #expect(throws: ShelfError.unrecognizedRoot) { try fixture.store(clock: clock) }
    try FileManager.default.removeItem(at: unknown)
    let recovered = try fixture.store(clock: clock)
    #expect(try await recovered.sweepExpiredExports().removedExportCount == 0)
    try fixture.assertOriginalIntact()
}

@Test func fifoCatalogIsRejectedWithoutWaitingForAWriter() async throws {
    let fixture = try Fixture()
    let clock = TestClock()
    let export = try await createRetiredExport(fixture: fixture, clock: clock)
    let catalog = fixture.exports.appendingPathComponent("catalog.json")
    try FileManager.default.removeItem(at: catalog)
    #expect(mkfifo(catalog.path, 0o600) == 0)
    #expect(throws: ShelfError.invalidCatalog) { try fixture.store(clock: clock) }
    #expect(try Data(contentsOf: export) == syntheticPNG())
    try fixture.assertOriginalIntact()
}
