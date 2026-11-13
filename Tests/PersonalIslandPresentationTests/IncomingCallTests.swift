import Combine
import CoreGraphics
import Foundation
import Testing
@testable import PersonalIslandPresentation

@Test func onlyAPlainFirstNameIsTakenFromTheBanner() {
    #expect(IncomingCalls.callerFirstName(fromDescription: "Alex Example, FaceTime Audio") == "Alex")
    #expect(IncomingCalls.callerFirstName(fromDescription: "Sam Sample\nfrom iPhone") == "Sam")
    #expect(IncomingCalls.callerFirstName(fromDescription: "  Jo\u{0007}  , Video") == "Jo")
    #expect(IncomingCalls.callerFirstName(fromDescription: "+1 (555) 010-0000, iPhone") == nil)   // a number, not a name
    #expect(IncomingCalls.callerFirstName(fromDescription: "FaceTime Audio") == nil)
    #expect(IncomingCalls.callerFirstName(fromDescription: "Incoming call") == nil)
    #expect(IncomingCalls.callerFirstName(fromDescription: "") == nil)
    #expect(IncomingCalls.callerFirstName(fromDescription: nil) == nil)
    #expect(IncomingCalls.callerFirstName(fromDescription: String(repeating: "x", count: 50))?.count == 20)
}

private final class Flag: @unchecked Sendable { var cancelled = false }

@MainActor
private final class FakeNotificationCenter {
    var trusted = true
    var trustRequests = 0
    var banner: String?
    var handler: (@MainActor () -> Void)?
    var observing = 0
    var stoppedObserving = 0
    var timers: [(delay: TimeInterval, action: @MainActor () -> Void, flag: Flag)] = []

    func controller() -> IncomingCallController {
        IncomingCallController(environment: .init(
            isTrusted: { [unowned self] in self.trusted },
            requestTrust: { [unowned self] in self.trustRequests += 1 },
            findCallBanner: { [unowned self] in self.banner },
            observe: { [unowned self] handler in
                self.handler = handler
                self.observing += 1
                return NSObject()
            },
            stopObserving: { [unowned self] _ in
                self.handler = nil
                self.stoppedObserving += 1
            },
            schedule: { [unowned self] delay, action in
                let flag = Flag()
                self.timers.append((delay, action, flag))
                return AnyCancellable { flag.cancelled = true }
            }
        ))
    }

    var pending: [TimeInterval] { timers.filter { !$0.flag.cancelled }.map(\.delay) }

    func fireTimer() {
        guard let timer = timers.last(where: { !$0.flag.cancelled }) else { return }
        timer.action()
    }
}

@Test @MainActor func aRingingBannerShowsAndEndsWithTheCall() {
    let center = FakeNotificationCenter()
    let controller = center.controller()
    var changes: [IncomingCallStatus] = []
    controller.onChange = { changes.append(controller.status) }
    controller.start()
    #expect(controller.status == .watching && center.observing == 1)
    #expect(center.pending == [IncomingCalls.idleCheckInterval])
    center.banner = "Alex Example, FaceTime Audio"
    center.handler?()
    center.handler?()                                          // repeated window changes
    #expect(controller.status == .ringing(IncomingCall(callerFirstName: "Alex")))
    #expect(center.pending == [IncomingCalls.ringingCheckInterval])   // checks often while ringing
    center.banner = nil                                        // answered, declined or missed
    center.fireTimer()
    #expect(controller.status == .watching)
    #expect(changes == [.watching, .ringing(IncomingCall(callerFirstName: "Alex")), .watching])
}

@Test @MainActor func aBannerWithoutADescriptionStillShowsACall() {
    let center = FakeNotificationCenter()
    center.banner = ""
    let controller = center.controller()
    controller.start()
    #expect(controller.status == .ringing(IncomingCall(callerFirstName: nil)))
}

@Test @MainActor func withoutAccessibilityItAsksOnceAndPicksUpPermissionLater() {
    let center = FakeNotificationCenter()
    center.trusted = false
    let controller = center.controller()
    controller.start()
    #expect(controller.status == .needsAccess && center.trustRequests == 1 && center.observing == 0)
    center.fireTimer()
    #expect(center.trustRequests == 1)                         // never nags again
    center.trusted = true                                      // allowed in System Settings
    center.fireTimer()
    #expect(controller.status == .watching && center.observing == 1)
    center.trusted = false                                     // revoked while running
    center.handler?()
    #expect(controller.status == .needsAccess && center.stoppedObserving == 1)
}

@Test @MainActor func stoppingEndsWatchingAndIgnoresLateEvents() {
    let center = FakeNotificationCenter()
    center.banner = "Alex"
    let controller = center.controller()
    controller.start()
    controller.start()
    #expect(center.observing == 1)
    let handler = center.handler
    controller.stop()
    controller.stop()
    #expect(controller.status == .off && center.stoppedObserving == 1 && center.pending.isEmpty)
    handler?()                                                 // late notification
    center.timers.forEach { $0.action() }                      // stale timers, even cancelled ones
    #expect(controller.status == .off)
}

@Test @MainActor func aCallNoticeStaysUntilEndedAndEndingLeavesOtherNoticesAlone() {
    let model = IslandPresentation(layout: IslandGeometry.layout(for: IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )), scheduler: { _, _ in AnyCancellable {} })
    #expect(IslandActivity.incomingCall(callerFirstName: nil).displayDuration > IslandActivity.timerDone(duration: 60).displayDuration)
    model.showActivity(.incomingCall(callerFirstName: "Alex"))
    #expect(model.activity == .incomingCall(callerFirstName: "Alex"))
    model.endActivity()
    #expect(model.activity == nil)
}

// MARK: - Ongoing call notice

@MainActor
private final class Timers {
    var jobs: [(action: @MainActor () -> Void, flag: Flag)] = []
    func model() -> IslandPresentation {
        IslandPresentation(layout: IslandGeometry.layout(for: IslandGeometry.Display(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )), scheduler: { [unowned self] _, action in
            let flag = Flag()
            self.jobs.append((action, flag))
            return AnyCancellable { flag.cancelled = true }
        })
    }
    func fireLatest() {
        if let job = jobs.last(where: { !$0.flag.cancelled }) { job.action() }
    }
}

private let ringing = IslandActivity.incomingCall(callerFirstName: "Alex")

@Test @MainActor func aRingingCallReturnsAfterTheIslandIsOpenedAndClosed() {
    let timers = Timers()
    let model = timers.model()
    model.setSticky(ringing)
    #expect(model.activity == ringing)
    model.toggle()                                            // open while ringing
    #expect(model.isExpanded && model.activity == nil)
    model.toggle()                                            // close: still ringing
    #expect(model.activity == ringing && model.isWidened)
    model.toggle()
    model.collapse()                                          // closing by Escape or hover-out
    #expect(model.activity == ringing)
}

@Test @MainActor func anotherNoticeCanShowAndTheCallComesBackAfterIt() {
    let timers = Timers()
    let model = timers.model()
    model.setSticky(ringing)
    model.showActivity(.battery(.pluggedIn(percent: 50)))
    #expect(model.activity == .battery(.pluggedIn(percent: 50)))
    timers.fireLatest()                                       // the battery notice ends
    #expect(model.activity == ringing)
}

@Test @MainActor func endingTheCallRemovesItAndItDoesNotReturn() {
    let timers = Timers()
    let model = timers.model()
    model.setSticky(ringing)
    model.setSticky(nil)                                      // answered, declined or missed
    #expect(model.activity == nil && model.stickyActivity == nil)
    model.setSticky(ringing)
    model.toggle()
    model.setSticky(nil)                                      // call ended while the island was open
    model.toggle()
    #expect(model.activity == nil)
}

@Test @MainActor func clearingTheCallLeavesAnUnrelatedNoticeAlone() {
    let timers = Timers()
    let model = timers.model()
    model.setSticky(ringing)
    model.showActivity(.airDropReceived)
    model.setSticky(nil)
    #expect(model.activity == .airDropReceived)
}
