import Combine
import Foundation
import Testing
@testable import PersonalIslandPresentation

// MARK: - Drag lifecycle

private struct ExportFull: Error {}
private struct EndFailed: Error {}

@MainActor
private final class FakeDragPlatform {
    var log: [String] = []
    var beginError: (any Error)?
    var endError: (any Error)?
    var nextSession = 1
    var ended: [Int] = []
    var reported = 0
    var pendingBegin: CheckedContinuation<Void, Never>?
    var holdBegin = false

    func flow() -> ShelfDragFlow<String, Int> {
        ShelfDragFlow(environment: .init(
            begin: { [unowned self] ids in
                self.log.append("begin \(ids.joined(separator: ","))")
                if self.holdBegin { await withCheckedContinuation { self.pendingBegin = $0 } }
                if let error = self.beginError { throw error }
                defer { self.nextSession += 1 }
                return self.nextSession
            },
            end: { [unowned self] session in
                self.log.append("end \(session)")
                self.ended.append(session)
                if let error = self.endError { throw error }
            },
            hold: { [unowned self] held in self.log.append(held ? "hold" : "release") },
            report: { [unowned self] _ in self.reported += 1 }
        ))
    }
}

@Test @MainActor func droppedDragEndsItsSessionExactlyOnceAndReleasesTheShelf() async {
    let platform = FakeDragPlatform()
    let flow = platform.flow()
    var started: [Int] = []
    #expect(await flow.request(["a", "b"]) { started.append($0); return true })
    #expect(started == [1])
    #expect(flow.phase == .dragging)
    #expect(platform.log == ["hold", "begin a,b"])
    await flow.dragEnded()
    await flow.dragEnded()
    #expect(platform.ended == [1])
    #expect(platform.log == ["hold", "begin a,b", "end 1", "release"])
    #expect(flow.phase == .idle)
}

@Test @MainActor func aDragThatCannotStartStillEndsItsPreparedSession() async {
    let platform = FakeDragPlatform()
    let flow = platform.flow()
    #expect(await flow.request(["a"]) { _ in false } == false)
    #expect(platform.ended == [1])
    #expect(platform.log == ["hold", "begin a", "end 1", "release"])
    #expect(flow.phase == .idle)
}

@Test @MainActor func releasingTheMouseDuringPreparationNeverStartsTheDrag() async {
    let platform = FakeDragPlatform()
    platform.holdBegin = true
    let flow = platform.flow()
    var startCalls = 0
    let request = Task { await flow.request(["a"]) { _ in startCalls += 1; return true } }
    while platform.pendingBegin == nil { await Task.yield() }
    #expect(flow.phase == .preparing)
    flow.mouseReleasedBeforeStart()
    platform.pendingBegin?.resume()
    #expect(await request.value == false)
    #expect(startCalls == 0)
    #expect(platform.ended == [1])
    #expect(flow.phase == .idle)
}

@Test @MainActor func requestsDuringAnotherDragAreIgnoredWithoutPreparingExports() async {
    let platform = FakeDragPlatform()
    platform.holdBegin = true
    let flow = platform.flow()
    let first = Task { await flow.request(["a"]) { _ in true } }
    while platform.pendingBegin == nil { await Task.yield() }
    #expect(await flow.request(["b"]) { _ in true } == false)
    platform.holdBegin = false
    platform.pendingBegin?.resume()
    #expect(await first.value)
    #expect(await flow.request(["c"]) { _ in true } == false)
    #expect(platform.log == ["hold", "begin a"])
    await flow.dragEnded()
    #expect(await flow.request(["c"]) { _ in true })
}

@Test @MainActor func emptyRequestsDoNothing() async {
    let platform = FakeDragPlatform()
    let flow = platform.flow()
    #expect(await flow.request([]) { _ in true } == false)
    #expect(platform.log.isEmpty)
}

@Test @MainActor func preparationFailureReportsReleasesAndNeedsNoEnd() async {
    let platform = FakeDragPlatform()
    platform.beginError = ExportFull()
    let flow = platform.flow()
    var startCalls = 0
    #expect(await flow.request(["a"]) { _ in startCalls += 1; return true } == false)
    #expect(startCalls == 0)
    #expect(platform.ended.isEmpty)
    #expect(platform.reported == 1)
    #expect(platform.log == ["hold", "begin a", "release"])
    #expect(flow.phase == .idle)
}

@Test @MainActor func endFailureIsReportedAndTheFlowCanDragAgain() async {
    let platform = FakeDragPlatform()
    platform.endError = EndFailed()
    let flow = platform.flow()
    #expect(await flow.request(["a"]) { _ in true })
    await flow.dragEnded()
    #expect(platform.reported == 1)
    #expect(flow.phase == .idle)
    platform.endError = nil
    #expect(await flow.request(["a"]) { _ in true })
    await flow.dragEnded()
    #expect(platform.ended == [1, 2])
}

// MARK: - Shelf hold during a drag

@MainActor
private final class Jobs {
    var actions: [(nanoseconds: UInt64, cancelled: () -> Bool, run: @MainActor () -> Void)] = []
    func presentation() -> IslandPresentation {
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        ))
        return IslandPresentation(layout: layout, scheduler: { [unowned self] nanoseconds, action in
            var cancelled = false
            self.actions.append((nanoseconds, { cancelled }, action))
            return AnyCancellable { cancelled = true }
        })
    }
    func fireLast() {
        let job = actions[actions.count - 1]
        if !job.cancelled() { job.run() }
    }
}

@MainActor
private func hoverOpened(_ jobs: Jobs) -> IslandPresentation {
    let model = jobs.presentation()
    model.hoverChanged(true, enabled: true)
    jobs.fireLast()
    #expect(model.isExpanded)
    return model
}

@Test @MainActor func heldHoverShelfIgnoresPointerExitAndClosesAfterRelease() {
    let jobs = Jobs()
    let model = hoverOpened(jobs)
    model.setHeld(true)
    model.hoverChanged(false, enabled: true)
    #expect(model.isExpanded)
    #expect(jobs.actions.count == 1)
    model.setHeld(false)
    #expect(jobs.actions.count == 2)
    jobs.fireLast()
    #expect(!model.isExpanded)
}

@Test @MainActor func releasingWithThePointerInsideKeepsTheShelfOpen() {
    let jobs = Jobs()
    let model = hoverOpened(jobs)
    model.setHeld(true)
    model.hoverChanged(false, enabled: true)
    model.hoverChanged(true, enabled: true)
    model.setHeld(false)
    #expect(model.isExpanded)
    #expect(jobs.actions.count == 1)
}

@Test @MainActor func holdCancelsAPendingPeekCloseAndReleaseReschedulesIt() {
    let jobs = Jobs()
    let model = jobs.presentation()
    model.peek()
    model.setHeld(true)
    #expect(jobs.actions[0].cancelled())
    model.setHeld(false)
    #expect(jobs.actions.count == 2)
    jobs.fireLast()
    #expect(!model.isExpanded)
}

@Test @MainActor func hoverTurnedOffDuringAHoldClosesAHoverShelfOnRelease() {
    let jobs = Jobs()
    let model = hoverOpened(jobs)
    model.setHeld(true)
    model.hoverChanged(true, enabled: false)
    #expect(model.isExpanded)
    model.setHeld(false)
    #expect(!model.isExpanded)
}

@Test @MainActor func manuallyOpenedShelfStaysOpenAfterAHold() {
    let jobs = Jobs()
    let model = jobs.presentation()
    model.toggle()
    model.setHeld(true)
    model.hoverChanged(false, enabled: true)
    model.setHeld(false)
    #expect(model.isExpanded)
    #expect(jobs.actions.isEmpty)
}

@Test @MainActor func suspendingClearsAHoldSoTheNextShelfBehavesNormally() {
    let jobs = Jobs()
    let model = hoverOpened(jobs)
    model.setHeld(true)
    model.suspendHover()
    #expect(!model.isHeld)
    #expect(!model.isExpanded)
}
