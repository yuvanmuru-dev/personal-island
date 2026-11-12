/*
 * Personal Island — capture-selection overlay.
 * Written for this personal project; no upstream file copied.
 */

import AppKit

/// Shows a dimmed overlay on every display. Drag selects a region; Space
/// toggles window mode, where a click selects the highlighted window; Return
/// selects the whole display under the pointer; Escape, a right-click or a
/// click without dragging (region mode) cancels. The overlay panels do not
/// activate the app, so the previously focused app keeps its active state.
@MainActor
final class RegionSelector {
    enum Mode { case region, window }

    private(set) var mode: Mode = .region
    private(set) var hoveredWindow: WindowPicker.Window?
    private var windows: [WindowPicker.Window] = []
    private var panels: [SelectionPanel] = []
    private var continuation: CheckedContinuation<CaptureTarget?, Never>?

    func select() async -> CaptureTarget? {
        guard continuation == nil else { return nil }
        mode = .region
        hoveredWindow = nil
        // Read the window list before the overlay exists, so it is not in it.
        // Only numbers, owners, layers, opacity and bounds are used.
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        windows = WindowPicker.windows(from: entries)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let pointer = NSEvent.mouseLocation
            for screen in NSScreen.screens {
                let panel = SelectionPanel(screen: screen, selector: self)
                panels.append(panel)
                panel.orderFrontRegardless()
                if screen.frame.contains(pointer) { panel.makeKey() }
            }
            if panels.isEmpty { finish(nil) }
        }
    }

    /// Ends a selection in progress without a target. Safe to call repeatedly.
    func cancel() { finish(nil) }

    fileprivate func finish(_ target: CaptureTarget?) {
        let open = panels
        panels = []
        windows = []
        hoveredWindow = nil
        for panel in open {
            panel.orderOut(nil)
            panel.close()
        }
        NSCursor.arrow.set()
        let pending = continuation
        continuation = nil
        pending?.resume(returning: target)
    }

    fileprivate func toggleMode() {
        mode = mode == .region ? .window : .region
        updateHover(at: NSEvent.mouseLocation)
        redraw()
    }

    fileprivate func selectDisplayUnderPointer() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return }
        finish(.region(screen.frame))
    }

    fileprivate func selectHoveredWindow() {
        guard mode == .window, let hoveredWindow else { return }
        finish(.window(hoveredWindow.id))
    }

    fileprivate func updateHover(at appKitPoint: CGPoint) {
        guard mode == .window else {
            if hoveredWindow != nil { hoveredWindow = nil; redraw() }
            return
        }
        let next = Self.primaryFrame.flatMap {
            CaptureGeometry.coreGraphicsPoint(fromAppKit: appKitPoint, primaryDisplay: $0)
        }.flatMap {
            WindowPicker.frontmost(at: $0, in: windows, excludingPID: ProcessInfo.processInfo.processIdentifier)
        }
        if next != hoveredWindow {
            hoveredWindow = next
            redraw()
        }
    }

    /// The hovered window's frame in AppKit global points, for highlighting.
    fileprivate var hoveredWindowFrame: CGRect? {
        guard let hoveredWindow, let primary = Self.primaryFrame else { return nil }
        return CaptureGeometry.appKitRect(fromCoreGraphics: hoveredWindow.bounds, primaryDisplay: primary)
    }

    private func redraw() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }

    private static var primaryFrame: CGRect? { NSScreen.screens.first?.frame }
}

@MainActor
private final class SelectionPanel: NSPanel {
    init(screen: NSScreen, selector: RegionSelector) {
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
        contentView = SelectionView(displayFrame: screen.frame, selector: selector)
        setAccessibilityLabel("Select what to capture. Drag for a region, Space for a window, Return for the whole screen, Escape to cancel.")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SelectionView: NSView {
    private let displayFrame: CGRect
    private weak var selector: RegionSelector?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(displayFrame: CGRect, selector: RegionSelector) {
        self.displayFrame = displayFrame
        self.selector = selector
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

    private var cursor: NSCursor { selector?.mode == .window ? .pointingHand : .crosshair }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func mouseMoved(with event: NSEvent) {
        cursor.set()
        selector?.updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        guard selector?.mode == .region else { return }
        dragStart = NSEvent.mouseLocation
        dragCurrent = dragStart
        cursor.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard selector?.mode == .region else { return }
        dragCurrent = NSEvent.mouseLocation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selector else { return }
        if selector.mode == .window {
            selector.selectHoveredWindow()
            return
        }
        guard let dragStart else { return selector.finish(nil) }
        let selection = CaptureGeometry.selection(
            from: dragStart, to: NSEvent.mouseLocation, within: displayFrame
        )
        self.dragStart = nil
        selector.finish(selection.map(CaptureTarget.region))
    }

    override func rightMouseDown(with event: NSEvent) { selector?.finish(nil) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: selector?.finish(nil)                       // Escape
        case 49:                                             // Space
            dragStart = nil
            dragCurrent = nil
            selector?.toggleMode()
            cursor.set()
        case 36, 76: selector?.selectDisplayUnderPointer()   // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { selector?.finish(nil) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if selector?.mode == .window {
            drawWindowHighlight()
        } else {
            drawRegionSelection()
        }
        drawHint()
    }

    private func drawRegionSelection() {
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
        drawLabel("\(Int(global.width)) × \(Int(global.height))",
                  at: CGPoint(x: local.maxX, y: local.minY), alignRight: true)
    }

    private func drawWindowHighlight() {
        guard let frame = selector?.hoveredWindowFrame else { return }
        let global = frame.intersection(displayFrame)
        guard !global.isNull else { return }
        let local = global.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        NSColor.clear.setFill()
        local.fill(using: .copy)
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        local.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
    }

    private func drawHint() {
        let hint = selector?.mode == .window
            ? "Click a window to capture it  ·  Space: region  ·  Return: whole screen  ·  Esc: cancel"
            : "Drag to capture a region  ·  Space: window  ·  Return: whole screen  ·  Esc: cancel"
        drawLabel(hint, at: CGPoint(x: bounds.midX, y: 28), centered: true)
    }

    private func drawLabel(_ text: String, at point: CGPoint, alignRight: Bool = false, centered: Bool = false) {
        let label = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        var origin = point
        if centered {
            origin.x -= size.width / 2
        } else if alignRight {
            origin = CGPoint(x: point.x - size.width - 6, y: max(point.y - size.height - 6, 4))
        }
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -3), xRadius: 5, yRadius: 5).fill()
        label.draw(at: origin, withAttributes: attributes)
    }
}
