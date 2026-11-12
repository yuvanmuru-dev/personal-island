import Combine
import Foundation

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
    var onExpansionChange: (() -> Void)?

    private let scheduler: Scheduler
    private var pendingInteraction: AnyCancellable?
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
