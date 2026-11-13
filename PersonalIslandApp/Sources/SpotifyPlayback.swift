/*
 * Personal Island — Spotify playback model and lifecycle.
 * Written for this personal project; no upstream file copied.
 */

import Foundation

/// The track Spotify reports, kept only in memory and never persisted.
struct NowPlaying: Equatable {
    var trackID: String
    var title: String
    var artist: String
    var album: String
    /// Seconds, when known.
    var duration: TimeInterval?
    /// Seconds into the track at `observedAt`.
    var position: TimeInterval
    var isPlaying: Bool
    var observedAt: Date

    /// Position extrapolated from the last observation while playing, kept
    /// within the track. A clock that moved backwards cannot rewind it.
    func position(at now: Date) -> TimeInterval {
        let elapsed = isPlaying ? max(0, now.timeIntervalSince(observedAt)) : 0
        let value = position + elapsed
        if let duration { return min(max(0, value), duration) }
        return max(0, value)
    }
}

enum SpotifyStatus: Equatable {
    /// The feature switch is off; nothing is observed or sent.
    case off
    case notRunning
    /// macOS has not been asked yet whether this app may control Spotify.
    case needsPermission
    /// The user declined Automation access to Spotify.
    case denied
    case ready
    /// Spotify did not answer as expected (for example, it is still starting).
    case unavailable
}

enum SpotifyCommand: Equatable {
    case playPause, next, previous
    /// Seconds into the current track.
    case seek(TimeInterval)
}

enum SpotifyPermission: Equatable {
    case granted, needsConsent, denied, notRunning
    /// The check itself failed or timed out (e.g. Spotify was busy). This is
    /// not a permission answer and must not be shown as one.
    case noAnswer
}

enum SpotifyError: Error, Equatable { case notRunning, notPermitted, unexpectedReply }

/// Something Spotify or the system reported while observation is active.
enum SpotifyEvent {
    /// The user info of Spotify's own playback-state notification.
    case playback([AnyHashable: Any])
    case launched
    case terminated
}

enum SpotifyPlayback {
    enum Update: Equatable {
        case stopped
        case track(NowPlaying)
    }

    static let bundleIdentifier = "com.spotify.client"
    static let notificationName = "com.spotify.client.PlaybackStateChanged"
    /// Display text is truncated; nothing longer is ever kept.
    static let maximumTextLength = 300

    /// Parses Spotify's playback notification. Duration arrives in
    /// milliseconds and position in seconds. Returns nil for unusable input.
    static func update(fromNotification info: [AnyHashable: Any], at date: Date) -> Update? {
        guard let state = info["Player State"] as? String else { return nil }
        return update(
            state: state,
            trackID: info["Track ID"] as? String,
            title: info["Name"] as? String,
            artist: info["Artist"] as? String,
            album: info["Album"] as? String,
            durationMilliseconds: (info["Duration"] as? NSNumber)?.doubleValue,
            position: (info["Playback Position"] as? NSNumber)?.doubleValue,
            at: date
        )
    }

    /// Shared by the notification and scripting paths. `state` is
    /// "Playing", "Paused" or "Stopped" (case-insensitive).
    static func update(
        state: String, trackID: String?, title: String?, artist: String?, album: String?,
        durationMilliseconds: Double?, position: Double?, at date: Date
    ) -> Update? {
        let isPlaying: Bool
        switch state.lowercased() {
        case "playing": isPlaying = true
        case "paused": isPlaying = false
        case "stopped": return .stopped
        default: return nil
        }
        guard let trackID = clean(trackID), let title = clean(title) else { return nil }
        let duration = durationMilliseconds.flatMap { $0.isFinite && $0 > 0 ? $0 / 1_000 : nil }
        var seconds = position.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        if let duration { seconds = min(seconds, duration) }
        return .track(NowPlaying(
            trackID: trackID, title: title, artist: clean(artist) ?? "", album: clean(album) ?? "",
            duration: duration, position: seconds, isPlaying: isPlaying, observedAt: date
        ))
    }

    /// Removes control characters and bounds length; empty text is nil.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumTextLength))
    }

    /// `m:ss`, or `h:mm:ss` from one hour.
    static func timeText(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3_600, minutes = total / 60 % 60, remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}

/// Runs blocking platform work on its own thread and returns `fallback` if it
/// has not finished by the deadline. Some system calls (for example the
/// Automation permission query) can block indefinitely; a deadline keeps the
/// feature responsive. A late result is discarded and never delivered twice.
enum Deadline {
    static func run<T: Sendable>(
        seconds: TimeInterval, fallback: T, _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let gate = Gate(continuation)
            Thread.detachNewThread { gate.resume(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { gate.resume(fallback) }
        }
    }

    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
        func resume(_ value: T) {
            let pending: CheckedContinuation<T, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}

/// Starts and stops all Spotify work for the feature switch. Platform access
/// is injected: tests drive it without Spotify, Apple Events or permissions.
@MainActor
final class SpotifyController {
    struct Environment {
        var isRunning: @MainActor () -> Bool
        var permission: @MainActor (_ askIfNeeded: Bool) async -> SpotifyPermission
        var snapshot: @MainActor () async throws -> SpotifyPlayback.Update
        var send: @MainActor (SpotifyCommand) async throws -> Void
        /// Begins observing Spotify notifications and app launch/quit; the
        /// returned token ends that observation.
        var observe: @MainActor (_ handler: @escaping @MainActor (SpotifyEvent) -> Void) -> AnyObject
        var stopObserving: @MainActor (AnyObject) -> Void
        var now: @MainActor () -> Date
        /// Pause before confirming a command's effect: Spotify's scripting
        /// interface can report the old state for a moment after a change.
        var settle: @MainActor () async -> Void
    }

    private(set) var status: SpotifyStatus = .off
    private(set) var nowPlaying: NowPlaying?
    var onChange: (@MainActor () -> Void)?

    private let environment: Environment
    private var observation: AnyObject?
    /// Bumped on stop so late replies from a previous session are ignored.
    private var generation = 0
    /// One permission request at a time: while macOS has not answered (the
    /// dialog is open, or the system is slow), further presses must not pile
    /// up additional blocked requests.
    private var permissionRequestInFlight = false
    /// Counts commands so only the latest one's confirmation is applied.
    private var commandSequence = 0
    /// When the last quiet re-check ran, so a stuck permission state is
    /// re-checked at most every `recheckInterval` seconds.
    private var lastQuietCheck: Date?
    static let recheckInterval: TimeInterval = 10
    /// Past this many seconds, Spotify's "previous" restarts the current
    /// track instead of going to the previous one.
    static let restartThreshold: TimeInterval = 3

    var isActive: Bool { observation != nil }

    init(environment: Environment) {
        self.environment = environment
    }

    func start(askPermission: Bool) async {
        guard observation == nil else { return }
        generation += 1
        observation = environment.observe { [weak self] event in self?.handle(event) }
        await refresh(askPermission: askPermission)
    }

    /// Ends observation and forgets the track. Safe to call repeatedly.
    func stop() {
        guard let observation else { return }
        environment.stopObserving(observation)
        self.observation = nil
        generation += 1
        permissionRequestInFlight = false
        lastQuietCheck = nil
        set(.off, nil)
    }

    /// Re-reads Spotify's state. Never launches Spotify.
    func refresh(askPermission: Bool = false) async {
        guard observation != nil else { return }
        let session = generation
        guard environment.isRunning() else { return set(.notRunning, nil) }
        if askPermission {
            guard !permissionRequestInFlight else { return }
            permissionRequestInFlight = true
        }
        let permission = await environment.permission(askPermission)
        if askPermission { permissionRequestInFlight = false }
        guard session == generation else { return }
        switch permission {
        case .granted:
            do {
                let update = try await environment.snapshot()
                guard session == generation else { return }
                apply(update, status: .ready)
            } catch {
                guard session == generation else { return }
                fail(error)
            }
        case .needsConsent: set(.needsPermission, nowPlaying)
        case .denied: set(.denied, nowPlaying)
        case .notRunning: set(.notRunning, nil)
        case .noAnswer: set(.unavailable, nowPlaying)
        }
    }

    /// Sends a control command, asking for permission first if needed.
    func perform(_ command: SpotifyCommand) async {
        guard observation != nil else { return }
        let session = generation
        guard environment.isRunning() else { return set(.notRunning, nil) }
        if status != .ready {
            guard !permissionRequestInFlight else { return }
            permissionRequestInFlight = true
            let permission = await environment.permission(true)
            permissionRequestInFlight = false
            guard session == generation else { return }
            guard permission == .granted else {
                switch permission {
                case .denied: set(.denied, nowPlaying)
                case .notRunning: set(.notRunning, nil)
                case .noAnswer: set(.unavailable, nowPlaying)
                default: set(.needsPermission, nowPlaying)
                }
                return
            }
            set(.ready, nowPlaying)
        }
        var command = command
        if case .seek(let target) = command {
            // Seeking needs a track whose length is known.
            guard let duration = nowPlaying?.duration, target.isFinite else { return }
            command = .seek(min(max(0, target), duration))
        }
        commandSequence += 1
        let sequence = commandSequence
        // Show the expected result at once, so the button and slider do not
        // wait on Spotify. A failed command re-reads the real state.
        if var track = nowPlaying {
            let now = environment.now()
            switch command {
            case .playPause:
                track.position = track.position(at: now)
                track.isPlaying.toggle()
            case .seek(let target):
                track.position = target
            case .previous where track.position(at: now) >= SpotifyController.restartThreshold:
                // Spotify restarts the current track rather than going back.
                track.position = 0
            case .next, .previous:
                // A different track: shown when Spotify reports it.
                break
            }
            track.observedAt = now
            set(status, track)
        }
        do {
            try await environment.send(command)
        } catch {
            guard session == generation else { return }
            fail(error)
            // An unexpected failure re-reads the real state to undo the
            // guess; "not running" and "not permitted" are already definite.
            if case .notRunning? = error as? SpotifyError { return }
            if case .notPermitted? = error as? SpotifyError { return }
            return await refresh()
        }
        // Confirm once Spotify has applied the change, unless a newer command
        // has started (its own confirmation will follow).
        await environment.settle()
        guard session == generation, sequence == commandSequence else { return }
        await refresh()
    }

    private func handle(_ event: SpotifyEvent) {
        guard observation != nil else { return }
        switch event {
        case .playback(let info):
            // Spotify's own notification needs no permission to receive.
            guard let update = SpotifyPlayback.update(fromNotification: info, at: environment.now()) else { return }
            apply(update, status: status == .notRunning || status == .unavailable ? .ready : status)
            // Permission can be given in System Settings, and an earlier check
            // may have failed for other reasons; re-check quietly (never shows
            // a prompt) instead of staying stuck until a control is pressed.
            if status == .needsPermission || status == .denied, !permissionRequestInFlight {
                let now = environment.now()
                if lastQuietCheck.map({ now.timeIntervalSince($0) >= Self.recheckInterval }) ?? true {
                    lastQuietCheck = now
                    Task { [weak self] in await self?.refresh() }
                }
            }
        case .launched:
            Task { await self.refresh() }
        case .terminated:
            set(.notRunning, nil)
        }
    }

    private func apply(_ update: SpotifyPlayback.Update, status: SpotifyStatus) {
        switch update {
        case .stopped: set(status, nil)
        case .track(let track): set(status, track)
        }
    }

    private func fail(_ error: any Error) {
        switch error as? SpotifyError {
        case .notRunning?: set(.notRunning, nil)
        case .notPermitted?: set(.denied, nowPlaying)
        default: set(.unavailable, nowPlaying)
        }
    }

    private func set(_ status: SpotifyStatus, _ track: NowPlaying?) {
        guard status != self.status || track != nowPlaying else { return }
        self.status = status
        nowPlaying = track
        onChange?()
    }
}
