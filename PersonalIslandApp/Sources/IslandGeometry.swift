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
 * global managers. On a notched display the compact window is exactly the
 * camera housing, which macOS never fills with menus or status items. On other
 * displays the compact window is a small pill centered inside the menu bar.
 * Only the expanded state, opened by the user, extends over the menu bar,
 * and a short activity (e.g. charging) widens the compact island for a few
 * seconds beside the housing.
 */

import CoreGraphics

enum IslandGeometry {
    struct Display: Equatable {
        let frame: CGRect
        let safeAreaTop: CGFloat
        let auxiliaryTopLeft: CGRect?
        let auxiliaryTopRight: CGRect?
        /// AppKit layout points, including when the menu bar is auto-hidden.
        var menuBarHeight: CGFloat = 24
    }

    struct Layout: Equatable {
        let hasNotch: Bool
        /// Height of the camera housing; expanded content starts below it.
        let topContentInset: CGFloat
        let compactSize: CGSize
        /// The compact island widened for a short notice (e.g. charging):
        /// equal wings beside the camera housing, or a longer pill.
        let activitySize: CGSize
        let expandedSize: CGSize
        let displayFrame: CGRect
        let topEdge: CGFloat

        var hasUsableArea: Bool {
            compactSize.width > 0 && compactSize.height > 0
                && expandedSize.width > 0 && expandedSize.height > 0
        }

        /// Width of each side of the activity beside the compact island.
        var activityWingWidth: CGFloat { max(0, (activitySize.width - compactSize.width) / 2) }

        func panelFrame(expanded: Bool, activity: Bool = false) -> CGRect {
            let size = expanded ? expandedSize : activity ? activitySize : compactSize
            return CGRect(
                x: displayFrame.midX - size.width / 2,
                y: topEdge - size.height,
                width: size.width,
                height: size.height
            )
        }
    }

    /// Upper bound for a plausible camera-housing height in layout points.
    static let maximumNotchHeight: CGFloat = 64
    /// Fallback camera-housing width when public metadata is unusable.
    static let fallbackNotchWidth: CGFloat = 180
    /// Upper bound for a plausible camera-housing width in layout points.
    static let maximumNotchWidth: CGFloat = 320
    static let pillWidth: CGFloat = 84
    static let pillMaximumHeight: CGFloat = 22
    static let expandedWidth: CGFloat = 420
    static let expandedContentHeight: CGFloat = 228
    /// Each side of a notch activity. Kept inside the menu bar's empty
    /// center so it rarely reaches menu titles or status items.
    static let activityWingWidth: CGFloat = 64
    static let pillActivityWidth: CGFloat = 150

    static func layout(for display: Display) -> Layout {
        let frame = sanitizedFrame(display.frame)
        let maximumWidth = max(0, frame.width - min(24, frame.width / 2))
        let safeTop = positiveInset(display.safeAreaTop, limit: frame.height, fallback: 0)
        let hasNotch = safeTop > 0

        if hasNotch {
            // The window occupies only the physical camera housing, flush with
            // the top edge. Nothing is drawn there by macOS, so it can never
            // cover a menu title or status item.
            let notchHeight = min(safeTop, maximumNotchHeight)
            let notchWidth = min(maximumWidth, cameraHousingWidth(for: display, inside: frame))
            let expandedWidth = min(maximumWidth, max(Self.expandedWidth, notchWidth))
            return Layout(
                hasNotch: true,
                topContentInset: notchHeight,
                compactSize: CGSize(width: notchWidth, height: notchHeight),
                activitySize: CGSize(
                    width: min(maximumWidth, notchWidth + 2 * activityWingWidth),
                    height: notchHeight
                ),
                expandedSize: CGSize(
                    width: expandedWidth,
                    height: min(frame.height, expandedContentHeight + notchHeight)
                ),
                displayFrame: frame,
                topEdge: frame.maxY
            )
        }

        // Without a notch, keep the compact pill inside the menu bar row with
        // a small inset so it reads as a pill rather than a bar segment.
        let menuTop = positiveInset(display.menuBarHeight, limit: frame.height, fallback: 24)
        let inset = min(3, menuTop / 4)
        let topEdge = frame.maxY - inset
        let pillHeight = min(pillMaximumHeight, max(0, menuTop - 2 * inset))
        return Layout(
            hasNotch: false,
            topContentInset: 0,
            compactSize: CGSize(width: min(pillWidth, maximumWidth), height: pillHeight),
            activitySize: CGSize(width: min(pillActivityWidth, maximumWidth), height: pillHeight),
            expandedSize: CGSize(
                width: min(Self.expandedWidth, maximumWidth),
                height: min(expandedContentHeight, max(0, topEdge - frame.minY))
            ),
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

    private static func cameraHousingWidth(for display: Display, inside frame: CGRect) -> CGFloat {
        if let left = display.auxiliaryTopLeft, let right = display.auxiliaryTopRight,
           isFinitePositiveRect(left), isFinitePositiveRect(right),
           left.width <= frame.width, right.width <= frame.width,
           left.height <= frame.height, right.height <= frame.height {
            let occupiedWidth = left.width + right.width
            if occupiedWidth.isFinite, occupiedWidth < frame.width {
                let width = frame.width - occupiedWidth
                if width <= maximumNotchWidth { return width }
            }
        }
        return min(fallbackNotchWidth, frame.width)
    }
}
