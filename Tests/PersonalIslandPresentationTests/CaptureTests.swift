import CoreGraphics
import Foundation
import Testing
@testable import PersonalIslandPresentation

// MARK: - Selection geometry

private let macBook = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let dellLeftBelow = CGRect(x: -1920, y: -600, width: 1920, height: 1080)

@Test func dragInAnyDirectionProducesTheSameNormalizedSelection() {
    let a = CGPoint(x: 100, y: 200), b = CGPoint(x: 400, y: 500)
    let expected = CGRect(x: 100, y: 200, width: 300, height: 300)
    #expect(CaptureGeometry.selection(from: a, to: b, within: macBook) == expected)
    #expect(CaptureGeometry.selection(from: b, to: a, within: macBook) == expected)
    #expect(CaptureGeometry.selection(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 400, y: 200), within: macBook) == expected)
}

@Test func selectionIsClampedToTheDisplayWhereTheDragStarted() {
    let selection = CaptureGeometry.selection(
        from: CGPoint(x: 1400, y: 900), to: CGPoint(x: 1700, y: 1200), within: macBook
    )
    #expect(selection == CGRect(x: 1400, y: 900, width: 112, height: 82))
}

@Test func selectionOnADisplayWithNegativeOriginStaysInsideIt() {
    let selection = CaptureGeometry.selection(
        from: CGPoint(x: -50, y: -700), to: CGPoint(x: -500, y: -100), within: dellLeftBelow
    )
    #expect(selection == CGRect(x: -500, y: -600, width: 450, height: 500))
}

@Test func fractionalDragsAreExpandedToWholePointsWithoutLeavingTheDisplay() {
    let selection = CaptureGeometry.selection(
        from: CGPoint(x: 10.4, y: 20.6), to: CGPoint(x: 1511.7, y: 981.9), within: macBook
    )
    #expect(selection == CGRect(x: 10, y: 20, width: 1502, height: 962))
}

@Test func clicksTinyDragsAndInvalidInputSelectNothing() {
    let p = CGPoint(x: 300, y: 300)
    #expect(CaptureGeometry.selection(from: p, to: p, within: macBook) == nil)
    #expect(CaptureGeometry.selection(from: p, to: CGPoint(x: 303, y: 400), within: macBook) == nil)
    #expect(CaptureGeometry.selection(from: p, to: CGPoint(x: 400, y: 302), within: macBook) == nil)
    #expect(CaptureGeometry.selection(from: CGPoint(x: CGFloat.nan, y: 0), to: p, within: macBook) == nil)
    #expect(CaptureGeometry.selection(from: p, to: CGPoint(x: 400, y: CGFloat.infinity), within: macBook) == nil)
    #expect(CaptureGeometry.selection(from: p, to: CGPoint(x: 400, y: 400), within: .zero) == nil)
    #expect(CaptureGeometry.selection(from: p, to: CGPoint(x: 400, y: 400), within: .null) == nil)
    // Entirely outside the starting display.
    #expect(CaptureGeometry.selection(from: CGPoint(x: 2000, y: 0), to: CGPoint(x: 2400, y: 400), within: macBook) == nil)
}

@Test func appKitRectsFlipToCoreGraphicsGlobalCoordinates() {
    let primary = macBook
    // Top-left corner region of the primary display.
    #expect(CaptureGeometry.coreGraphicsRect(fromAppKit: CGRect(x: 0, y: 882, width: 200, height: 100), primaryDisplay: primary)
            == CGRect(x: 0, y: 0, width: 200, height: 100))
    // Bottom edge of the primary display.
    #expect(CaptureGeometry.coreGraphicsRect(fromAppKit: CGRect(x: 10, y: 0, width: 50, height: 40), primaryDisplay: primary)
            == CGRect(x: 10, y: 942, width: 50, height: 40))
    // A display left of and below the primary keeps negative x and lies below it.
    #expect(CaptureGeometry.coreGraphicsRect(fromAppKit: CGRect(x: -500, y: -600, width: 450, height: 500), primaryDisplay: primary)
            == CGRect(x: -500, y: 1082, width: 450, height: 500))
    // A display above the primary has negative Core Graphics y.
    #expect(CaptureGeometry.coreGraphicsRect(fromAppKit: CGRect(x: 0, y: 1500, width: 100, height: 100), primaryDisplay: primary)
            == CGRect(x: 0, y: -618, width: 100, height: 100))
}

@Test func coordinateConversionRejectsInvalidInput() {
    #expect(CaptureGeometry.coreGraphicsRect(fromAppKit: .zero, primaryDisplay: macBook) == nil)
    #expect(CaptureGeometry.coreGraphicsRect(fromAppKit: CGRect(x: 0, y: 0, width: 10, height: 10), primaryDisplay: .null) == nil)
    #expect(CaptureGeometry.coreGraphicsRect(fromAppKit: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), primaryDisplay: macBook) == nil)
}

// MARK: - Capture lifecycle

private struct CaptureFailed: Error {}
private struct ShelfFull: Error {}

@MainActor
private final class FakeCapturePlatform {
    var permitted = true
    var log: [String] = []
    var selection: CGRect? = CGRect(x: 0, y: 0, width: 100, height: 100)
    var captureError: (any Error)?
    var admitError: (any Error)?
    var admitted: [Data] = []
    var pendingSelection: CheckedContinuation<CGRect?, Never>?
    var holdSelection = false

    func environment() -> CaptureFlow.Environment {
        CaptureFlow.Environment(
            hasPermission: { [unowned self] in self.permitted },
            requestPermission: { [unowned self] in self.log.append("request") },
            hideIslands: { [unowned self] in self.log.append("hide") },
            restoreIslands: { [unowned self] in self.log.append("restore") },
            selectRegion: { [unowned self] in
                self.log.append("select")
                if self.holdSelection {
                    return await withCheckedContinuation { self.pendingSelection = $0 }
                }
                return self.selection
            },
            cancelSelection: { [unowned self] in
                self.log.append("cancelSelection")
                self.pendingSelection?.resume(returning: nil)
                self.pendingSelection = nil
            },
            captureRegion: { [unowned self] rect in
                self.log.append("capture")
                if let error = self.captureError { throw error }
                return Data("png-\(Int(rect.width))".utf8)
            },
            admit: { [unowned self] data in
                self.log.append("admit")
                if let error = self.admitError { throw error }
                self.admitted.append(data)
            },
            classify: { error in error is ShelfFull ? .shelfFull : .capture }
        )
    }
}

@Test @MainActor func successfulCaptureHidesIslandsAdmitsOnceAndRestores() async {
    let platform = FakeCapturePlatform()
    let flow = CaptureFlow(environment: platform.environment())
    #expect(await flow.run() == .captured)
    #expect(platform.log == ["hide", "select", "capture", "admit", "restore"])
    #expect(platform.admitted == [Data("png-100".utf8)])
    #expect(flow.phase == .idle)
}

@Test @MainActor func missingPermissionRequestsItWithoutHidingOrCapturing() async {
    let platform = FakeCapturePlatform()
    platform.permitted = false
    let flow = CaptureFlow(environment: platform.environment())
    #expect(await flow.run() == .permissionNeeded)
    #expect(platform.log == ["request"])
    #expect(flow.phase == .idle)
}

@Test @MainActor func cancelledSelectionRestoresIslandsWithoutCapturing() async {
    let platform = FakeCapturePlatform()
    platform.selection = nil
    let flow = CaptureFlow(environment: platform.environment())
    #expect(await flow.run() == .cancelled)
    #expect(platform.log == ["hide", "select", "restore"])
    #expect(platform.admitted.isEmpty)
}

@Test @MainActor func captureAndAdmissionFailuresRestoreIslandsAndReportTheReason() async {
    let platform = FakeCapturePlatform()
    platform.captureError = CaptureFailed()
    let flow = CaptureFlow(environment: platform.environment())
    #expect(await flow.run() == .failed(.capture))
    #expect(platform.log == ["hide", "select", "capture", "restore"])

    platform.log = []
    platform.captureError = nil
    platform.admitError = ShelfFull()
    #expect(await flow.run() == .failed(.shelfFull))
    #expect(platform.log == ["hide", "select", "capture", "admit", "restore"])
    #expect(platform.admitted.isEmpty)
    #expect(flow.phase == .idle)
}

@Test @MainActor func aSecondRequestDuringSelectionIsRejectedAndCancelEndsTheFirst() async {
    let platform = FakeCapturePlatform()
    platform.holdSelection = true
    let flow = CaptureFlow(environment: platform.environment())
    let first = Task { await flow.run() }
    while platform.pendingSelection == nil { await Task.yield() }
    #expect(flow.phase == .selecting)
    #expect(await flow.run() == .busy)
    #expect(platform.log == ["hide", "select"])

    flow.cancel()
    #expect(await first.value == .cancelled)
    #expect(platform.log == ["hide", "select", "cancelSelection", "restore"])
    #expect(flow.phase == .idle)

    // Cancelling while idle does nothing; a new capture can start.
    flow.cancel()
    platform.holdSelection = false
    platform.log = []
    #expect(await flow.run() == .captured)
    #expect(platform.log == ["hide", "select", "capture", "admit", "restore"])
}
