import Combine
import Foundation

/// A short notice shown beside the notch.
enum IslandActivity: Equatable {
    case battery(BatteryActivity)
    /// A countdown reached zero; its original length in seconds.
    case timerDone(duration: TimeInterval)
    /// An AirDrop finished arriving.
    case airDropReceived

    /// How long the notice stays, in nanoseconds.
    var displayDuration: UInt64 {
        switch self {
        case .battery: IslandPresentation.activityDuration
        case .timerDone: 8_000_000_000
        case .airDropReceived: 4_000_000_000
        }
    }
}

/// UI-independent state shared by a single display presenter. The scheduler is
/// injectable so cancellation and pointer/click races can be tested without
/// wall-clock sleeps, application windows, or global input monitoring.
@MainActor
final class IslandPresentation: ObservableObject {
    typealias Scheduler = @MainActor (
        _ nanoseconds: UInt64,
        _ action: @escaping @MainActor () -> Void
    ) -> AnyCancellable

    @Published private(set) var isExpanded = false
    @Published private(set) var layout: IslandGeometry.Layout
    /// A short notice shown in the widened compact island. Never shown while
    /// the island is open; opening it ends the notice.
    @Published private(set) var activity: IslandActivity?
    /// Something ongoing (a running timer) keeps the compact island widened
    /// when no notice is showing.
    @Published private(set) var showsLive = false
    var onExpansionChange: (() -> Void)?
    /// Called when a notice starts or ends, so the window can resize.
    var onActivityChange: (() -> Void)?

    private let scheduler: Scheduler
    private var pendingInteraction: AnyCancellable?
    private var activityTimer: AnyCancellable?
    private var activityID: UUID?
    private var pendingID: UUID?
    private var openedByHover = false
    private var openedByPeek = false
    private(set) var isHeld = false
    private var pointerInside = false
    private var hoverEnabled = false

    // A short dwell avoids opening on an incidental pass; a slightly longer
    // exit grace lets the pointer cross an edge without flickering the shelf.
    private static let openDelay: UInt64 = 80_000_000
    private static let closeDelay: UInt64 = 120_000_000
    /// How long a peek (e.g. after a capture) stays open without interaction.
    static let peekDuration: UInt64 = 3_000_000_000
    /// How long a notice such as "charging" stays beside the notch.
    nonisolated static let activityDuration: UInt64 = 3_000_000_000

    init(layout: IslandGeometry.Layout, scheduler: Scheduler? = nil) {
        self.layout = layout
        self.scheduler = scheduler ?? { nanoseconds, action in
            Self.scheduleAfter(nanoseconds, action: action)
        }
    }

    func update(layout: IslandGeometry.Layout) { self.layout = layout }

    func toggle() {
        cancelPendingInteraction()
        openedByHover = false
        openedByPeek = false
        isExpanded.toggle()
        if isExpanded { endActivity() }
        onExpansionChange?()
    }

    func collapse() {
        cancelPendingInteraction()
        openedByHover = false
        openedByPeek = false
        guard isExpanded else { return }
        isExpanded = false
        onExpansionChange?()
    }

    func hoverChanged(_ inside: Bool, enabled: Bool) {
        // Tracking-area updates and window resizing can repeat the same input.
        // Those callbacks must not extend an already scheduled deadline.
        guard inside != pointerInside || enabled != hoverEnabled else { return }
        pointerInside = inside
        hoverEnabled = enabled
        // A drag from the shelf keeps it open; release re-evaluates the
        // pointer and setting that were recorded meanwhile.
        if isHeld { return }
        cancelPendingInteraction()
        if openedByPeek {
            // A peek is held open while the pointer is on it, whatever the
            // hover setting, and closes shortly after the pointer leaves.
            if !inside {
                scheduleInteraction(after: Self.closeDelay) { [weak self] in self?.collapse() }
            }
            return
        }
        guard enabled else {
            if openedByHover { collapse() }
            return
        }
        if inside, !isExpanded {
            scheduleInteraction(after: Self.openDelay) { [weak self] in
                guard let self else { return }
                self.openedByHover = true
                self.isExpanded = true
                self.endActivity()
                self.onExpansionChange?()
            }
        } else if !inside, isExpanded, openedByHover {
            scheduleInteraction(after: Self.closeDelay) { [weak self] in
                self?.collapse()
            }
        }
    }

    /// Briefly opens the shelf to acknowledge an event such as a capture. It
    /// never disturbs a shelf that is already open, closes by itself unless
    /// the pointer is on it, and a click or Escape closes it like any other.
    func peek(for nanoseconds: UInt64 = IslandPresentation.peekDuration) {
        guard !isExpanded else { return }
        cancelPendingInteraction()
        openedByHover = false
        openedByPeek = true
        isExpanded = true
        endActivity()
        onExpansionChange?()
        guard !pointerInside else { return }
        scheduleInteraction(after: nanoseconds) { [weak self] in self?.collapse() }
    }

    /// While held (an outgoing drag), pointer exit and hover changes do not
    /// close the shelf. On release, an automatically opened shelf closes if
    /// the pointer is outside or hover was turned off meanwhile; a manually
    /// opened shelf stays open.
    func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        if held {
            cancelPendingInteraction()
            return
        }
        guard isExpanded else { return }
        if openedByHover && !hoverEnabled {
            collapse()
        } else if !pointerInside && (openedByHover || openedByPeek) {
            scheduleInteraction(after: Self.closeDelay) { [weak self] in self?.collapse() }
        }
    }

    /// Hidden/disconnected panels must not retain pending work or an old
    /// pointer-inside value that could suppress the next genuine entry.
    func suspendHover() {
        isHeld = false
        pointerInside = false
        hoverEnabled = false
        collapse()
        endActivity()
    }

    /// Shows a notice for a few seconds. A newer notice replaces the current
    /// one and restarts the timer. Ignored while the island is open.
    func showActivity(_ activity: IslandActivity, for nanoseconds: UInt64? = nil) {
        guard !isExpanded else { return }
        let nanoseconds = nanoseconds ?? activity.displayDuration
        activityTimer?.cancel()
        let id = UUID()
        activityID = id
        let changed = !isWidened
        self.activity = activity
        activityTimer = scheduler(nanoseconds) { [weak self] in
            guard let self, self.activityID == id else { return }
            self.endActivity()
        }
        if changed { onActivityChange?() }
    }

    /// Whether the compact island currently uses the wider activity frame.
    var isWidened: Bool { !isExpanded && (activity != nil || showsLive) }

    func setLive(_ live: Bool) {
        guard live != showsLive else { return }
        let before = isWidened
        showsLive = live
        if isWidened != before { onActivityChange?() }
    }

    func endActivity() {
        activityTimer?.cancel()
        activityTimer = nil
        activityID = nil
        guard activity != nil else { return }
        let before = isWidened
        activity = nil
        if isWidened != before { onActivityChange?() }
    }

    func cancelPendingInteraction() {
        pendingID = nil
        pendingInteraction?.cancel()
        pendingInteraction = nil
    }

    private func scheduleInteraction(after nanoseconds: UInt64, action: @escaping @MainActor () -> Void) {
        let id = UUID()
        pendingID = id
        pendingInteraction = scheduler(nanoseconds) { [weak self] in
            // Cancellation can race delivery. A stale callback must not open
            // or close a newer manual/hover presentation even if delivered.
            guard let self, self.pendingID == id else { return }
            self.pendingID = nil
            self.pendingInteraction = nil
            action()
        }
    }

    private static func scheduleAfter(
        _ nanoseconds: UInt64,
        action: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        let task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return AnyCancellable { task.cancel() }
    }
}
