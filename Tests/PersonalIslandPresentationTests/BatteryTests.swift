import Combine
import CoreGraphics
import Foundation
import IOKit.ps
import Testing
@testable import PersonalIslandPresentation

// MARK: - Reading power-source descriptions

private func description(current: Int = 50, max: Int = 100, state: String = kIOPSBatteryPowerValue,
                         charging: Bool = false, extra: [String: Any] = [:]) -> [String: Any] {
    var value: [String: Any] = [
        kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
        kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: max,
        kIOPSPowerSourceStateKey: state, kIOPSIsChargingKey: charging,
    ]
    value.merge(extra) { $1 }
    return value
}

@Test func internalBatteryDescriptionIsRead() throws {
    let snapshot = try #require(PowerSnapshot(description: description(
        current: 4_150, max: 5_000, state: kIOPSACPowerValue, charging: true,
        extra: [kIOPSTimeToFullChargeKey: 42, kIOPSTimeToEmptyKey: -1]
    )))
    #expect(snapshot.percent == 83)
    #expect(snapshot.isPluggedIn && snapshot.isCharging && !snapshot.isCharged)
    #expect(snapshot.minutesToFull == 42)
    #expect(snapshot.minutesToEmpty == nil)   // -1: still estimating
}

@Test func otherSourcesAndImplausibleReadingsAreRejected() {
    #expect(PowerSnapshot(description: description(extra: [kIOPSTypeKey: kIOPSUPSType])) == nil)
    #expect(PowerSnapshot(description: description(extra: [kIOPSIsPresentKey: false])) == nil)
    #expect(PowerSnapshot(description: description(max: 0)) == nil)
    #expect(PowerSnapshot(description: description(current: -5)) == nil)
    #expect(PowerSnapshot(description: description(extra: [kIOPSCurrentCapacityKey: "50"])) == nil)
    #expect(PowerSnapshot(description: description(current: 130))?.percent == 100)
}

// MARK: - Deciding notices

private func reading(_ percent: Int, plugged: Bool = false, charged: Bool = false) -> PowerSnapshot {
    PowerSnapshot(percent: percent, isPluggedIn: plugged, isCharging: plugged && !charged, isCharged: charged)
}

private func event(_ old: PowerSnapshot, _ new: PowerSnapshot, low: Bool = true, full: Bool = true) -> BatteryActivity? {
    BatteryEvents.activity(from: old, to: new, lowAlerts: low, chargedAlert: full)
}

@Test func pluggingInAndUnpluggingAreAnnounced() {
    #expect(event(reading(40), reading(40, plugged: true)) == .pluggedIn(percent: 40))
    #expect(event(reading(40, plugged: true), reading(40)) == .unplugged(percent: 40))
    #expect(event(reading(40), reading(39)) == nil)
}

@Test func lowAlertsFireOnceWhenCrossingEachThreshold() {
    #expect(event(reading(21), reading(20)) == .low(percent: 20))
    #expect(event(reading(20), reading(19)) == nil)
    #expect(event(reading(11), reading(10)) == .low(percent: 10))
    #expect(event(reading(25), reading(9)) == .low(percent: 9))       // skipped readings after sleep
    #expect(event(reading(21), reading(20), low: false) == nil)
    #expect(event(reading(21, plugged: true), reading(20, plugged: true)) == nil)
}

@Test func chargedIsAnnouncedOnceIncludingOptimizedChargingStops() {
    #expect(event(reading(99, plugged: true), reading(100, plugged: true)) == .charged(percent: 100))
    #expect(event(reading(80, plugged: true), reading(80, plugged: true, charged: true)) == .charged(percent: 80))
    #expect(event(reading(100, plugged: true), reading(100, plugged: true, charged: true)) == nil)
    #expect(event(reading(99, plugged: true), reading(100, plugged: true), full: false) == nil)
    #expect(event(reading(99), reading(100)) == nil)
}

// MARK: - Controller lifecycle

@MainActor
private final class FakePower {
    var current: PowerSnapshot? = reading(50)
    var handler: (@MainActor () -> Void)?
    var observing = 0
    var stopped = 0

    func controller() -> BatteryController {
        BatteryController(environment: .init(
            read: { [unowned self] in self.current },
            observe: { [unowned self] handler in
                self.handler = handler
                self.observing += 1
                return NSObject()
            },
            stopObserving: { [unowned self] _ in
                self.handler = nil
                self.stopped += 1
            }
        ))
    }

    func change(to snapshot: PowerSnapshot?) {
        current = snapshot
        handler?()
    }
}

@Test @MainActor func startingIsQuietAndChangesAreAnnounced() {
    let power = FakePower()
    power.current = reading(15)
    let controller = power.controller()
    var notices: [BatteryActivity] = []
    controller.onActivity = { notices.append($0) }
    controller.start()
    #expect(controller.status == .ready && controller.snapshot == reading(15))
    #expect(notices.isEmpty)   // already low at launch: no alert
    power.change(to: reading(15, plugged: true))
    power.change(to: reading(15, plugged: true))   // repeated notification
    #expect(notices == [.pluggedIn(percent: 15)])
}

@Test @MainActor func stoppingEndsObservationAndForgetsTheReading() {
    let power = FakePower()
    let controller = power.controller()
    var changes = 0
    var notices = 0
    controller.onChange = { changes += 1 }
    controller.onActivity = { _ in notices += 1 }
    controller.start()
    controller.start()
    #expect(power.observing == 1)
    controller.stop()
    controller.stop()
    #expect(power.stopped == 1 && power.handler == nil)
    #expect(controller.status == .off && controller.snapshot == nil)
    controller.refresh()
    #expect(controller.snapshot == nil && notices == 0)
    #expect(changes == 2)
}

@Test @MainActor func restartingDoesNotAnnounceWhatChangedWhileOff() {
    let power = FakePower()
    let controller = power.controller()
    var notices: [BatteryActivity] = []
    controller.onActivity = { notices.append($0) }
    controller.start()
    controller.stop()
    power.current = reading(50, plugged: true)
    controller.start()
    #expect(notices.isEmpty)
    #expect(controller.snapshot?.isPluggedIn == true)
}

@Test @MainActor func turnedOffAlertsAreRespectedAndAMissingBatteryIsReported() {
    let power = FakePower()
    power.current = reading(21)
    let controller = power.controller()
    controller.lowAlertsEnabled = false
    var notices: [BatteryActivity] = []
    controller.onActivity = { notices.append($0) }
    controller.start()
    power.change(to: reading(20))
    #expect(notices.isEmpty)
    power.change(to: nil)
    #expect(controller.status == .noBattery && controller.snapshot == nil)
    power.change(to: reading(20, plugged: true))
    #expect(notices.isEmpty)   // no previous reading to compare with
}

// MARK: - Presentation and geometry

private final class Flag: @unchecked Sendable {
    var cancelled = false
}

@MainActor
private final class Jobs {
    var actions: [(action: @MainActor () -> Void, flag: Flag)] = []
    func presentation(_ layout: IslandGeometry.Layout = notchLayout()) -> IslandPresentation {
        IslandPresentation(layout: layout, scheduler: { [unowned self] _, action in
            let flag = Flag()
            self.actions.append((action, flag))
            return AnyCancellable { flag.cancelled = true }
        })
    }
    func fire(_ index: Int, evenIfCancelled: Bool = false) {
        if evenIfCancelled || !actions[index].flag.cancelled { actions[index].action() }
    }
}

private func notchLayout() -> IslandGeometry.Layout {
    IslandGeometry.layout(for: IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 37,
        auxiliaryTopLeft: CGRect(x: 0, y: 945, width: 660, height: 37),
        auxiliaryTopRight: CGRect(x: 852, y: 945, width: 660, height: 37)
    ))
}

@Test func activityWidensTheNotchEquallyOnBothSidesWithoutGrowingDown() {
    let layout = notchLayout()
    let compact = layout.panelFrame(expanded: false)
    let activity = layout.panelFrame(expanded: false, activity: true)
    #expect(activity.height == compact.height && activity.maxY == compact.maxY)
    #expect(activity.midX == compact.midX)
    #expect(layout.activityWingWidth == IslandGeometry.activityWingWidth)
    #expect(compact.minX - activity.minX == IslandGeometry.activityWingWidth)
    #expect(layout.panelFrame(expanded: true, activity: true) == layout.panelFrame(expanded: true))
}

@Test func pillActivityStaysInTheMenuBarAndFitsNarrowDisplays() {
    let pill = IslandGeometry.layout(for: IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    ))
    #expect(pill.activitySize.width == IslandGeometry.pillActivityWidth)
    #expect(pill.activitySize.height == pill.compactSize.height)
    let narrow = IslandGeometry.layout(for: IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 120, height: 400), safeAreaTop: 0,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    ))
    #expect(narrow.panelFrame(expanded: false, activity: true).width <= 120)
}

@Test @MainActor func activityEndsByItselfAndANewerOneRestartsTheTimer() {
    let jobs = Jobs()
    let model = jobs.presentation()
    var resizes = 0
    model.onActivityChange = { resizes += 1 }
    model.showActivity(.pluggedIn(percent: 40))
    model.showActivity(.unplugged(percent: 40))
    #expect(model.activity == .unplugged(percent: 40))
    #expect(resizes == 1)
    jobs.fire(0, evenIfCancelled: true)   // stale timer must not end the newer notice
    #expect(model.activity == .unplugged(percent: 40))
    jobs.fire(1)
    #expect(model.activity == nil)
    #expect(resizes == 2)
}

@Test @MainActor func openingTheIslandEndsANoticeAndNoticesWaitWhileOpen() {
    let jobs = Jobs()
    let model = jobs.presentation()
    model.showActivity(.low(percent: 20))
    model.toggle()
    #expect(model.isExpanded && model.activity == nil)
    model.showActivity(.charged(percent: 100))
    #expect(model.activity == nil)
    model.collapse()
    model.showActivity(.charged(percent: 100))
    model.suspendHover()   // hidden or disconnected display
    #expect(model.activity == nil)
}
