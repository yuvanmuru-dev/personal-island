import Combine
import CoreGraphics
import Foundation
import Testing
@testable import PersonalIslandPresentation

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Explicitly delivers callbacks, including stale canceled callbacks, to model
/// cancellation racing delivery. There are no sleeps, Tasks, or polling loops.
@MainActor
private final class ManualScheduler {
    struct Job {
        let nanoseconds: UInt64
        let action: @MainActor () -> Void
        let flag: CancellationFlag
    }
    private(set) var jobs: [Job] = []

    func schedule(_ nanoseconds: UInt64, action: @escaping @MainActor () -> Void) -> AnyCancellable {
        let flag = CancellationFlag()
        jobs.append(Job(nanoseconds: nanoseconds, action: action, flag: flag))
        return AnyCancellable { flag.cancel() }
    }

    func fire(_ index: Int, evenIfCancelled: Bool = false) {
        let job = jobs[index]
        if evenIfCancelled || !job.flag.isCancelled { job.action() }
    }

    func presentation() -> IslandPresentation {
        IslandPresentation(layout: testLayout(), scheduler: { [self] nanoseconds, action in
            schedule(nanoseconds, action: action)
        })
    }
}

private func testLayout() -> IslandGeometry.Layout {
    IslandGeometry.layout(for: IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    ))
}

@Test @MainActor func clickTogglesImmediatelyAndEscapeCollapseIsIdempotent() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes: [Bool] = []
    model.onExpansionChange = { [weak model] in changes.append(model?.isExpanded ?? false) }
    #expect(!model.isExpanded)
    model.collapse()
    #expect(changes.isEmpty)
    model.toggle()
    #expect(model.isExpanded)
    model.collapse()
    model.collapse()
    #expect(!model.isExpanded)
    #expect(changes == [true, false])
    #expect(scheduler.jobs.isEmpty)
}

@Test @MainActor func disabledHoverNeverSchedulesOrExpands() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: false)
    model.hoverChanged(false, enabled: false)
    #expect(scheduler.jobs.isEmpty)
    #expect(!model.isExpanded)
}

@Test @MainActor func hoverWaitsForTheOpenDelayAndEmitsOneChange() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes = 0
    model.onExpansionChange = { changes += 1 }
    model.hoverChanged(true, enabled: true)
    #expect(!model.isExpanded)
    #expect(changes == 0)
    #expect(scheduler.jobs.map(\.nanoseconds) == [80_000_000])
    scheduler.fire(0)
    #expect(model.isExpanded)
    #expect(changes == 1)
    scheduler.fire(0, evenIfCancelled: true)
    #expect(changes == 1)
}

@Test @MainActor func leavingBeforeOpenCancelsEvenALateDeliveredCallback() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: true)
    model.hoverChanged(false, enabled: true)
    #expect(scheduler.jobs[0].flag.isCancelled)
    scheduler.fire(0, evenIfCancelled: true)
    #expect(!model.isExpanded)
}

@Test @MainActor func reenteringCannotBeOpenedByThePreviousHoverAttempt() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: true)
    model.hoverChanged(false, enabled: true)
    model.hoverChanged(true, enabled: true)
    scheduler.fire(0, evenIfCancelled: true)
    #expect(!model.isExpanded)
    scheduler.fire(1)
    #expect(model.isExpanded)
}

@Test @MainActor func hoverOpenedShelfClosesOnlyAfterItsExitDelay() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: true)
    scheduler.fire(0)
    model.hoverChanged(false, enabled: true)
    #expect(model.isExpanded)
    #expect(scheduler.jobs.map(\.nanoseconds) == [80_000_000, 120_000_000])
    scheduler.fire(1)
    #expect(!model.isExpanded)
}

@Test @MainActor func returningToTheShelfCancelsPendingHoverClose() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: true)
    scheduler.fire(0)
    model.hoverChanged(false, enabled: true)
    model.hoverChanged(true, enabled: true)
    scheduler.fire(1, evenIfCancelled: true)
    #expect(model.isExpanded)
    model.hoverChanged(false, enabled: true)
    scheduler.fire(2)
    #expect(!model.isExpanded)
}

@Test @MainActor func manuallyOpenedShelfDoesNotAutoCloseOnPointerExit() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.toggle()
    model.hoverChanged(true, enabled: true)
    model.hoverChanged(false, enabled: true)
    #expect(model.isExpanded)
    #expect(scheduler.jobs.isEmpty)
}

@Test @MainActor func manualClickSupersedesAPendingHoverOpen() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes = 0
    model.onExpansionChange = { changes += 1 }
    model.hoverChanged(true, enabled: true)
    model.toggle()
    scheduler.fire(0, evenIfCancelled: true)
    model.hoverChanged(false, enabled: true)
    #expect(model.isExpanded)
    #expect(changes == 1)
    #expect(scheduler.jobs.count == 1)
}

@Test @MainActor func staleHoverCloseCannotCloseANewerManualOpening() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: true)
    scheduler.fire(0)
    model.hoverChanged(false, enabled: true)
    model.toggle()
    model.toggle()
    scheduler.fire(1, evenIfCancelled: true)
    model.hoverChanged(false, enabled: true)
    #expect(model.isExpanded)
    #expect(scheduler.jobs.count == 2)
}

@Test @MainActor func disablingHoverCancelsAnAlreadyScheduledOpen() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: true)
    model.hoverChanged(true, enabled: false)
    scheduler.fire(0, evenIfCancelled: true)
    #expect(!model.isExpanded)
}

@Test @MainActor func collapsingBeforeTheHoverDelayKeepsTheShelfClosed() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes = 0
    model.onExpansionChange = { changes += 1 }
    model.hoverChanged(true, enabled: true)
    model.collapse()
    scheduler.fire(0, evenIfCancelled: true)
    #expect(!model.isExpanded)
    #expect(changes == 0)
}

@Test @MainActor func cancelPendingInteractionDoesNotInventAStateChange() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: true)
    scheduler.fire(0)
    var changes = 0
    model.onExpansionChange = { changes += 1 }
    model.hoverChanged(false, enabled: true)
    model.cancelPendingInteraction()
    scheduler.fire(1, evenIfCancelled: true)
    #expect(model.isExpanded)
    #expect(changes == 0)
}

@Test @MainActor func changingDisplayLayoutPreservesExpansionWithoutDuplicateCallbacks() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.toggle()
    var changes = 0
    model.onExpansionChange = { changes += 1 }
    let replacement = IslandGeometry.layout(for: IslandGeometry.Display(
        frame: CGRect(x: -1512, y: 982, width: 1512, height: 982),
        safeAreaTop: 37, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    ))
    model.update(layout: replacement)
    #expect(model.isExpanded)
    #expect(model.layout == replacement)
    #expect(changes == 0)
}

@Test @MainActor func pendingHoverCallbackDoesNotKeepADisconnectedPresenterAlive() {
    let scheduler = ManualScheduler()
    var model: IslandPresentation? = scheduler.presentation()
    weak var weakModel = model
    model?.hoverChanged(true, enabled: true)
    model = nil
    #expect(weakModel == nil)
    #expect(scheduler.jobs[0].flag.isCancelled)
    scheduler.fire(0, evenIfCancelled: true)
    #expect(weakModel == nil)
}

@Test @MainActor func duplicateEnterEventsPreserveTheOriginalOpenJobAndDeadline() throws {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes = 0
    model.onExpansionChange = { changes += 1 }
    model.hoverChanged(true, enabled: true)
    model.hoverChanged(true, enabled: true)
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 1)
    #expect(scheduler.jobs[0].nanoseconds == 80_000_000)
    #expect(!scheduler.jobs[0].flag.isCancelled)
    #expect(!model.isExpanded)
    scheduler.fire(0)
    #expect(model.isExpanded)
    #expect(changes == 1)
}

@Test @MainActor func duplicateExitEventsPreserveTheOriginalCloseJobAndDeadline() throws {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes: [Bool] = []
    model.onExpansionChange = { [weak model] in changes.append(model?.isExpanded ?? false) }
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 1)
    scheduler.fire(0)
    model.hoverChanged(false, enabled: true)
    model.hoverChanged(false, enabled: true)
    model.hoverChanged(false, enabled: true)
    try #require(scheduler.jobs.count == 2)
    #expect(scheduler.jobs[1].nanoseconds == 120_000_000)
    #expect(!scheduler.jobs[1].flag.isCancelled)
    #expect(model.isExpanded)
    scheduler.fire(1)
    #expect(!model.isExpanded)
    #expect(changes == [true, false])
}

@Test @MainActor func disablingHoverDuringPendingCloseCollapsesOnceAndCancelsTheJob() throws {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes: [Bool] = []
    model.onExpansionChange = { [weak model] in changes.append(model?.isExpanded ?? false) }
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 1)
    scheduler.fire(0)
    model.hoverChanged(false, enabled: true)
    try #require(scheduler.jobs.count == 2)
    model.hoverChanged(false, enabled: false)
    #expect(!model.isExpanded)
    #expect(scheduler.jobs[1].flag.isCancelled)
    model.hoverChanged(false, enabled: false)
    scheduler.fire(1, evenIfCancelled: true)
    #expect(!model.isExpanded)
    #expect(changes == [true, false])
    #expect(scheduler.jobs.count == 2)
}

@Test @MainActor func disablingHoverPreservesAManuallyOpenedShelf() {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes: [Bool] = []
    model.onExpansionChange = { [weak model] in changes.append(model?.isExpanded ?? false) }
    model.toggle()
    model.hoverChanged(true, enabled: true)
    model.hoverChanged(true, enabled: false)
    model.hoverChanged(false, enabled: false)
    #expect(model.isExpanded)
    #expect(changes == [true])
    #expect(scheduler.jobs.isEmpty)
}

@Test @MainActor func enablingAndReenablingHoverWhileStationarySchedulesFreshOpen() throws {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: false)
    #expect(scheduler.jobs.isEmpty)
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 1)
    model.hoverChanged(true, enabled: false)
    #expect(scheduler.jobs[0].flag.isCancelled)
    #expect(!model.isExpanded)
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 2)
    scheduler.fire(0, evenIfCancelled: true)
    #expect(!model.isExpanded)
    scheduler.fire(1)
    #expect(model.isExpanded)
    model.hoverChanged(true, enabled: true)
    #expect(scheduler.jobs.count == 2)
}

@Test @MainActor func disablingAnExpandedHoverShelfAllowsReenableWithoutPointerMovement() throws {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes: [Bool] = []
    model.onExpansionChange = { [weak model] in changes.append(model?.isExpanded ?? false) }
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 1)
    scheduler.fire(0)
    model.hoverChanged(true, enabled: false)
    #expect(!model.isExpanded)
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 2)
    scheduler.fire(0, evenIfCancelled: true)
    #expect(!model.isExpanded)
    scheduler.fire(1)
    #expect(model.isExpanded)
    #expect(changes == [true, false, true])
}

@Test @MainActor func manualCollapseInsideIgnoresDuplicateEnterUntilExitAndReentry() throws {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 1)
    scheduler.fire(0)
    model.collapse()
    model.hoverChanged(true, enabled: true)
    model.hoverChanged(true, enabled: true)
    #expect(!model.isExpanded)
    #expect(scheduler.jobs.count == 1)
    model.hoverChanged(false, enabled: true)
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 2)
    scheduler.fire(1)
    #expect(model.isExpanded)
}

@Test @MainActor func suspendingPendingHoverOpenCancelsItAndAllowsANewInsideEvent() throws {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes: [Bool] = []
    model.onExpansionChange = { [weak model] in changes.append(model?.isExpanded ?? false) }
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 1)
    model.suspendHover()
    #expect(scheduler.jobs[0].flag.isCancelled)
    scheduler.fire(0, evenIfCancelled: true)
    #expect(!model.isExpanded)
    #expect(changes.isEmpty)
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 2)
    scheduler.fire(0, evenIfCancelled: true)
    #expect(!model.isExpanded)
    scheduler.fire(1)
    #expect(model.isExpanded)
    #expect(changes == [true])
}

@Test @MainActor func suspendingExpandedHoverShelfRejectsLateCloseAfterResume() throws {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes: [Bool] = []
    model.onExpansionChange = { [weak model] in changes.append(model?.isExpanded ?? false) }
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 1)
    scheduler.fire(0)
    model.hoverChanged(false, enabled: true)
    try #require(scheduler.jobs.count == 2)
    model.suspendHover()
    #expect(!model.isExpanded)
    #expect(scheduler.jobs[1].flag.isCancelled)
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 3)
    scheduler.fire(1, evenIfCancelled: true)
    #expect(!model.isExpanded)
    scheduler.fire(2)
    #expect(model.isExpanded)
    scheduler.fire(1, evenIfCancelled: true)
    #expect(model.isExpanded)
    #expect(changes == [true, false, true])
}

@Test @MainActor func suspendingAManualOpeningCollapsesOnceAndResetsHoverTracking() throws {
    let scheduler = ManualScheduler()
    let model = scheduler.presentation()
    var changes: [Bool] = []
    model.onExpansionChange = { [weak model] in changes.append(model?.isExpanded ?? false) }
    model.toggle()
    model.hoverChanged(true, enabled: true)
    model.suspendHover()
    model.suspendHover()
    #expect(!model.isExpanded)
    #expect(changes == [true, false])
    #expect(scheduler.jobs.isEmpty)
    model.hoverChanged(true, enabled: true)
    try #require(scheduler.jobs.count == 1)
    scheduler.fire(0)
    #expect(model.isExpanded)
    #expect(changes == [true, false, true])
}

/// Integration smoke test for the real Task.sleep scheduler. Unlike the manual
/// race tests, this waits for actual production callbacks through an AsyncStream
/// continuation. It asserts state delivery, not elapsed time or timer precision.
/// Stream iteration responds to cancellation so the test time limit can stop it.
@Test(.timeLimit(.minutes(1))) @MainActor
func defaultSchedulerDeliversHoverOpenAndCloseWithoutGUI() async {
    let model = IslandPresentation(layout: testLayout())
    let (events, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(2))
    model.onExpansionChange = { [weak model] in
        guard let model else { return }
        continuation.yield(model.isExpanded)
    }
    defer {
        model.onExpansionChange = nil
        model.cancelPendingInteraction()
        continuation.finish()
    }

    var iterator = events.makeAsyncIterator()
    model.hoverChanged(true, enabled: true)
    let opened = await iterator.next()
    #expect(opened == true)
    guard opened == true else { return }
    #expect(model.isExpanded)

    model.hoverChanged(false, enabled: true)
    let closed = await iterator.next()
    #expect(closed == false)
    #expect(!model.isExpanded)
}
