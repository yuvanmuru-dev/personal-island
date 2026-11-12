/*
 * Personal Island
 * Notch measurements adapted from Atoll (DynamicIsland),
 * Copyright (C) 2024-2026 Atoll Contributors.
 * Originally from boring.notch; see the retained NOTICE.
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
 * Source: Ebullioscopic/Atoll, commit
 * b8d86a2d8118d905ffa3e2c912adc736683741bb,
 * DynamicIsland/sizing/matters.swift, getClosedNotchSize.
 * Adaptations: pure inputs, explicit per-display coordinates, no Defaults or
 * global managers; both presentations keep their entire window below the menu
 * band. Camera width is metadata, not reserved interactive space.
 */

import CoreGraphics

enum IslandGeometry {
    struct Display: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
        let safeAreaTop: CGFloat
        let auxiliaryTopLeft: CGRect?
        let auxiliaryTopRight: CGRect?
        /// AppKit layout points, including when the menu bar is auto-hidden.
        var menuBarHeight: CGFloat = 24
    }

    struct Layout: Equatable {
        let hasNotch: Bool
        let cameraHousingWidth: CGFloat
        let topContentInset: CGFloat
        let protectedTopInset: CGFloat
        let compactSize: CGSize
        let expandedSize: CGSize
        let displayFrame: CGRect
        let topEdge: CGFloat

        var hasUsableArea: Bool {
            compactSize.width > 0 && compactSize.height > 0
                && expandedSize.width > 0 && expandedSize.height > 0
        }

        func panelFrame(expanded: Bool) -> CGRect {
            let size = expanded ? expandedSize : compactSize
            return CGRect(
                x: displayFrame.midX - size.width / 2,
                y: topEdge - size.height,
                width: size.width,
                height: size.height
            )
        }
    }

    static func layout(for display: Display) -> Layout {
        let frame = sanitizedFrame(display.frame)
        let maximumWidth = max(0, frame.width - min(24, frame.width / 2))
        let safeTop = positiveInset(display.safeAreaTop, limit: frame.height, fallback: 0)
        let menuTop = positiveInset(display.menuBarHeight, limit: frame.height, fallback: 24)
        let visibleTop = visibleTopInset(display.visibleFrame, inside: frame)
        let protectedTopInset = max(max(safeTop, visibleTop), menuTop)
        let hasNotch = safeTop > 0
        let cameraWidth = hasNotch ? cameraHousingWidth(for: display, inside: frame) : 0

        // Protect the actual window rectangle, not just its painted controls.
        // Even an auto-hidden menu bar keeps its explicit band reserved. If that
        // band consumes a tiny/invalid display, there is no usable panel area.
        let remainingHeight = max(0, frame.height - protectedTopInset)
        let floatingMargin = hasNotch ? 0 : min(8, remainingHeight / 2)
        let topEdge = min(frame.maxY, max(frame.minY, frame.maxY - protectedTopInset - floatingMargin))
        let maximumHeight = max(0, topEdge - frame.minY)

        let compact = CGSize(
            width: min(maximumWidth, max(164, min(240, cameraWidth))),
            height: min(34, maximumHeight)
        )
        let expanded = CGSize(
            width: min(420, maximumWidth),
            height: min(228, maximumHeight)
        )
        return Layout(
            hasNotch: hasNotch,
            cameraHousingWidth: cameraWidth,
            topContentInset: 0,
            protectedTopInset: protectedTopInset,
            compactSize: compact,
            expandedSize: expanded,
            displayFrame: frame,
            topEdge: topEdge
        )
    }

    private static func positiveInset(_ value: CGFloat, limit: CGFloat, fallback: CGFloat) -> CGFloat {
        let usable = value.isFinite && value > 0 ? value : fallback
        return min(limit, usable)
    }

    private static func isFinitePositiveRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func sanitizedFrame(_ frame: CGRect) -> CGRect {
        guard isFinitePositiveRect(frame) else {
            return CGRect(
                x: frame.origin.x.isFinite ? frame.origin.x : 0,
                y: frame.origin.y.isFinite ? frame.origin.y : 0,
                width: 0, height: 0
            )
        }
        return frame
    }

    private static func visibleTopInset(_ visible: CGRect, inside frame: CGRect) -> CGFloat {
        guard isFinitePositiveRect(visible) else { return 0 }
        // Compare before subtracting to avoid overflow in malformed metadata.
        if visible.maxY >= frame.maxY { return 0 }
        if visible.maxY <= frame.minY { return frame.height }
        return frame.maxY - visible.maxY
    }

    private static func cameraHousingWidth(for display: Display, inside frame: CGRect) -> CGFloat {
        if let left = display.auxiliaryTopLeft, let right = display.auxiliaryTopRight,
           isFinitePositiveRect(left), isFinitePositiveRect(right),
           left.width <= frame.width, right.width <= frame.width,
           left.height <= frame.height, right.height <= frame.height {
            let occupiedWidth = left.width + right.width
            if occupiedWidth.isFinite, occupiedWidth < frame.width {
                return frame.width - occupiedWidth
            }
        }
        return min(180, frame.width)
    }
}
