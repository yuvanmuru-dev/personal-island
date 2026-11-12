/*
 * Personal Island — IOKit power-source adapter (read-only).
 * Written for this personal project; no upstream file copied.
 */

import Foundation
import IOKit.ps

/// Real platform access for `BatteryController`. Reads the public power-source
/// information that macOS also shows in the menu bar; needs no permission and
/// changes nothing. The run-loop source exists only while the switch is on.
@MainActor
enum BatteryAdapter {
    static func environment() -> BatteryController.Environment {
        BatteryController.Environment(
            read: { read() },
            observe: { handler in Observation(handler: handler) },
            stopObserving: { ($0 as? Observation)?.invalidate() }
        )
    }

    static func read() -> PowerSnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let snapshot = PowerSnapshot(description: description) else { continue }
            return snapshot
        }
        return nil
    }

    /// Delivers IOKit power-source notifications on the main run loop.
    @MainActor
    private final class Observation {
        private var source: CFRunLoopSource?
        private var box: Unmanaged<HandlerBox>?

        init?(handler: @escaping @MainActor () -> Void) {
            let box = Unmanaged.passRetained(HandlerBox(handler))
            let callback: IOPowerSourceCallbackType = { context in
                guard let context else { return }
                let box = Unmanaged<HandlerBox>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { box.handler() }
            }
            guard let source = IOPSNotificationCreateRunLoopSource(callback, box.toOpaque())?.takeRetainedValue() else {
                box.release()
                return nil
            }
            self.source = source
            self.box = box
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        func invalidate() {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                CFRunLoopSourceInvalidate(source)
            }
            source = nil
            box?.release()
            box = nil
        }
    }

    private final class HandlerBox {
        let handler: @MainActor () -> Void
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    }
}
