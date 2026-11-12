import Darwin
import Foundation
import Testing
@testable import PersonalIslandCore

private final class NameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00:00 UTC
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private final class NameFixture {
    let base: URL
    var exports: URL { base.appendingPathComponent("exports", isDirectory: true) }
    var catalog: URL { exports.appendingPathComponent("catalog.json") }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalIslandNameTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: base) }

    func store(clock: NameClock, zone: String = "UTC") throws -> ShelfStore {
        try ShelfStore(exportRoot: exports, now: { clock.now() }, exportTimeZone: TimeZone(identifier: zone)!)
    }

    func catalogObject() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
    }
}

private func png(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

@Test func capturesInTheSameSecondGetNumberedDistinctNames() async throws {
    let fixture = try NameFixture()
    let clock = NameClock()
    let store = try fixture.store(clock: clock)
    let ids = [
        try await store.addScreenshot(encodedPNG: png(1)),
        try await store.addScreenshot(encodedPNG: png(2)),
        try await store.addScreenshot(encodedPNG: png(3)),
    ]
    let drag = try await store.beginFileDrag(itemIDs: ids)
    #expect(drag.items.map(\.url.lastPathComponent) == [
        "Screenshot 2027-01-15 at 08.00.00.png",
        "Screenshot 2027-01-15 at 08.00.00 (2).png",
        "Screenshot 2027-01-15 at 08.00.00 (3).png",
    ])
    for (item, byte) in zip(drag.items, [UInt8(1), 2, 3]) {
        #expect(try Data(contentsOf: item.url) == png(byte))
    }
    try await store.endDrag(drag.id)
}

@Test func namesUseTheConfiguredLocalTimeZone() async throws {
    let fixture = try NameFixture()
    let clock = NameClock()
    let store = try fixture.store(clock: clock, zone: "America/Chicago")
    let id = try await store.addScreenshot(encodedPNG: png(1))
    let drag = try await store.beginFileDrag(itemIDs: [id])
    #expect(drag.items[0].url.lastPathComponent == "Screenshot 2027-01-15 at 02.00.00.png")
    try await store.endDrag(drag.id)
}

@Test func storedNamesSurviveRestartInAnotherTimeZoneAndAreSweptNormally() async throws {
    let fixture = try NameFixture()
    let clock = NameClock()
    var store: ShelfStore? = try fixture.store(clock: clock)
    let id = try await store!.addScreenshot(encodedPNG: png(7))
    let drag = try await store!.beginFileDrag(itemIDs: [id])
    try await store!.endDrag(drag.id)
    let url = drag.items[0].url
    #expect(try fixture.catalogObject()["version"] as? Int == 2)
    store = nil

    // The stored name is not recomputed, so a time-zone change cannot turn
    // the existing file into an unrecognized one.
    let restarted = try fixture.store(clock: clock, zone: "Asia/Tokyo")
    #expect(try await restarted.sweepExpiredExports().removedExportCount == 0)
    #expect(try Data(contentsOf: url) == png(7))
    clock.advance(ShelfStore.exportGracePeriod)
    #expect(try await restarted.sweepExpiredExports().removedExportCount == 1)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func versionOneCatalogWithGeneratedNamesStillLoadsAndCleansUp() async throws {
    let fixture = try NameFixture()
    let clock = NameClock()
    // Create the directory, then replace its catalog with a version 1 one
    // describing a legacy identifier-named export, as written by 0.3.0.
    _ = try fixture.store(clock: clock)
    let exportID = UUID()
    let legacyName = exportID.uuidString.lowercased() + ".png"
    let legacyURL = fixture.exports.appendingPathComponent(legacyName)
    let created = clock.now().timeIntervalSince1970 * 1_000
    let catalog: [String: Any] = [
        "version": 1,
        "storeID": UUID().uuidString,
        "records": [[
            "id": ["value": exportID.uuidString],
            "sourceID": ["value": UUID().uuidString],
            "createdAt": created,
            "lastUsedAt": created,
        ]],
    ]
    try JSONSerialization.data(withJSONObject: catalog).write(to: fixture.catalog)
    try png(9).write(to: legacyURL)
    chmod(legacyURL.path, 0o600)
    chmod(fixture.catalog.path, 0o600)

    let store = try fixture.store(clock: clock)
    // A new export uses a readable name alongside the legacy file.
    let id = try await store.addScreenshot(encodedPNG: png(1))
    let drag = try await store.beginFileDrag(itemIDs: [id])
    #expect(drag.items[0].url.lastPathComponent == "Screenshot 2027-01-15 at 08.00.00.png")
    try await store.endDrag(drag.id)
    #expect(try fixture.catalogObject()["version"] as? Int == 2)

    // The legacy export is still recognized and expires on schedule.
    clock.advance(ShelfStore.exportGracePeriod)
    #expect(try await store.sweepExpiredExports().removedExportCount == 1)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(FileManager.default.fileExists(atPath: drag.items[0].url.path))
}

@Test func onlyTheExactReadablePatternIsAccepted() {
    for name in [
        "Screenshot 2026-11-12 at 14.32.05.png",
        "Screenshot 2026-11-12 at 14.32.05 (2).png",
        "Screenshot 2026-11-12 at 14.32.05 (9999).png",
    ] {
        #expect(ExportRecord.isReadableFileName(name), "\(name)")
    }
    for name in [
        "", "catalog.json", "../Screenshot 2026-11-12 at 14.32.05.png",
        "Screenshot 2026-11-12 at 14.32.05/../x.png", ".Screenshot 2026-11-12 at 14.32.05.png",
        "Screenshot 2026-11-12 at 14:32:05.png", "Screenshot 2026-11-12 at 14.32.05 (1).png",
        "Screenshot 2026-11-12 at 14.32.05 (02).png", "Screenshot 2026-11-12 at 14.32.05 (10000).png",
        "Screenshot 2026-11-12 at 14.32.05.png.txt", "screenshot 2026-11-12 at 14.32.05.png",
        "Screenshot ٢٠٢٦-11-12 at 14.32.05.png", "Screenshot 2026-11-12 at 14.32.05.png\n",
    ] {
        #expect(!ExportRecord.isReadableFileName(name), "\(name)")
    }
}
