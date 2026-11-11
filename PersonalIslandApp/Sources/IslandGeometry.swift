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
 * global managers; separate attached-notch and floating-capsule placement.
 */

import CoreGraphics

enum IslandGeometry {
    struct Display: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
        let safeAreaTop: CGFloat
        let auxiliaryTopLeft: CGRect?
        let auxiliaryTopRight: CGRect?
    }

    struct Layout: Equatable {
        let hasNotch: Bool
        let reservedNotchWidth: CGFloat
        let topContentInset: CGFloat
        let compactSize: CGSize
        let expandedSize: CGSize
        let displayFrame: CGRect
        let topEdge: CGFloat

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
        let frame = display.frame
        let maximumWidth = max(0, frame.width - min(24, frame.width / 2))
        let topInset = max(0, min(display.safeAreaTop, 80))
        let hasNotch = topInset > 0
        // Size the panel to the available area below its actual top edge.
        // Moving that edge upwards to fit would overlap a floating menu bar.
        let availableTop = min(frame.maxY, display.visibleFrame.maxY)
        let floatingMargin = min(8, max(0, availableTop - frame.minY) / 2)
        let desiredTopEdge = hasNotch
            ? frame.maxY
            : availableTop - floatingMargin
        let topEdge = min(frame.maxY, max(frame.minY, desiredTopEdge))
        let maximumHeight = max(0, min(frame.height - min(16, frame.height / 2), topEdge - frame.minY))

        var notchWidth: CGFloat = 0
        if hasNotch {
            if let left = display.auxiliaryTopLeft, let right = display.auxiliaryTopRight {
                notchWidth = max(0, frame.width - left.width - right.width)
            }
            if notchWidth <= 0 { notchWidth = 180 }
            notchWidth = min(notchWidth, max(0, maximumWidth - 72))
        }

        let compact = CGSize(
            width: min(hasNotch ? notchWidth + 72 : 164, maximumWidth),
            height: min(hasNotch ? max(topInset, 32) : 34, maximumHeight)
        )
        let expanded = CGSize(
            width: min(420, maximumWidth),
            height: min(228 + (hasNotch ? topInset : 0), maximumHeight)
        )
        return Layout(
            hasNotch: hasNotch,
            reservedNotchWidth: notchWidth,
            topContentInset: hasNotch ? topInset : 0,
            compactSize: compact,
            expandedSize: expanded,
            displayFrame: frame,
            topEdge: topEdge
        )
    }
}
