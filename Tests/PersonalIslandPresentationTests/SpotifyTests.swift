import Foundation
import Testing
@testable import PersonalIslandPresentation

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func notification(_ state: String = "Playing", id: String? = "spotify:track:1", name: String? = "Song",
                          artist: String? = "Artist", album: String? = "Album",
                          durationMs: Any? = 180_000, position: Any? = 12.5) -> [AnyHashable: Any] {
    var info: [AnyHashable: Any] = ["Player State": state]
    if let id { info["Track ID"] = id }
    if let name { info["Name"] = name }
    if let artist { info["Artist"] = artist }
    if let album { info["Album"] = album }
    if let durationMs { info["Duration"] = durationMs }
    if let position { info["Playback Position"] = position }
    return info
}

// MARK: - Parsing

@Test func playingNotificationParsesWithMillisecondDurationAndSecondPosition() {
    let update = SpotifyPlayback.update(fromNotification: notification(), at: t0)
    #expect(update == .track(NowPlaying(trackID: "spotify:track:1", title: "Song", artist: "Artist", album: "Album",
                                        duration: 180, position: 12.5, isPlaying: true, observedAt: t0)))
}

@Test func pausedStoppedAndUnknownStatesAreDistinguished() {
    guard case .track(let paused)? = SpotifyPlayback.update(fromNotification: notification("Paused"), at: t0) else {
        Issue.record("expected a paused track"); return
    }
    #expect(!paused.isPlaying)
    #expect(SpotifyPlayback.update(fromNotification: notification("Stopped", id: nil, name: nil), at: t0) == .stopped)
    #expect(SpotifyPlayback.update(fromNotification: notification("Buffering"), at: t0) == nil)
    #expect(SpotifyPlayback.update(fromNotification: ["Name": "No state"], at: t0) == nil)
    #expect(SpotifyPlayback.update(fromNotification: ["Player State": 1], at: t0) == nil)
}

@Test func missingTrackIdentityIsIgnoredButOtherMissingFieldsDegradeGracefully() {
    #expect(SpotifyPlayback.update(fromNotification: notification(id: nil), at: t0) == nil)
    #expect(SpotifyPlayback.update(fromNotification: notification(name: "   "), at: t0) == nil)
    guard case .track(let track)? = SpotifyPlayback.update(
        fromNotification: notification(artist: nil, album: nil, durationMs: "long", position: "far"), at: t0
    ) else { Issue.record("expected a track"); return }
    #expect(track.artist == "" && track.album == "")
    #expect(track.duration == nil)
    #expect(track.position == 0)
}

@Test func invalidNumbersAreRejectedAndPositionIsClampedToTheTrack() {
    for (duration, position, expectedDuration, expectedPosition) in [
        (Double.nan, 10.0, nil, 10.0), (-5_000, 10, nil, 10), (0, 10, nil, 10),
        (60_000, -3, 60, 0), (60_000, .infinity, 60, 0), (60_000, 500, 60, 60),
    ] as [(Double, Double, TimeInterval?, TimeInterval)] {
        guard case .track(let track)? = SpotifyPlayback.update(
            fromNotification: notification(durationMs: duration, position: position), at: t0
        ) else { Issue.record("expected a track"); continue }
        #expect(track.duration == expectedDuration)
        #expect(track.position == expectedPosition)
    }
}

@Test func displayTextIsStrippedOfControlCharactersAndBounded() {
    #expect(SpotifyPlayback.clean("A\u{0}B\nC\u{7}") == "ABC")
    #expect(SpotifyPlayback.clean(" \t ") == nil)
    #expect(SpotifyPlayback.clean(String(repeating: "x", count: 1_000))?.count == SpotifyPlayback.maximumTextLength)
    #expect(SpotifyPlayback.clean("Beyoncé 🎵") == "Beyoncé 🎵")
}

@Test func positionAdvancesOnlyWhilePlayingAndStaysInsideTheTrack() {
    var track = NowPlaying(trackID: "t", title: "T", artist: "", album: "", duration: 100,
                           position: 90, isPlaying: true, observedAt: t0)
    #expect(track.position(at: t0.addingTimeInterval(5)) == 95)
    #expect(track.position(at: t0.addingTimeInterval(60)) == 100)
    #expect(track.position(at: t0.addingTimeInterval(-30)) == 90)   // clock moved backwards
    track.isPlaying = false
    #expect(track.position(at: t0.addingTimeInterval(60)) == 90)
    track.duration = nil
    track.isPlaying = true
    #expect(track.position(at: t0.addingTimeInterval(500)) == 590)
}

@Test func timesFormatLikeAMediaPlayer() {
    #expect(SpotifyPlayback.timeText(0) == "0:00")
    #expect(SpotifyPlayback.timeText(65.9) == "1:05")
    #expect(SpotifyPlayback.timeText(3_725) == "1:02:05")
    #expect(SpotifyPlayback.timeText(-4) == "0:00")
    #expect(SpotifyPlayback.timeText(.nan) == "0:00")
}

// MARK: - Lifecycle

@MainActor
private final class FakeSpotify {
    var running = true
    var permission: SpotifyPermission = .granted
    var snapshot: SpotifyPlayback.Update = .track(NowPlaying(trackID: "a", title: "First", artist: "X", album: "Y",
                                                            duration: 200, position: 10, isPlaying: true, observedAt: t0))
    var snapshotError: (any Error)?
    var sendError: (any Error)?
    var log: [String] = []
    var handler: (@MainActor (SpotifyEvent) -> Void)?
    var activeObservations = 0
    var holdSnapshot = false
    var holdPermission = false
    var holdSettle = false
    var pendingSettles: [CheckedContinuation<Void, Never>] = []
    var sent: [SpotifyCommand] = []
    var pendingPermission: CheckedContinuation<Void, Never>?
    var pendingSnapshot: CheckedContinuation<Void, Never>?
    var now = t0

    func controller() -> SpotifyController {
        SpotifyController(environment: .init(
            isRunning: { [unowned self] in self.running },
            permission: { [unowned self] ask in
                self.log.append(ask ? "permission(ask)" : "permission")
                if self.holdPermission && ask { await withCheckedContinuation { self.pendingPermission = $0 } }
                return self.permission
            },
            snapshot: { [unowned self] in
                self.log.append("snapshot")
                if self.holdSnapshot { await withCheckedContinuation { self.pendingSnapshot = $0 } }
                if let error = self.snapshotError { throw error }
                return self.snapshot
            },
            send: { [unowned self] command in
                self.log.append("send \(command)")
                self.sent.append(command)
                if let error = self.sendError { throw error }
            },
            observe: { [unowned self] handler in
                self.handler = handler
                self.activeObservations += 1
                self.log.append("observe")
                return NSObject()
            },
            stopObserving: { [unowned self] _ in
                self.handler = nil
                self.activeObservations -= 1
                self.log.append("stopObserving")
            },
            now: { [unowned self] in self.now },
            settle: { [unowned self] in
                self.log.append("settle")
                if self.holdSettle { await withCheckedContinuation { self.pendingSettles.append($0) } }
            }
        ))
    }
}

@Test @MainActor func startObservesReadsTheTrackAndStopEndsAllWork() async {
    let fake = FakeSpotify()
    let controller = fake.controller()
    var changes = 0
    controller.onChange = { changes += 1 }
    await controller.start(askPermission: true)
    #expect(fake.log == ["observe", "permission(ask)", "snapshot"])
    #expect(controller.status == .ready)
    #expect(controller.nowPlaying?.title == "First")
    #expect(fake.activeObservations == 1)

    controller.stop()
    controller.stop()
    #expect(fake.activeObservations == 0)
    #expect(controller.status == .off)
    #expect(controller.nowPlaying == nil)
    #expect(changes == 2)

    // After stop, events, refreshes and commands do nothing.
    fake.log = []
    await controller.refresh()
    await controller.perform(.next)
    #expect(fake.log.isEmpty)
    #expect(controller.status == .off)
}

@Test @MainActor func startingTwiceDoesNotObserveTwice() async {
    let fake = FakeSpotify()
    let controller = fake.controller()
    await controller.start(askPermission: false)
    await controller.start(askPermission: false)
    #expect(fake.activeObservations == 1)
}

@Test @MainActor func aReplyArrivingAfterStopIsIgnored() async {
    let fake = FakeSpotify()
    fake.holdSnapshot = true
    let controller = fake.controller()
    let starting = Task { await controller.start(askPermission: false) }
    while fake.pendingSnapshot == nil { await Task.yield() }
    controller.stop()
    fake.pendingSnapshot?.resume()
    await starting.value
    #expect(controller.status == .off)
    #expect(controller.nowPlaying == nil)
}

@Test @MainActor func spotifyNotRunningIsReportedWithoutAskingOrLaunching() async {
    let fake = FakeSpotify()
    fake.running = false
    let controller = fake.controller()
    await controller.start(askPermission: true)
    #expect(controller.status == .notRunning)
    #expect(fake.log == ["observe"])
    await controller.perform(.playPause)
    #expect(fake.log == ["observe"])
}

@Test @MainActor func permissionStatesAreReportedAndCommandsAskBeforeSending() async {
    let fake = FakeSpotify()
    fake.permission = .needsConsent
    let controller = fake.controller()
    await controller.start(askPermission: false)
    #expect(controller.status == .needsPermission)

    fake.permission = .denied
    await controller.perform(.next)
    #expect(controller.status == .denied)
    #expect(!fake.log.contains("send next"))

    fake.permission = .granted
    fake.log = []
    await controller.perform(.next)
    #expect(fake.log == ["permission(ask)", "send next", "settle", "permission", "snapshot"])
    #expect(controller.status == .ready)
}

@Test @MainActor func notificationsUpdateTheTrackAndQuitClearsIt() async {
    let fake = FakeSpotify()
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.now = t0.addingTimeInterval(30)
    fake.handler?(.playback(notification("Paused", id: "b", name: "Second", position: 40)))
    #expect(controller.nowPlaying?.title == "Second")
    #expect(controller.nowPlaying?.isPlaying == false)
    #expect(controller.nowPlaying?.observedAt == fake.now)
    fake.handler?(.playback(["garbage": true]))
    #expect(controller.nowPlaying?.title == "Second")
    fake.handler?(.playback(notification("Stopped")))
    #expect(controller.nowPlaying == nil)
    #expect(controller.status == .ready)
    fake.handler?(.terminated)
    #expect(controller.status == .notRunning)
}

@Test @MainActor func trackInfoStillShowsWhenControlIsNotAllowed() async {
    let fake = FakeSpotify()
    fake.permission = .denied
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.handler?(.playback(notification()))
    #expect(controller.status == .denied)
    #expect(controller.nowPlaying?.title == "Song")
}

@Test @MainActor func playPauseFlipsStateImmediatelyKeepingThePosition() async {
    let fake = FakeSpotify()
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.now = t0.addingTimeInterval(5)
    fake.holdSnapshot = true
    let pressing = Task { await controller.perform(.playPause) }
    while fake.pendingSnapshot == nil { await Task.yield() }
    #expect(controller.nowPlaying?.isPlaying == false)
    #expect(controller.nowPlaying?.position == 15)
    fake.snapshot = .track(NowPlaying(trackID: "a", title: "First", artist: "X", album: "Y",
                                      duration: 200, position: 15, isPlaying: false, observedAt: fake.now))
    fake.pendingSnapshot?.resume()
    await pressing.value
    #expect(controller.nowPlaying?.isPlaying == false)
}

@Test @MainActor func scriptingFailuresMapToStatuses() async {
    for (error, expected) in [(SpotifyError.notRunning, SpotifyStatus.notRunning),
                              (.notPermitted, .denied), (.unexpectedReply, .unavailable)] {
        let fake = FakeSpotify()
        fake.snapshotError = error
        let controller = fake.controller()
        await controller.start(askPermission: false)
        #expect(controller.status == expected)
    }
    let fake = FakeSpotify()
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.sendError = SpotifyError.notPermitted
    await controller.perform(.previous)
    #expect(controller.status == .denied)
}

@Test @MainActor func launchRefreshesAndANotificationRecoversFromUnavailable() async {
    let fake = FakeSpotify()
    fake.running = false
    let controller = fake.controller()
    await controller.start(askPermission: false)
    #expect(controller.status == .notRunning)
    fake.running = true
    fake.handler?(.launched)
    while controller.status != .ready { await Task.yield() }
    #expect(controller.nowPlaying?.title == "First")

    let other = FakeSpotify()
    other.snapshotError = SpotifyError.unexpectedReply
    let recovering = other.controller()
    await recovering.start(askPermission: false)
    #expect(recovering.status == .unavailable)
    other.handler?(.playback(notification()))
    #expect(recovering.status == .ready)
}

// MARK: - Deadlines for blocking platform calls

private final class Latch: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
}

@Test func aCallThatNeverAnswersFallsBackAtTheDeadline() async {
    let latch = Latch()
    let started = Date()
    // Models the Automation permission query that blocked indefinitely.
    let result = await Deadline.run(seconds: 0.2, fallback: "fallback") {
        latch.semaphore.wait()
        return "late"
    }
    #expect(result == "fallback")
    #expect(Date().timeIntervalSince(started) < 5)
    latch.semaphore.signal()   // let the blocked thread finish; its result is discarded
}

@Test func aPromptAnswerBeforeTheDeadlineIsUsed() async {
    let result = await Deadline.run(seconds: 5, fallback: 0) { 42 }
    #expect(result == 42)
}

@Test func aLateAnswerAfterTheFallbackIsDiscardedSafely() async {
    let latch = Latch()
    let result = await Deadline.run(seconds: 0.05, fallback: 1) {
        latch.semaphore.wait()
        return 2
    }
    #expect(result == 1)
    latch.semaphore.signal()
    // Give the late result a chance to arrive; it must not crash by
    // resuming the same continuation twice.
    try? await Task.sleep(for: .milliseconds(100))
}

@Test @MainActor func repeatedPressesWhileMacOSHasNotAnsweredSendOnlyOnePermissionRequest() async {
    let fake = FakeSpotify()
    fake.permission = .needsConsent
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.log = []
    fake.holdPermission = true
    let first = Task { await controller.perform(.playPause) }
    while fake.pendingPermission == nil { await Task.yield() }
    await controller.perform(.next)
    await controller.perform(.previous)
    await controller.refresh(askPermission: true)
    #expect(fake.log == ["permission(ask)"])

    fake.permission = .granted
    fake.holdPermission = false
    fake.pendingPermission?.resume()
    await first.value
    #expect(fake.log.prefix(2) == ["permission(ask)", "send playPause"])
    #expect(controller.status == .ready)

    // Once answered, a new request can be made again.
    controller.stop()
    await controller.start(askPermission: true)
    #expect(fake.log.last == "snapshot")
}

@Test @MainActor func stoppingWhileAPermissionRequestIsOpenAllowsAFreshStart() async {
    let fake = FakeSpotify()
    fake.permission = .needsConsent
    fake.holdPermission = true
    let controller = fake.controller()
    let starting = Task { await controller.start(askPermission: true) }
    while fake.pendingPermission == nil { await Task.yield() }
    controller.stop()
    fake.holdPermission = false
    fake.permission = .granted
    await controller.start(askPermission: true)
    #expect(controller.status == .ready)
    fake.pendingPermission?.resume()
    await starting.value
    #expect(controller.status == .ready)
}

// MARK: - Command confirmation and seeking

@Test @MainActor func playPauseShowsTheChangeBeforeSendingAndConfirmsOnlyAfterSettling() async {
    let fake = FakeSpotify()
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.log = []
    fake.holdSettle = true
    let pressing = Task { await controller.perform(.playPause) }
    while fake.pendingSettles.isEmpty { await Task.yield() }
    // Flipped immediately; no state read yet that could flip it back.
    #expect(controller.nowPlaying?.isPlaying == false)
    #expect(fake.log == ["send playPause", "settle"])
    fake.snapshot = .track(NowPlaying(trackID: "a", title: "First", artist: "X", album: "Y",
                                      duration: 200, position: 10, isPlaying: false, observedAt: t0))
    fake.pendingSettles.removeFirst().resume()
    await pressing.value
    #expect(fake.log == ["send playPause", "settle", "permission", "snapshot"])
    #expect(controller.nowPlaying?.isPlaying == false)
}

@Test @MainActor func anOlderConfirmationDoesNotOverwriteANewerCommand() async {
    let fake = FakeSpotify()
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.holdSettle = true
    let first = Task { await controller.perform(.playPause) }
    while fake.pendingSettles.count < 1 { await Task.yield() }
    let second = Task { await controller.perform(.playPause) }
    while fake.pendingSettles.count < 2 { await Task.yield() }
    #expect(controller.nowPlaying?.isPlaying == true)   // toggled twice
    fake.log = []
    fake.pendingSettles.removeFirst().resume()
    await first.value
    #expect(fake.log.isEmpty)                          // stale confirmation skipped
    fake.pendingSettles.removeFirst().resume()
    await second.value
    #expect(fake.log == ["permission", "snapshot"])
}

@Test @MainActor func seekingMovesThePositionAtOnceAndIsClampedToTheTrack() async {
    let fake = FakeSpotify()
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.now = t0.addingTimeInterval(3)
    fake.holdSettle = true
    let seeking = Task { await controller.perform(.seek(500)) }
    while fake.pendingSettles.isEmpty { await Task.yield() }
    #expect(fake.sent == [.seek(200)])
    #expect(controller.nowPlaying?.position(at: fake.now) == 200)
    fake.holdSettle = false
    fake.pendingSettles.removeFirst().resume()
    await seeking.value

    await controller.perform(.seek(-20))
    #expect(fake.sent.last == .seek(0))
    let count = fake.sent.count
    await controller.perform(.seek(.nan))
    #expect(fake.sent.count == count)
}

@Test @MainActor func seekingWithoutAKnownTrackLengthSendsNothing() async {
    let fake = FakeSpotify()
    fake.snapshot = .track(NowPlaying(trackID: "a", title: "Live", artist: "", album: "",
                                      duration: nil, position: 10, isPlaying: true, observedAt: t0))
    let controller = fake.controller()
    await controller.start(askPermission: false)
    await controller.perform(.seek(30))
    #expect(fake.sent.isEmpty)
    fake.snapshot = .stopped
    await controller.refresh()
    await controller.perform(.seek(30))
    #expect(fake.sent.isEmpty)
}

@Test @MainActor func aFailedCommandRestoresTheRealStateInsteadOfTheGuess() async {
    let fake = FakeSpotify()
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.sendError = SpotifyError.unexpectedReply
    await controller.perform(.playPause)
    #expect(controller.nowPlaying?.isPlaying == true)   // re-read from Spotify
    #expect(!fake.log.contains("settle"))
}

// MARK: - Failed checks and recovery

@Test @MainActor func aCheckThatFailsIsNotShownAsMissingPermission() async {
    let fake = FakeSpotify()
    fake.permission = .noAnswer
    let controller = fake.controller()
    await controller.start(askPermission: false)
    #expect(controller.status == .unavailable)
    await controller.perform(.next)
    #expect(controller.status == .unavailable && fake.sent.isEmpty)
}

@Test @MainActor func aStuckPermissionStateIsRecheckedQuietlyWhenSpotifyUpdates() async {
    let fake = FakeSpotify()
    fake.permission = .needsConsent
    let controller = fake.controller()
    await controller.start(askPermission: false)
    #expect(controller.status == .needsPermission)
    fake.log = []
    fake.permission = .granted                                   // allowed meanwhile in System Settings
    fake.handler?(.playback(notification("Playing", id: "b", name: "Second", position: 5)))
    while controller.status != .ready { await Task.yield() }
    #expect(fake.log.first == "permission")                      // quiet check, never "permission(ask)"
    #expect(!fake.log.contains("permission(ask)"))
}

@Test @MainActor func quietRechecksAreLimitedToOneEveryTenSeconds() async {
    let fake = FakeSpotify()
    fake.permission = .needsConsent
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.log = []
    for _ in 0..<5 { fake.handler?(.playback(notification("Playing", id: "a", name: "First", position: 1))) }
    for _ in 0..<20 { await Task.yield() }
    #expect(fake.log.filter { $0 == "permission" }.count == 1)
    fake.now = fake.now.addingTimeInterval(SpotifyController.recheckInterval)
    fake.handler?(.playback(notification("Playing", id: "a", name: "First", position: 2)))
    for _ in 0..<20 { await Task.yield() }
    #expect(fake.log.filter { $0 == "permission" }.count == 2)
    #expect(controller.status == .needsPermission)
}

// MARK: - Previous

@Test @MainActor func previousPastThreeSecondsShowsTheRestartAtOnce() async {
    let fake = FakeSpotify()                                     // playing, 10 s in
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.holdSettle = true
    let pressing = Task { await controller.perform(.previous) }
    while fake.pendingSettles.isEmpty { await Task.yield() }
    #expect(controller.nowPlaying?.position(at: fake.now) == 0)  // before Spotify confirms
    #expect(controller.nowPlaying?.trackID == "a")
    fake.pendingSettles.removeFirst().resume()
    await pressing.value
}

@Test @MainActor func previousNearTheStartWaitsForSpotifysNewTrack() async {
    let fake = FakeSpotify()
    fake.snapshot = .track(NowPlaying(trackID: "a", title: "First", artist: "X", album: "Y",
                                      duration: 200, position: 1, isPlaying: true, observedAt: t0))
    let controller = fake.controller()
    await controller.start(askPermission: false)
    fake.holdSettle = true
    let pressing = Task { await controller.perform(.previous) }
    while fake.pendingSettles.isEmpty { await Task.yield() }
    #expect(controller.nowPlaying?.position(at: fake.now) == 1)  // unchanged: a different track is coming
    fake.pendingSettles.removeFirst().resume()
    await pressing.value
}
