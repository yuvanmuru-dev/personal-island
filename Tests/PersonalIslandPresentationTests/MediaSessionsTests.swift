import Combine
import Foundation
import Testing
@testable import PersonalIslandPresentation

private let received = Date(timeIntervalSince1970: 1_000)

@Test func helperLinesBecomeSessionsWithPositionsBroughtForward() throws {
    let line = #"{"players":[{"id":"com.example.browser","name":"Browser","title":"Talk","artist":"Host","album":null,"duration":300,"elapsed":100,"rate":1,"timestamp":990},{"id":"com.example.player","name":"Player","title":"Song","artist":"Band","album":"Record","duration":200,"elapsed":50,"rate":null,"timestamp":900},{"id":"com.example.stream","name":"Stream","title":"Live","artist":"Channel","album":null,"duration":null,"elapsed":null,"rate":null,"timestamp":null}]}"#
    guard case .sessions(let sessions)? = MediaSessions.parse(line, receivedAt: received) else {
        Issue.record("not parsed"); return
    }
    #expect(sessions.map(\.id) == ["com.example.browser", "com.example.player", "com.example.stream"])
    #expect(sessions[0].isPlaying && sessions[0].position == 110)          // 10 s since the app reported it
    #expect(!sessions[1].isPlaying && sessions[1].position == 50)          // paused: not moved forward
    #expect(sessions[1].album == "Record" && sessions[0].album == nil)
    #expect(sessions[2].duration == nil && sessions[2].position == nil)    // a live stream
    #expect(sessions[0].position(at: received.addingTimeInterval(5)) == 115)
}

@Test func badOrHostileHelperOutputIsIgnoredOrBounded() {
    #expect(MediaSessions.parse("not json", receivedAt: received) == nil)
    #expect(MediaSessions.parse(#"{"something":"else"}"#, receivedAt: received) == nil)
    #expect(MediaSessions.parse(#"{"error":"unavailable"}"#, receivedAt: received) == .unavailable)
    #expect(MediaSessions.parse(String(repeating: " ", count: MediaSessions.maximumLineLength + 1), receivedAt: received) == nil)
    let tricky = #"{"players":[{"id":"bad\tid","name":"x"},{"id":"ok.app","name":"A\u0007pp","title":"T","elapsed":999,"duration":60,"rate":1,"timestamp":1000},{"id":"ok.app","name":"duplicate"}]}"#
    guard case .sessions(let sessions)? = MediaSessions.parse(tricky, receivedAt: received) else {
        Issue.record("not parsed"); return
    }
    #expect(sessions.map(\.id) == ["ok.app"])                              // bad id and duplicate dropped
    #expect(sessions[0].appName == "App" && sessions[0].position == 60)     // cleaned; clamped to duration
    let many = "{\"players\":[" + (0..<40).map { "{\"id\":\"app\($0)\",\"name\":\"A\"}" }.joined(separator: ",") + "]}"
    if case .sessions(let bounded)? = MediaSessions.parse(many, receivedAt: received) {
        #expect(bounded.count == MediaSessions.maximumSessions)
    } else { Issue.record("not parsed") }
}

@Test func infiniteOrMissingNumbersFromAnAppAreTreatedAsUnknown() {
    // Live streams can report an infinite length; the helper sends null, and
    // the parser must cope with either.
    let line = #"{"players":[{"id":"com.brave.Browser","name":"Brave","title":"Live","duration":null,"elapsed":null,"rate":1,"timestamp":null}]}"#
    if case .sessions(let sessions)? = MediaSessions.parse(line, receivedAt: received) {
        #expect(sessions.first?.duration == nil && sessions.first?.position == nil && sessions.first?.isPlaying == true)
    } else { Issue.record("not parsed") }
    // A number JSON cannot hold makes the whole line unreadable: skipped, never a crash.
    #expect(MediaSessions.parse(#"{"players":[{"id":"a.b","name":"A","duration":1e400}]}"#, receivedAt: received) == nil)
}

@Test @MainActor func tryAgainOnlyAppliesAfterTheHelperKeptStopping() {
    let helper = FakeHelper()
    let controller = helper.controller()
    controller.retry()                                              // not running
    controller.start()
    controller.retry()                                              // running fine: nothing to retry
    #expect(helper.launches == 1)
    helper.onLine?(#"{"error":"unavailable"}"#)
    controller.retry()                                              // macOS refused: retrying cannot help
    #expect(helper.launches == 1 && controller.status == .unavailable)
}

@Test func onlySafeCommandsReachTheHelper() {
    #expect(MediaSessions.commandLine(.togglePlayPause, for: "com.brave.Browser") == "toggle\tcom.brave.Browser\n")
    #expect(MediaSessions.commandLine(.seek(61.5), for: "org.mozilla.firefox") == "seek\torg.mozilla.firefox\t61.500\n")
    #expect(MediaSessions.commandLine(.next, for: "bad\nid") == nil)
    #expect(MediaSessions.commandLine(.previous, for: "") == nil)
    #expect(MediaSessions.commandLine(.seek(.nan), for: "a.b") == nil)
    #expect(MediaSessions.commandLine(.seek(-1), for: "a.b") == nil)
}

// MARK: - Helper lifecycle

private final class Flag: @unchecked Sendable { var cancelled = false }

@MainActor
private final class FakeHelper {
    var launches = 0
    var launchFails = false
    var terminated = 0
    var sent: [String] = []
    var onLine: (@MainActor (String) -> Void)?
    var onExit: (@MainActor () -> Void)?
    var now = received
    var timers: [(delay: TimeInterval, action: @MainActor () -> Void, flag: Flag)] = []

    func controller() -> MediaSessionsController {
        MediaSessionsController(environment: .init(
            launch: { [unowned self] onLine, onExit in
                self.launches += 1
                guard !self.launchFails else { return nil }
                self.onLine = onLine
                self.onExit = onExit
                return NSObject()
            },
            send: { [unowned self] _, line in self.sent.append(line) },
            terminate: { [unowned self] _ in self.terminated += 1 },
            now: { [unowned self] in self.now },
            schedule: { [unowned self] delay, action in
                let flag = Flag()
                self.timers.append((delay, action, flag))
                return AnyCancellable { flag.cancelled = true }
            }
        ))
    }

    func report(playing: Bool, id: String = "com.example.browser") {
        onLine?(#"{"players":[{"id":"\#(id)","name":"Browser","title":"Talk","duration":300,"elapsed":10,"rate":\#(playing ? 1 : 0),"timestamp":\#(now.timeIntervalSince1970)}]}"#)
    }

    func fireTimer() {
        if let timer = timers.last(where: { !$0.flag.cancelled }) { timer.action() }
    }
}

@Test @MainActor func startingRunsOneHelperAndReportsSessions() {
    let helper = FakeHelper()
    let controller = helper.controller()
    controller.start()
    controller.start()
    #expect(helper.launches == 1 && controller.status == .starting)
    helper.report(playing: true)
    #expect(controller.status == .ready && controller.sessions.map(\.id) == ["com.example.browser"])
}

@Test @MainActor func aTapShowsAtOnceAndOutlastsALateReport() {
    let helper = FakeHelper()
    let controller = helper.controller()
    controller.start()
    helper.report(playing: true)
    controller.perform(.togglePlayPause, on: "com.example.browser")
    #expect(controller.sessions[0].isPlaying == false)
    #expect(helper.sent == ["toggle\tcom.example.browser\n"])
    helper.report(playing: true)                                  // the app had not caught up yet
    #expect(controller.sessions[0].isPlaying == false)
    helper.now = helper.now.addingTimeInterval(MediaSessions.settleSeconds + 0.1)
    helper.report(playing: true)                                  // later reports win again
    #expect(controller.sessions[0].isPlaying == true)
}

@Test @MainActor func seeksAreClampedAndCommandsNeedAKnownApp() {
    let helper = FakeHelper()
    let controller = helper.controller()
    controller.start()
    controller.perform(.next, on: "com.example.browser")          // not ready yet
    #expect(helper.sent.isEmpty)
    helper.report(playing: false)
    controller.perform(.seek(9_999), on: "com.example.browser")
    #expect(helper.sent == ["seek\tcom.example.browser\t300.000\n"])
    #expect(controller.sessions[0].position == 300)
    controller.perform(.next, on: "com.unknown.app")
    #expect(helper.sent.count == 1)
}

@Test @MainActor func anUnexpectedExitRestartsWithBackoffThenGivesUp() {
    let helper = FakeHelper()
    let controller = helper.controller()
    controller.start()
    for (attempt, delay) in MediaSessions.restartDelays.enumerated() {
        helper.onExit?()
        #expect(helper.timers.last?.delay == delay)
        helper.fireTimer()
        #expect(helper.launches == attempt + 2)
    }
    helper.onExit?()
    #expect(controller.status == .failed && controller.sessions.isEmpty)   // not "macOS refused"
    controller.retry()                                                    // Try again
    #expect(helper.launches == MediaSessions.restartDelays.count + 2 && controller.status == .starting)
    helper.report(playing: true)
    #expect(controller.status == .ready)
}

@Test @MainActor func reportingCountsAsHealthySoLaterCrashesRestartAgain() {
    let helper = FakeHelper()
    let controller = helper.controller()
    controller.start()
    helper.onExit?(); helper.fireTimer()
    helper.onExit?(); helper.fireTimer()
    helper.report(playing: true)                                   // working again: failures reset
    helper.onExit?()
    #expect(helper.timers.last?.delay == MediaSessions.restartDelays[0])
}

@Test @MainActor func anUnavailableMacStopsWithoutRestarting() {
    let helper = FakeHelper()
    let controller = helper.controller()
    controller.start()
    helper.onLine?(#"{"error":"unavailable"}"#)
    #expect(controller.status == .unavailable && helper.terminated == 1)
    helper.onExit?()
    #expect(helper.timers.isEmpty && helper.launches == 1)
}

@Test @MainActor func aMissingHelperIsRetriedThenReportedUnavailable() {
    let helper = FakeHelper()
    helper.launchFails = true
    let controller = helper.controller()
    controller.start()
    for _ in MediaSessions.restartDelays { helper.fireTimer() }
    #expect(controller.status == .failed)
    #expect(helper.launches == MediaSessions.restartDelays.count + 1)
}

@Test @MainActor func stoppingEndsTheHelperForgetsSessionsAndIgnoresLateOutput() {
    let helper = FakeHelper()
    let controller = helper.controller()
    controller.start()
    helper.report(playing: true)
    let lateLine = helper.onLine, lateExit = helper.onExit
    controller.stop()
    controller.stop()
    #expect(helper.terminated == 1 && controller.status == .off && controller.sessions.isEmpty)
    lateLine?(#"{"players":[{"id":"x.y","name":"Late"}]}"#)
    lateExit?()
    helper.timers.forEach { $0.action() }
    #expect(controller.status == .off && controller.sessions.isEmpty && helper.launches == 1)
}
