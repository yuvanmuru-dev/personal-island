/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 * Personal Island adaptations from Ebullioscopic/Atoll commit
 * b8d86a2d8118d905ffa3e2c912adc736683741bb,
 * DynamicIsland/components/Notch/DynamicIslandWindow.swift:
 * independent nonactivating panels, explicit display layout and shared model;
 * removed upstream screen-capture/defaults registration and global services.
 */

import AppKit
import SwiftUI

@MainActor
final class IslandPanelController {
    private let panel: IslandPanel
    private let presentation: IslandPresentation
    private let hostingView: IslandTrackingHostingView
    private var currentScreen: NSScreen
    private var hoverEnabled: Bool
    private var isHoverTrackingActive = false
    private var isUpdatingFrame = false

    init(screen: NSScreen, coordinator: IslandCoordinator) {
        currentScreen = screen
        let layout = Self.layout(for: screen)
        hoverEnabled = coordinator.expandOnHover
        presentation = IslandPresentation(layout: layout)
        panel = IslandPanel(contentRect: layout.panelFrame(expanded: false))
        hostingView = IslandTrackingHostingView(
            rootView: IslandView(coordinator: coordinator, presentation: presentation)
        )
        panel.contentView = hostingView
        hostingView.onPointerReconciliation = { [weak self] inside in
            guard let self, self.isHoverTrackingActive else { return }
            self.presentation.hoverChanged(inside, enabled: self.hoverEnabled)
        }
        presentation.onExpansionChange = { [weak self, weak coordinator] in
            guard let self else { return }
            guard self.updateFrame() else { return }
            if self.presentation.isExpanded { coordinator?.islandDidExpand() }
        }
    }

    func update(screen: NSScreen) {
        currentScreen = screen
        updateFrame()
    }

    func show() {
        guard updateFrame() else { return }
        panel.orderFrontRegardless()
        isHoverTrackingActive = true
        hostingView.setHoverTrackingActive(true)
        hostingView.reconcilePointer()
    }

    /// Briefly opens this display's shelf, e.g. after a capture.
    func peek() {
        guard isHoverTrackingActive, panel.isVisible else { return }
        presentation.peek()
    }

    /// Keeps the shelf open during an outgoing drag. On release, the pointer
    /// position is re-read first because tracking events pause during a drag.
    func setHeld(_ held: Bool) {
        if !held { hostingView.reconcilePointer() }
        presentation.setHeld(held)
    }

    func setHoverEnabled(_ enabled: Bool) {
        hoverEnabled = enabled
        if isHoverTrackingActive {
            // A setting can change while the pointer is stationary. Deliver
            // the current position with the new preference immediately.
            hostingView.reconcilePointer()
        } else {
            presentation.suspendHover()
        }
    }

    func hide() {
        isHoverTrackingActive = false
        hostingView.setHoverTrackingActive(false)
        presentation.suspendHover()
        panel.orderOut(nil)
    }

    func close() {
        isHoverTrackingActive = false
        hostingView.setHoverTrackingActive(false)
        hostingView.onPointerReconciliation = nil
        presentation.onExpansionChange = nil
        presentation.suspendHover()
        panel.orderOut(nil)
        panel.close()
    }

    @discardableResult
    private func updateFrame() -> Bool {
        // A no-space layout suspends expansion, which can call back here while
        // hiding. Keep that lifecycle transition finite and leave tracking off.
        guard !isUpdatingFrame else { return presentation.layout.hasUsableArea }
        isUpdatingFrame = true
        defer { isUpdatingFrame = false }

        // Read the current public screen/status-bar inputs on every show,
        // expansion and display update, rather than preserving startup metrics.
        let layout = Self.layout(for: currentScreen)
        if layout != presentation.layout { presentation.update(layout: layout) }
        guard layout.hasUsableArea else {
            hide()
            return false
        }
        let frame = layout.panelFrame(expanded: presentation.isExpanded)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        // AppKit need not receive a fresh mouse event when a stationary
        // pointer changes containment because the panel has resized.
        hostingView.reconcilePointer()
        return true
    }

    private static func layout(for screen: NSScreen) -> IslandGeometry.Layout {
        IslandGeometry.layout(for: IslandGeometry.Display(
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            menuBarHeight: NSStatusBar.system.thickness
        ))
    }
}

/// This host keeps its identity across compact/expanded SwiftUI branches. Its
/// own tracking area is independent of SwiftUI content reconstruction and
/// remains active while another application has keyboard focus.
@MainActor
private final class IslandTrackingHostingView: NSHostingView<IslandView> {
    var onPointerReconciliation: ((Bool) -> Void)?
    private var ownTrackingArea: NSTrackingArea?
    private var isHoverTrackingActive = false

    func setHoverTrackingActive(_ active: Bool) {
        guard isHoverTrackingActive != active else { return }
        isHoverTrackingActive = active
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        // NSHostingView maintains tracking areas for its controls too. Never
        // remove those or replace button hit testing with an overlay view.
        super.updateTrackingAreas()
        if !isHoverTrackingActive {
            if let ownTrackingArea { removeTrackingArea(ownTrackingArea) }
            ownTrackingArea = nil
            return
        }
        if let ownTrackingArea,
           !trackingAreas.contains(where: { $0 === ownTrackingArea }) {
            self.ownTrackingArea = nil
        }
        guard ownTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        ownTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        reconcilePointer()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        reconcilePointer()
    }

    func reconcilePointer() {
        guard isHoverTrackingActive, let window, window.isVisible else { return }
        // This borderless host fills the panel. Use the actual window frame so
        // reconciliation does not wait for SwiftUI's content transition/layout
        // after a resize. Both values are AppKit screen points, including
        // displays with negative origins.
        // The compact notch window touches the top of the display, where the
        // pointer can rest exactly on the frame's maxY. CGRect.contains
        // excludes that edge, so include it explicitly.
        let frame = window.frame
        let point = NSEvent.mouseLocation
        let inside = frame.contains(point)
            || (point.y == frame.maxY && point.x >= frame.minX && point.x < frame.maxX)
        onPointerReconciliation?(inside)
    }
}

@MainActor
private final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        isReleasedWhenClosed = false
        hasShadow = false
        // Above status items, so an expanded island draws over the menu bar
        // while open. Menus that are opened still appear above it.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // The compact notch content is visually empty. Without this, the window
        // server could pass clicks through its transparent pixels.
        ignoresMouseEvents = false
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .stationary]
        acceptsMouseMovedEvents = true
        setAccessibilityLabel("Personal Island")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
