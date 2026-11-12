/*
 * Personal Island — region-capture lifecycle.
 * Written for this personal project; no upstream file copied.
 */

import CoreGraphics
import Foundation

/// Coordinates one on-demand region capture at a time. Platform work is
/// injected so the lifecycle — permission gating, hiding/restoring islands,
/// cancellation and failure — is testable without a GUI or permissions.
@MainActor
final class CaptureFlow {
    enum Phase: Equatable { case idle, selecting, capturing }

    enum Outcome: Equatable {
        case captured
        case cancelled
        /// Another capture is already running; this request did nothing.
        case busy
        /// Screen Recording access is missing; the system request was shown.
        case permissionNeeded
        case failed(Failure)
    }

    enum Failure: Equatable {
        case capture
        case shelfFull
        case shelfUnavailable
    }

    struct Environment {
        var hasPermission: @MainActor () -> Bool
        var requestPermission: @MainActor () -> Void
        var hideIslands: @MainActor () -> Void
        var restoreIslands: @MainActor () -> Void
        /// Shows the selection UI; returns an AppKit global rect or nil.
        var selectRegion: @MainActor () async -> CGRect?
        var cancelSelection: @MainActor () -> Void
        /// Returns validated PNG bytes for an AppKit global rect.
        var captureRegion: @MainActor (CGRect) async throws -> Data
        var admit: @MainActor (Data) async throws -> Void
        var classify: @MainActor (any Error) -> Failure = { _ in .capture }
    }

    private(set) var phase: Phase = .idle
    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    func run() async -> Outcome {
        guard phase == .idle else { return .busy }
        guard environment.hasPermission() else {
            environment.requestPermission()
            return .permissionNeeded
        }
        phase = .selecting
        environment.hideIslands()
        defer {
            phase = .idle
            environment.restoreIslands()
        }
        guard let region = await environment.selectRegion() else { return .cancelled }
        phase = .capturing
        do {
            let png = try await environment.captureRegion(region)
            try await environment.admit(png)
            return .captured
        } catch {
            return .failed(environment.classify(error))
        }
    }

    /// Ends an in-progress selection (Escape, app stop). A capture that has
    /// already started completes or fails on its own.
    func cancel() {
        guard phase == .selecting else { return }
        environment.cancelSelection()
    }
}
