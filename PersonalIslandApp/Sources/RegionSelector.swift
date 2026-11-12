/*
 * Personal Island — region-selection overlay.
 * Written for this personal project; no upstream file copied.
 */

import AppKit

/// Shows a dimmed crosshair overlay on every display and returns the dragged
/// rectangle in AppKit global points. Escape, or a click without dragging,
/// cancels. The overlay panels do not activate the app, so the previously
/// focused app keeps its active state.
@MainActor
final class RegionSelector {
    private var panels: [SelectionPanel] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?

    func select() async -> CGRect? {
        guard continuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let pointer = NSEvent.mouseLocation
            for screen in NSScreen.screens {
                let panel = SelectionPanel(screen: screen) { [weak self] rect in
                    self?.finish(rect)
                }
                panels.append(panel)
                panel.orderFrontRegardless()
                if screen.frame.contains(pointer) { panel.makeKey() }
            }
            if panels.isEmpty { finish(nil) }
        }
    }

    /// Ends a selection in progress without a region. Safe to call repeatedly.
    func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        let open = panels
        panels = []
        for panel in open {
            panel.orderOut(nil)
            panel.close()
        }
        NSCursor.arrow.set()
        let pending = continuation
        continuation = nil
        pending?.resume(returning: rect)
    }
}

@MainActor
private final class SelectionPanel: NSPanel {
    init(screen: NSScreen, onFinish: @escaping @MainActor (CGRect?) -> Void) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        setFrame(screen.frame, display: false)
        contentView = SelectionView(displayFrame: screen.frame, onFinish: onFinish)
        setAccessibilityLabel("Select a region to capture. Press Escape to cancel.")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SelectionView: NSView {
    private let displayFrame: CGRect
    private let onFinish: @MainActor (CGRect?) -> Void
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(displayFrame: CGRect, onFinish: @escaping @MainActor (CGRect?) -> Void) {
        self.displayFrame = displayFrame
        self.onFinish = onFinish
        super.init(frame: CGRect(origin: .zero, size: displayFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragCurrent = dragStart
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = NSEvent.mouseLocation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else { return onFinish(nil) }
        let selection = CaptureGeometry.selection(
            from: dragStart, to: NSEvent.mouseLocation, within: displayFrame
        )
        self.dragStart = nil
        onFinish(selection)
    }

    override func rightMouseDown(with event: NSEvent) { onFinish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onFinish(nil) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let start = dragStart, let current = dragCurrent else { return }
        let global = CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        ).intersection(displayFrame)
        guard !global.isNull else { return }
        let local = global.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        NSColor.clear.setFill()
        local.fill(using: .copy)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: local.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let label = "\(Int(global.width)) × \(Int(global.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let origin = CGPoint(x: local.maxX - size.width - 6, y: max(local.minY - size.height - 6, 4))
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -2), xRadius: 4, yRadius: 4).fill()
        label.draw(at: origin, withAttributes: attributes)
    }
}
