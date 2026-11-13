/*
 * Personal Island — media from all apps: model and lifecycle.
 * Written for this personal project; no upstream file copied.
 *
 * macOS blocks apps from reading other apps' Now Playing sessions, so a
 * bundled helper (PersonalIslandApp/Helper) runs under Apple's /usr/bin/perl,
 * which may still read them, and reports one JSON line per change. This file
 * turns those lines into sessions and owns the helper's lifecycle. Track
 * details stay in memory only.
 */

import Combine
import Foundation

/// One app's media, as macOS's Now Playing reports it.
struct MediaSession: Identifiable, Equatable {
    /// The app's bundle identifier.
    let id: String
    let appName: String
    var title: String?
    var artist: String?
    var album: String?
    /// Seconds, when known (live streams have none).
    var duration: TimeInterval?
    /// Seconds into the track at `observedAt`, when known.
    var position: TimeInterval?
    var isPlaying: Bool
    var observedAt: Date

    func position(at now: Date) -> TimeInterval? {
        guard let position else { return nil }
        let value = position + (isPlaying ? max(0, now.timeIntervalSince(observedAt)) : 0)
        if let duration { return min(max(0, value), duration) }
        return max(0, value)
    }
}

enum MediaCommand: Equatable {
    case togglePlayPause, next, previous
    case seek(TimeInterval)
}

enum MediaBridgeMessage: Equatable {
    case sessions([MediaSession])
    /// The helper could not find the macOS functions it needs.
    case unavailable
}

enum MediaStatus: Equatable {
    case off
    case starting
    case ready
    /// This Mac's macOS lacks what the helper needs.
    case unavailable
    /// The helper kept stopping; it can be tried again.
    case failed
}

enum MediaSessions {
    static let maximumSessions = 16
    static let maximumLineLength = 256 * 1_024
    /// After a command, the shown play state wins over reports for this long:
    /// apps can briefly report the old state.
    static let settleSeconds: TimeInterval = 1.5
    /// Waits before restarting a helper that stopped unexpectedly.
    static let restartDelays: [TimeInterval] = [1, 3, 10]

    /// Reads one line from the helper. Positions are brought forward from the
    /// time the app reported them; malformed or oversized input is ignored.
    static func parse(_ line: String, receivedAt: Date) -> MediaBridgeMessage? {
        guard line.utf8.count <= maximumLineLength, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["error"] as? String == "unavailable" { return .unavailable }
        guard let players = object["players"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        var sessions: [MediaSession] = []
        for player in players.prefix(maximumSessions) {
            guard let id = player["id"] as? String, isValidIdentifier(id), seen.insert(id).inserted else { continue }
            let rate = (player["rate"] as? NSNumber)?.doubleValue ?? 0
            let playing = rate.isFinite && rate > 0
            let duration = finite(player["duration"]).flatMap { $0 > 0 ? $0 : nil }
            var position = finite(player["elapsed"]).map { max(0, $0) }
            if let elapsed = position, playing, let stamp = finite(player["timestamp"]) {
                position = elapsed + max(0, receivedAt.timeIntervalSince1970 - stamp) * rate
            }
            if let duration, let value = position { position = min(value, duration) }
            sessions.append(MediaSession(
                id: id,
                appName: SpotifyPlayback.clean(player["name"] as? String) ?? id,
                title: SpotifyPlayback.clean(player["title"] as? String),
                artist: SpotifyPlayback.clean(player["artist"] as? String),
                album: SpotifyPlayback.clean(player["album"] as? String),
                duration: duration, position: position, isPlaying: playing, observedAt: receivedAt
            ))
        }
        return .sessions(sessions)
    }

    /// The line sent to the helper, or nil for anything it must not receive.
    static func commandLine(_ command: MediaCommand, for id: String) -> String? {
        guard isValidIdentifier(id) else { return nil }
        switch command {
        case .togglePlayPause: return "toggle\t\(id)\n"
        case .next: return "next\t\(id)\n"
        case .previous: return "previous\t\(id)\n"
        case .seek(let seconds):
            guard seconds.isFinite, seconds >= 0 else { return nil }
            return "seek\t\(id)\t\(String(format: "%.3f", seconds))\n"
        }
    }

    /// Bundle-identifier characters only, so nothing can break the line protocol.
    static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) }
    }

    private static func finite(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
        return number
    }
}

/// Runs the helper while "Media from all apps" is on. Platform access is
/// injected so tests never start a process or read real media.
@MainActor
final class MediaSessionsController {
    struct Environment {
        /// Starts the helper; lines and its exit are delivered on the main actor.
        var launch: @MainActor (_ onLine: @escaping @MainActor (String) -> Void,
                                _ onExit: @escaping @MainActor () -> Void) -> AnyObject?
        var send: @MainActor (AnyObject, String) -> Void
        var terminate: @MainActor (AnyObject) -> Void
        var now: @MainActor () -> Date
        var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable
    }

    private(set) var status: MediaStatus = .off
    private(set) var sessions: [MediaSession] = []
    var onChange: (@MainActor () -> Void)?

    private let environment: Environment
    private var helper: AnyObject?
    private var isRunning = false
    private var generation = 0
    private var failures = 0
    private var restart: AnyCancellable?
    /// Play states shown after a command, until the app has caught up.
    private var pending: [String: (isPlaying: Bool, until: Date)] = [:]

    init(environment: Environment) {
        self.environment = environment
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        failures = 0
        launch()
    }

    /// Stops the helper and forgets every session.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        restart?.cancel()
        restart = nil
        if let helper { environment.terminate(helper) }
        helper = nil
        pending = [:]
        update(.off, [])
    }

    /// Starts again after the helper kept stopping.
    func retry() {
        guard isRunning, status == .failed else { return }
        failures = 0
        launch()
    }

    func perform(_ command: MediaCommand, on id: String) {
        guard status == .ready, let helper, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var command = command
        var session = sessions[index]
        let now = environment.now()
        switch command {
        case .togglePlayPause:
            session.position = session.position(at: now)
            session.isPlaying.toggle()
            pending[id] = (session.isPlaying, now.addingTimeInterval(MediaSessions.settleSeconds))
        case .seek(let target):
            guard let duration = session.duration, target.isFinite else { return }
            let clamped = min(max(0, target), duration)
            command = .seek(clamped)
            session.position = clamped
        case .next, .previous:
            break
        }
        guard let line = MediaSessions.commandLine(command, for: id) else { return }
        session.observedAt = now
        var next = sessions
        next[index] = session
        update(status, next)
        environment.send(helper, line)
    }

    private func launch() {
        generation += 1
        let session = generation
        update(.starting, sessions)
        helper = environment.launch({ [weak self] line in
            guard let self, session == self.generation else { return }
            self.received(line)
        }, { [weak self] in
            guard let self, session == self.generation else { return }
            self.exited()
        })
        if helper == nil { exited() }
    }

    private func received(_ line: String) {
        let now = environment.now()
        switch MediaSessions.parse(line, receivedAt: now) {
        case .sessions(let incoming)?:
            failures = 0
            pending = pending.filter { $0.value.until > now }
            let shown = incoming.map { session -> MediaSession in
                guard let held = pending[session.id] else { return session }
                var session = session
                session.isPlaying = held.isPlaying
                return session
            }
            update(.ready, shown)
        case .unavailable?:
            // Not a crash: this Mac's macOS lacks what the helper needs.
            generation += 1
            if let helper { environment.terminate(helper) }
            helper = nil
            update(.unavailable, [])
        case nil:
            break
        }
    }

    private func exited() {
        helper = nil
        guard isRunning, status != .unavailable else { return }
        guard failures < MediaSessions.restartDelays.count else {
            update(.failed, [])
            return
        }
        let delay = MediaSessions.restartDelays[failures]
        failures += 1
        generation += 1
        let session = generation
        restart = environment.schedule(delay) { [weak self] in
            guard let self, session == self.generation, self.isRunning else { return }
            self.launch()
        }
    }

    private func update(_ status: MediaStatus, _ sessions: [MediaSession]) {
        guard status != self.status || sessions != self.sessions else { return }
        self.status = status
        self.sessions = sessions
        onChange?()
    }
}
