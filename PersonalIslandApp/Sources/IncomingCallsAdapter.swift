/*
 * Personal Island — incoming-call banner watcher (Accessibility).
 * Written for this personal project; no upstream file copied.
 */

import AppKit
import ApplicationServices
import Combine

/// Real platform access for `IncomingCallController`. With Accessibility
/// permission it observes Notification Center and looks for macOS's
/// incoming-call banner, which macOS marks with the identifier
/// FACETIME_NOTIFICATION (found with a diagnostic probe on macOS 27). The
/// banner's description is used only to show the caller's first name; it is
/// never logged or stored. Nothing is clicked or changed.
@MainActor
enum IncomingCallsAdapter {
    nonisolated static let notificationCenterID = "com.apple.notificationcenterui"
    static let callBannerIdentifier = "FACETIME_NOTIFICATION"

    static func environment() -> IncomingCallController.Environment {
        IncomingCallController.Environment(
            isTrusted: { AXIsProcessTrusted() },
            requestTrust: {
                // The value of kAXTrustedCheckOptionPrompt.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            },
            findCallBanner: { findCallBanner() },
            observe: { handler in Observation(handler: handler) },
            stopObserving: { ($0 as? Observation)?.invalidate() },
            schedule: { delay, action in
                let timer = Timer(timeInterval: delay, repeats: false) { _ in
                    MainActor.assumeIsolated { action() }
                }
                timer.tolerance = delay / 4
                RunLoop.main.add(timer, forMode: .common)
                return AnyCancellable { timer.invalidate() }
            }
        )
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func notificationCenter() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterID).first else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func findCallBanner() -> String? {
        guard let root = notificationCenter() else { return nil }
        var visited = 0
        guard let banner = find(root, depth: 0, visited: &visited) else { return nil }
        return string(banner, kAXDescriptionAttribute)
            ?? attributedString(banner, "AXAttributedDescription")
            ?? ""
    }

    private static func find(_ element: AXUIElement, depth: Int, visited: inout Int) -> AXUIElement? {
        guard depth <= 14, visited < 400 else { return nil }
        visited += 1
        if string(element, kAXIdentifierAttribute) == callBannerIdentifier { return element }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let found = find(child, depth: depth + 1, visited: &visited) { return found }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func attributedString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSAttributedString)?.string
    }

    /// Notification Center window changes, re-attached if it restarts.
    @MainActor
    private final class Observation {
        private var observer: AXObserver?
        private var launchObserver: (any NSObjectProtocol)?
        private let handler: @MainActor () -> Void

        init(handler: @escaping @MainActor () -> Void) {
            self.handler = handler
            attach()
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == IncomingCallsAdapter.notificationCenterID else { return }
                MainActor.assumeIsolated {
                    self?.attach()
                    self?.handler()
                }
            }
        }

        private func attach() {
            detach()
            guard let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: IncomingCallsAdapter.notificationCenterID).first else { return }
            var created: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                let observation = Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { observation.handler() }
            }
            guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            let context = Unmanaged.passUnretained(self).toOpaque()
            for notification in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(created, element, notification as CFString, context)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            observer = created
        }

        private func detach() {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            observer = nil
        }

        func invalidate() {
            detach()
            if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
            launchObserver = nil
        }
    }
}
