/*
 * Personal Island — incoming-call indicator model and lifecycle.
 * Written for this personal project; no upstream file copied.
 *
 * macOS has no public API for observing calls, so the platform side looks
 * for macOS's own incoming-call banner through Accessibility. The island only
 * shows that a call is ringing; answering stays in macOS's banner.
 */

import Combine
import Foundation

/// What the island shows while a call rings. Kept only in memory.
struct IncomingCall: Equatable {
    /// The caller's first name when macOS's banner exposes it.
    let callerFirstName: String?
}

enum IncomingCallStatus: Equatable {
    case off
    /// Accessibility permission is needed to see macOS's call banner.
    case needsAccess
    case watching
    case ringing(IncomingCall)
}

enum IncomingCalls {
    /// How often the banner is re-checked: often while ringing (to notice
    /// the end), rarely otherwise (notifications are the main trigger).
    static let ringingCheckInterval: TimeInterval = 1
    static let idleCheckInterval: TimeInterval = 5

    /// The caller's first name from the banner's description, e.g.
    /// "Name Surname, FaceTime Audio" or "Name Surname\nfrom iPhone".
    /// Control characters are removed and the result is bounded; anything
    /// that looks like a number or service label gives no name.
    static func callerFirstName(fromDescription description: String?) -> String? {
        guard let description else { return nil }
        var cleaned = ""
        for scalar in description.unicodeScalars {
            cleaned.unicodeScalars.append(CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" ? " " : scalar)
        }
        guard let first = cleaned.split(whereSeparator: { $0 == "\n" || $0 == "," }).first else { return nil }
        let name = first.trimmingCharacters(in: .whitespaces)
        let serviceWords = ["facetime", "incoming", "call", "audio", "video", "iphone"]
        guard !name.isEmpty, !name.contains(where: \.isNumber),
              !serviceWords.contains(where: { name.lowercased().hasPrefix($0) }),
              let firstWord = name.split(separator: " ").first else { return nil }
        return String(firstWord.prefix(20))
    }
}

/// Watches for incoming calls while the switch is on. Platform access is
/// injected so tests never use Accessibility or see real notifications.
@MainActor
final class IncomingCallController {
    struct Environment {
        var isTrusted: @MainActor () -> Bool
        /// Shows macOS's Accessibility prompt if it was never answered.
        var requestTrust: @MainActor () -> Void
        /// The banner's description when a call banner is showing, "" when
        /// it shows without a description, nil when no call is ringing.
        var findCallBanner: @MainActor () -> String?
        /// Calls the handler when Notification Center's windows change.
        var observe: @MainActor (_ handler: @escaping @MainActor () -> Void) -> AnyObject?
        var stopObserving: @MainActor (AnyObject) -> Void
        var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable
    }

    private(set) var status: IncomingCallStatus = .off
    var onChange: (@MainActor () -> Void)?

    private let environment: Environment
    private var observation: AnyObject?
    private var timer: AnyCancellable?
    private var isRunning = false
    private var generation = 0

    init(environment: Environment) {
        self.environment = environment
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        if !environment.isTrusted() { environment.requestTrust() }
        check()
    }

    /// Stops watching and forgets any ringing call.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        timer?.cancel()
        timer = nil
        if let observation { environment.stopObserving(observation) }
        observation = nil
        set(.off)
    }

    /// Re-checks now, e.g. after Notification Center changed.
    func check() {
        guard isRunning else { return }
        guard environment.isTrusted() else {
            if let observation { environment.stopObserving(observation) }
            observation = nil
            set(.needsAccess)
            // Permission granted later in System Settings is picked up here.
            reschedule(after: IncomingCalls.idleCheckInterval)
            return
        }
        if observation == nil {
            let session = generation
            observation = environment.observe { [weak self] in
                guard let self, session == self.generation else { return }
                self.check()
            }
        }
        if let description = environment.findCallBanner() {
            set(.ringing(IncomingCall(callerFirstName: IncomingCalls.callerFirstName(fromDescription: description))))
            reschedule(after: IncomingCalls.ringingCheckInterval)
        } else {
            set(.watching)
            reschedule(after: IncomingCalls.idleCheckInterval)
        }
    }

    private func reschedule(after seconds: TimeInterval) {
        timer?.cancel()
        let session = generation
        timer = environment.schedule(seconds) { [weak self] in
            guard let self, session == self.generation else { return }
            self.check()
        }
    }

    private func set(_ next: IncomingCallStatus) {
        guard next != status else { return }
        status = next
        onChange?()
    }
}
