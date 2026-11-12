/*
 * Personal Island — global capture shortcut.
 * Written for this personal project; no upstream file copied.
 */

import AppKit
import Carbon.HIToolbox

/// One system-wide shortcut registered with the Carbon hot-key API. This
/// receives only its own key combination; it does not observe other typing
/// and needs no Accessibility or Input Monitoring permission.
@MainActor
final class GlobalHotKey {
    struct Combination: Equatable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let displayName: String

        /// Control-Shift-4: mirrors macOS's Command-Shift-4 region capture.
        static let captureRegion = Combination(
            keyCode: UInt32(kVK_ANSI_4),
            carbonModifiers: UInt32(controlKey | shiftKey),
            displayName: "⌃⇧4"
        )
    }

    private let combination: Combination
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var isRegistered: Bool { hotKeyRef != nil }

    init(_ combination: Combination, action: @escaping @MainActor () -> Void) {
        self.combination = combination
        self.action = action
    }

    /// Returns false if another app already owns the combination.
    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var handler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), Self.handleEvent, 1, &eventType, userData, &handler
        )
        guard installStatus == noErr, let handler else { return false }

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            combination.keyCode, combination.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &reference
        )
        guard registerStatus == noErr, let reference else {
            RemoveEventHandler(handler)
            return false
        }
        handlerRef = handler
        hotKeyRef = reference
        return true
    }

    /// Stops receiving the shortcut. Safe to call repeatedly.
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    private func fire() { action() }

    private static let signature: OSType = 0x5049_736C // "PIsl"

    private static let handleEvent: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
            return OSStatus(eventNotHandledErr)
        }
        // The handler is removed before its owner is released (unregister in
        // the coordinator's stop and deinit paths), so the pointer is valid.
        let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in owner.fire() }
        return noErr
    }
}
