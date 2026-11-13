/*
 * Personal Island — open-at-login model.
 * Written for this personal project; no upstream file copied.
 */

import Foundation

/// What macOS reports for the app's login item. macOS is the source of
/// truth, so the switch never shows a remembered value that may be stale.
enum LoginItemState: Equatable {
    case off
    case on
    /// Registered, but the user must allow it in System Settings › Login Items.
    case needsApproval
    /// macOS cannot find the app to register (for example, it was moved).
    case unavailable
}

/// Turns opening at login on and off. Platform access is injected so tests
/// never register a real login item.
@MainActor
final class LoginItemController {
    struct Environment {
        var state: @MainActor () -> LoginItemState
        var register: @MainActor () throws -> Void
        var unregister: @MainActor () throws -> Void
    }

    private(set) var state: LoginItemState
    /// Short text when the last change failed; cleared by the next success.
    private(set) var message: String?
    var onChange: (@MainActor () -> Void)?

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
        state = environment.state()
    }

    /// Whether the switch shows on: approval pending still counts, so the
    /// switch does not flip back while the user approves it.
    var isOn: Bool { state == .on || state == .needsApproval }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isOn else { return refresh() }
        do {
            if enabled { try environment.register() } else { try environment.unregister() }
            message = nil
        } catch {
            message = enabled ? "macOS didn't allow opening at login." : "macOS didn't remove the login item."
        }
        refresh(force: true)
    }

    /// Re-reads macOS's state, e.g. when Settings opens or after approval.
    func refresh(force: Bool = false) {
        let next = environment.state()
        guard force || next != state else { return }
        state = next
        onChange?()
    }
}
