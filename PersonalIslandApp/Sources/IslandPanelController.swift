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

    init(screen: NSScreen, coordinator: IslandCoordinator) {
        let layout = Self.layout(for: screen)
        presentation = IslandPresentation(layout: layout)
        panel = IslandPanel(contentRect: layout.panelFrame(expanded: false))
        panel.contentView = NSHostingView(
            rootView: IslandView(coordinator: coordinator, presentation: presentation)
        )
        presentation.onExpansionChange = { [weak self, weak coordinator] in
            guard let self else { return }
            self.updateFrame()
            if self.presentation.isExpanded { coordinator?.prepareShelfIfNeeded() }
        }
    }

    func update(screen: NSScreen) {
        presentation.update(layout: Self.layout(for: screen))
        updateFrame()
    }

    func show() { panel.orderFrontRegardless() }

    func hide() {
        presentation.collapse()
        panel.orderOut(nil)
    }

    func close() {
        presentation.cancelPendingInteraction()
        presentation.onExpansionChange = nil
        panel.orderOut(nil)
        panel.close()
    }

    private func updateFrame() {
        panel.setFrame(
            presentation.layout.panelFrame(expanded: presentation.isExpanded),
            display: true
        )
    }

    private static func layout(for screen: NSScreen) -> IslandGeometry.Layout {
        IslandGeometry.layout(for: IslandGeometry.Display(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        ))
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
        level = .statusBar
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .stationary]
        acceptsMouseMovedEvents = true
        setAccessibilityLabel("Personal Island")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
