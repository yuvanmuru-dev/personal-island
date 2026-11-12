/*
 * Personal Island — shelf drag lifecycle.
 * Written for this personal project; no upstream file copied.
 */

import Foundation

/// Runs one outgoing drag at a time. Preparing a drag asks the core for file
/// representations (temporary PNG exports for screenshots); every prepared
/// session is ended exactly once — after the drop, a cancelled drag, or a
/// mouse release before the drag could start — so export protection renews
/// and later expires instead of leaking. Ending a drag never implies that a
/// destination finished an upload or a message was sent. Generic over the
/// core's item and session types so the lifecycle is testable on its own.
@MainActor
final class ShelfDragFlow<ItemID, Session> {
    enum Phase: Equatable { case idle, preparing, dragging }

    struct Environment {
        var begin: @MainActor ([ItemID]) async throws -> Session
        var end: @MainActor (Session) async throws -> Void
        /// Keeps the shelf open while a drag is being prepared or is active.
        var hold: @MainActor (Bool) -> Void
        var report: @MainActor (any Error) -> Void
    }

    private(set) var phase: Phase = .idle
    private var current: Session?
    private var releasedBeforeStart = false
    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    /// `start` begins the platform drag and returns false if it could not
    /// (for example, the mouse button is no longer down). Returns whether a
    /// platform drag is now running.
    @discardableResult
    func request(_ ids: [ItemID], start: @MainActor (Session) -> Bool) async -> Bool {
        guard phase == .idle, !ids.isEmpty else { return false }
        phase = .preparing
        releasedBeforeStart = false
        environment.hold(true)
        let session: Session
        do {
            session = try await environment.begin(ids)
        } catch {
            finish()
            environment.report(error)
            return false
        }
        guard !releasedBeforeStart, start(session) else {
            await close(session)
            return false
        }
        phase = .dragging
        current = session
        return true
    }

    /// The mouse was released while the drag was still being prepared.
    func mouseReleasedBeforeStart() {
        if phase == .preparing { releasedBeforeStart = true }
    }

    /// The platform drag ended, whether dropped or cancelled.
    func dragEnded() async {
        guard phase == .dragging, let session = current else { return }
        current = nil
        await close(session)
    }

    private func close(_ session: Session) async {
        do {
            try await environment.end(session)
        } catch {
            environment.report(error)
        }
        finish()
    }

    private func finish() {
        phase = .idle
        environment.hold(false)
    }
}
