/*
 * Personal Island — countdown timers model and lifecycle.
 * Written for this personal project; no upstream file copied.
 * These are the app's own timers; Apple's Clock timers are not observed.
 */

import Combine
import Foundation

/// One countdown, kept only in memory. Running timers count toward an end
/// date; paused timers keep their remaining time.
struct IslandTimer: Identifiable, Equatable {
    let id: UUID
    /// The length the timer was started with, in seconds.
    let duration: TimeInterval
    /// Set while running.
    private(set) var endDate: Date?
    /// Set while paused.
    private(set) var pausedRemaining: TimeInterval?

    init(id: UUID = UUID(), duration: TimeInterval, startedAt now: Date) {
        self.id = id
        self.duration = duration
        endDate = now.addingTimeInterval(duration)
    }

    var isPaused: Bool { pausedRemaining != nil }

    /// Seconds left, never negative.
    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(now))
    }

    /// 0 at the start, 1 when done.
    func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }

    mutating func pause(at now: Date) {
        guard !isPaused else { return }
        pausedRemaining = remaining(at: now)
        endDate = nil
    }

    mutating func resume(at now: Date) {
        guard let pausedRemaining else { return }
        endDate = now.addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
    }
}

/// A stopwatch counting up, with laps. Kept only in memory.
struct Stopwatch: Equatable {
    static let maximumLaps = 99

    /// Set while running.
    private(set) var startedAt: Date?
    /// Time counted before the current run.
    private(set) var accumulated: TimeInterval = 0
    /// Total elapsed at each lap, oldest first.
    private(set) var lapMarks: [TimeInterval] = []

    var isRunning: Bool { startedAt != nil }
    /// Running, or paused with time on it.
    var isActive: Bool { isRunning || accumulated > 0 }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Each lap's own length, oldest first.
    var lapLengths: [TimeInterval] {
        zip(lapMarks, [0] + lapMarks).map { $0 - $1 }
    }

    mutating func start(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    mutating func pause(at now: Date) {
        guard startedAt != nil else { return }
        accumulated = elapsed(at: now)
        startedAt = nil
    }

    mutating func lap(at now: Date) {
        guard isRunning, lapMarks.count < Self.maximumLaps else { return }
        let mark = elapsed(at: now)
        guard mark > (lapMarks.last ?? 0) else { return }
        lapMarks.append(mark)
    }

    mutating func reset() { self = Stopwatch() }
}

enum IslandTimers {
    static let maximumCount = 5
    static let presetMinutes = [1, 3, 5, 10, 15, 25, 30, 60]
    /// Custom lengths are whole minutes in this range.
    static let customMinutes = 1...180

    /// "4:59", "1:02:03"; rounds up so a timer never reads 0:00 while running.
    static func clockText(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.up))) : 0
        let hours = total / 3_600, minutes = total / 60 % 60, remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    /// "1:02.3", "1:02:03.4": tenths, rounded down so it never runs ahead.
    static func stopwatchText(_ seconds: TimeInterval) -> String {
        let tenths = seconds.isFinite ? max(0, Int((seconds * 10).rounded(.down))) : 0
        let total = tenths / 10
        let hours = total / 3_600, minutes = total / 60 % 60, remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes, remainder, tenths % 10)
            : String(format: "%d:%02d.%d", minutes, remainder, tenths % 10)
    }

    /// Whole seconds for the small notch display: "1:02".
    static func stopwatchShortText(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3_600, minutes = total / 60 % 60, remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    /// "5 min", "1 hr", "1 hr 30 min".
    static func lengthText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }
}

/// Owns all timers for the feature switch. Time and scheduling are injected
/// so tests never wait on a real clock.
@MainActor
final class TimerController {
    struct Environment {
        var now: @MainActor () -> Date
        /// Calls the action once at (or soon after) the date.
        var schedule: @MainActor (Date, @escaping @MainActor () -> Void) -> AnyCancellable
    }

    /// Oldest first.
    private(set) var timers: [IslandTimer] = []
    private(set) var stopwatch = Stopwatch()
    var onChange: (@MainActor () -> Void)?
    /// Called once per finished timer.
    var onFinish: (@MainActor (IslandTimer) -> Void)?

    private let environment: Environment
    private var wake: AnyCancellable?
    private var generation = 0

    init(environment: Environment) {
        self.environment = environment
    }

    var canAdd: Bool { timers.count < IslandTimers.maximumCount }

    /// The timer to show beside the notch: the running one finishing first,
    /// otherwise the most recent paused one.
    var featured: IslandTimer? {
        let now = environment.now()
        return timers.filter { !$0.isPaused }.min { $0.remaining(at: now) < $1.remaining(at: now) }
            ?? timers.last
    }

    @discardableResult
    func start(seconds: TimeInterval) -> Bool {
        guard canAdd, seconds.isFinite, seconds >= 1, seconds <= 24 * 3_600 else { return false }
        timers.append(IslandTimer(duration: seconds, startedAt: environment.now()))
        changed()
        return true
    }

    func pause(_ id: UUID) { update(id) { $0.pause(at: environment.now()) } }
    func resume(_ id: UUID) { update(id) { $0.resume(at: environment.now()) } }

    func cancel(_ id: UUID) {
        guard timers.contains(where: { $0.id == id }) else { return }
        timers.removeAll { $0.id == id }
        changed()
    }

    func startStopwatch() { changeStopwatch { $0.start(at: environment.now()) } }
    func pauseStopwatch() { changeStopwatch { $0.pause(at: environment.now()) } }
    func lapStopwatch() { changeStopwatch { $0.lap(at: environment.now()) } }
    func resetStopwatch() { changeStopwatch { $0.reset() } }

    /// Feature off or app quitting: cancels every timer and the wake-up and
    /// resets the stopwatch.
    func stop() {
        generation += 1
        wake?.cancel()
        wake = nil
        guard !timers.isEmpty || stopwatch != Stopwatch() else { return }
        timers = []
        stopwatch = Stopwatch()
        onChange?()
    }

    private func changeStopwatch(_ change: (inout Stopwatch) -> Void) {
        let before = stopwatch
        change(&stopwatch)
        if stopwatch != before { onChange?() }
    }

    /// Finishes anything due, e.g. after the Mac wakes from sleep.
    func reconcile() {
        let now = environment.now()
        let due = timers.filter { !$0.isPaused && $0.remaining(at: now) <= 0 }
        if !due.isEmpty {
            timers.removeAll { timer in due.contains { $0.id == timer.id } }
        }
        schedule()
        if !due.isEmpty { onChange?() }
        for timer in due { onFinish?(timer) }
    }

    private func update(_ id: UUID, _ change: (inout IslandTimer) -> Void) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        let before = timers[index]
        change(&timers[index])
        if timers[index] != before { changed() }
    }

    private func changed() {
        schedule()
        onChange?()
    }

    /// One wake-up at the earliest running end date.
    private func schedule() {
        generation += 1
        wake?.cancel()
        wake = nil
        guard let next = timers.compactMap(\.endDate).min() else { return }
        let session = generation
        wake = environment.schedule(next) { [weak self] in
            guard let self, session == self.generation else { return }
            self.reconcile()
        }
    }
}
