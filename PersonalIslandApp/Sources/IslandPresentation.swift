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
        isExpanded.toggle()
        onExpansionChange?()
    }

    func collapse() {
        cancelPendingInteraction()
        openedByHover = false
        guard isExpanded else { return }
        isExpanded = false
        onExpansionChange?()
    }

    func hoverChanged(_ inside: Bool, enabled: Bool) {
        cancelPendingInteraction()
        guard enabled else { return }
        if inside, !isExpanded {
            scheduleInteraction(after: 250_000_000) { [weak self] in
                guard let self else { return }
                self.openedByHover = true
                self.isExpanded = true
                self.onExpansionChange?()
            }
        } else if !inside, isExpanded, openedByHover {
            scheduleInteraction(after: 500_000_000) { [weak self] in
                self?.collapse()
            }
        }
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
