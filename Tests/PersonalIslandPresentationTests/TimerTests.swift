import Combine
import CoreGraphics
import Foundation
import Testing
@testable import PersonalIslandPresentation

private final class Cancelled: @unchecked Sendable {
    var value = false
}

/// A fake clock and scheduler: tests move time by hand and fire wake-ups
/// explicitly, including stale ones that were already cancelled.
@MainActor
private final class FakeClock {
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    var wakes: [(date: Date, action: @MainActor () -> Void, cancelled: Cancelled)] = []

    func controller() -> TimerController {
        TimerController(environment: .init(
            now: { [unowned self] in self.now },
            schedule: { [unowned self] date, action in
                let flag = Cancelled()
                self.wakes.append((date, action, flag))
                return AnyCancellable { flag.value = true }
            }
        ))
    }

    var pending: [Date] { wakes.filter { !$0.cancelled.value }.map(\.date) }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    func fireLatest(evenIfCancelled: Bool = false) {
        guard let wake = wakes.last else { return }
        if evenIfCancelled || !wake.cancelled.value { wake.action() }
    }
}

@Test func clockAndLengthTextReadNaturally() {
    #expect(IslandTimers.clockText(300) == "5:00")
    #expect(IslandTimers.clockText(299.2) == "5:00")      // rounds up: never 0:00 while running
    #expect(IslandTimers.clockText(0.4) == "0:01")
    #expect(IslandTimers.clockText(0) == "0:00")
    #expect(IslandTimers.clockText(3_723) == "1:02:03")
    #expect(IslandTimers.clockText(-.infinity) == "0:00")
    #expect(IslandTimers.lengthText(300) == "5 min")
    #expect(IslandTimers.lengthText(3_600) == "1 hr")
    #expect(IslandTimers.lengthText(5_400) == "1 hr 30 min")
}

@Test func pausingKeepsTheRemainingTimeAndResumingContinuesFromIt() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var timer = IslandTimer(duration: 600, startedAt: start)
    #expect(timer.remaining(at: start.addingTimeInterval(100)) == 500)
    timer.pause(at: start.addingTimeInterval(100))
    #expect(timer.isPaused)
    #expect(timer.remaining(at: start.addingTimeInterval(400)) == 500)
    timer.resume(at: start.addingTimeInterval(400))
    #expect(timer.remaining(at: start.addingTimeInterval(450)) == 450)
    #expect(timer.progress(at: start.addingTimeInterval(450)) == 0.25)
    #expect(timer.remaining(at: start.addingTimeInterval(10_000)) == 0)
    #expect(timer.progress(at: start.addingTimeInterval(10_000)) == 1)
}

@Test @MainActor func oneWakeUpAtTheEarliestEndFinishesOnlyWhatIsDue() {
    let clock = FakeClock()
    let controller = clock.controller()
    var finished: [TimeInterval] = []
    controller.onFinish = { finished.append($0.duration) }
    controller.start(seconds: 300)
    controller.start(seconds: 60)
    #expect(clock.pending == [clock.now.addingTimeInterval(60)])
    clock.advance(60)
    clock.fireLatest()
    #expect(finished == [60])
    #expect(controller.timers.map(\.duration) == [300])
    #expect(clock.pending == [clock.now.addingTimeInterval(240)])
}

@Test @MainActor func pausedTimersNeverFinishAndCancelRemovesTheWakeUp() {
    let clock = FakeClock()
    let controller = clock.controller()
    var finished = 0
    controller.onFinish = { _ in finished += 1 }
    controller.start(seconds: 60)
    let id = controller.timers[0].id
    controller.pause(id)
    #expect(clock.pending.isEmpty)
    clock.advance(3_600)
    controller.reconcile()
    #expect(finished == 0 && controller.timers[0].remaining(at: clock.now) == 60)
    controller.resume(id)
    #expect(clock.pending == [clock.now.addingTimeInterval(60)])
    controller.cancel(id)
    #expect(controller.timers.isEmpty && clock.pending.isEmpty)
    clock.fireLatest(evenIfCancelled: true)
    #expect(finished == 0)
}

@Test @MainActor func aStaleWakeUpIsIgnoredAndWakingFromSleepFinishesOverdueTimers() {
    let clock = FakeClock()
    let controller = clock.controller()
    var finished: [TimeInterval] = []
    controller.onFinish = { finished.append($0.duration) }
    controller.start(seconds: 120)
    controller.start(seconds: 30)            // replaces the first wake-up
    clock.advance(10)
    clock.wakes[0].action()                  // stale: delivered after cancellation
    #expect(finished.isEmpty && controller.timers.count == 2)
    clock.advance(500)                       // asleep past both ends
    controller.reconcile()
    #expect(finished.sorted() == [30, 120])
    #expect(controller.timers.isEmpty && clock.pending.isEmpty)
}

@Test @MainActor func atMostFiveTimersAndInvalidLengthsAreRefused() {
    let clock = FakeClock()
    let controller = clock.controller()
    for _ in 0..<IslandTimers.maximumCount { #expect(controller.start(seconds: 60)) }
    #expect(!controller.canAdd)
    #expect(!controller.start(seconds: 60))
    controller.stop()
    for seconds in [0, 0.5, -60, .infinity, .nan, 25 * 3_600] as [TimeInterval] {
        #expect(!controller.start(seconds: seconds))
    }
    #expect(controller.timers.isEmpty)
}

@Test @MainActor func stoppingCancelsEveryTimerAndItsWakeUp() {
    let clock = FakeClock()
    let controller = clock.controller()
    var changes = 0
    var finished = 0
    controller.onChange = { changes += 1 }
    controller.onFinish = { _ in finished += 1 }
    controller.start(seconds: 60)
    controller.start(seconds: 90)
    controller.stop()
    controller.stop()
    #expect(controller.timers.isEmpty && clock.pending.isEmpty)
    clock.advance(100)
    clock.fireLatest(evenIfCancelled: true)
    #expect(finished == 0)
    #expect(changes == 3)
}

@Test @MainActor func theNotchShowsTheRunningTimerFinishingFirst() {
    let clock = FakeClock()
    let controller = clock.controller()
    #expect(controller.featured == nil)
    controller.start(seconds: 600)
    controller.start(seconds: 120)
    #expect(controller.featured?.duration == 120)
    controller.pause(controller.timers[1].id)
    #expect(controller.featured?.duration == 600)
    controller.pause(controller.timers[0].id)
    #expect(controller.featured?.duration == 120)   // all paused: the most recent
}

// MARK: - Live countdown in the presentation

@MainActor private func liveModel() -> (IslandPresentation, () -> Int) {
    let model = IslandPresentation(layout: IslandGeometry.layout(for: IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )), scheduler: { _, _ in AnyCancellable {} })
    var resizes = 0
    model.onActivityChange = { resizes += 1 }
    return (model, { resizes })
}

@Test @MainActor func aRunningTimerKeepsTheIslandWidenedWithoutExtraResizes() {
    let (model, resizes) = liveModel()
    model.setLive(true)
    model.setLive(true)
    #expect(model.isWidened && resizes() == 1)
    model.showActivity(.timerDone(duration: 60))    // already wide: no resize
    #expect(resizes() == 1)
    model.endActivity()
    #expect(model.isWidened && resizes() == 1)      // still live
    model.toggle()
    #expect(!model.isWidened)
    model.collapse()
    #expect(model.isWidened)
    model.setLive(false)
    #expect(!model.isWidened && resizes() == 2)
}

@Test func timerNoticesStayLongerThanBatteryNotices() {
    #expect(IslandActivity.timerDone(duration: 60).displayDuration > IslandActivity.battery(.pluggedIn(percent: 50)).displayDuration)
}

// MARK: - Stopwatch

@Test func stopwatchTextShowsTenthsWithoutRunningAhead() {
    #expect(IslandTimers.stopwatchText(0) == "0:00.0")
    #expect(IslandTimers.stopwatchText(62.39) == "1:02.3")
    #expect(IslandTimers.stopwatchText(3_723.45) == "1:02:03.4")
    #expect(IslandTimers.stopwatchText(.nan) == "0:00.0")
    #expect(IslandTimers.stopwatchShortText(62.99) == "1:02")
    #expect(IslandTimers.stopwatchShortText(3_723) == "1:02:03")
}

@Test func stopwatchCountsOnlyWhileRunningAndLapsAreSplits() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var watch = Stopwatch()
    #expect(!watch.isActive)
    watch.start(at: start)
    watch.start(at: start.addingTimeInterval(5))           // repeated start keeps the first
    watch.lap(at: start.addingTimeInterval(10))
    watch.pause(at: start.addingTimeInterval(15))
    #expect(watch.elapsed(at: start.addingTimeInterval(100)) == 15)
    #expect(watch.isActive && !watch.isRunning)
    watch.lap(at: start.addingTimeInterval(100))           // no laps while paused
    watch.start(at: start.addingTimeInterval(100))
    watch.lap(at: start.addingTimeInterval(105))
    watch.lap(at: start.addingTimeInterval(105))           // a zero-length lap is ignored
    #expect(watch.lapMarks == [10, 20])
    #expect(watch.lapLengths == [10, 10])
    watch.reset()
    #expect(watch == Stopwatch())
}

@Test func lapsAreBounded() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var watch = Stopwatch()
    watch.start(at: start)
    for second in 1...(Stopwatch.maximumLaps + 5) { watch.lap(at: start.addingTimeInterval(Double(second))) }
    #expect(watch.lapMarks.count == Stopwatch.maximumLaps)
}

@Test @MainActor func stopwatchChangesAreReportedAndStoppingResetsIt() {
    let clock = FakeClock()
    let controller = clock.controller()
    var changes = 0
    controller.onChange = { changes += 1 }
    controller.startStopwatch()
    controller.startStopwatch()
    clock.advance(12)
    controller.lapStopwatch()
    controller.pauseStopwatch()
    #expect(changes == 3)
    #expect(controller.stopwatch.elapsed(at: clock.now.addingTimeInterval(50)) == 12)
    #expect(clock.pending.isEmpty)                         // no wake-ups for a stopwatch
    controller.stop()
    #expect(controller.stopwatch == Stopwatch() && changes == 4)
    controller.stop()
    #expect(changes == 4)
}
