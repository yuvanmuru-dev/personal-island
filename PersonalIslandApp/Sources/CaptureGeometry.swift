/*
 * Personal Island — region-selection geometry.
 * Written for this personal project; no upstream file copied.
 */

import CoreGraphics

/// Pure coordinate math for region capture. AppKit reports global points with
/// the origin at the bottom-left of the primary display and y increasing
/// upwards. ScreenCaptureKit's `captureImage(in:)` takes Core Graphics global
/// display points, with the origin at the top-left of the primary display and
/// y increasing downwards. Both use points, not pixels.
enum CaptureGeometry {
    /// Selections smaller than this in either dimension are treated as clicks.
    static let minimumSide: CGFloat = 4

    /// The rectangle spanned by two drag points, clamped to the display the
    /// drag started on. Returns nil for an accidental click or invalid input.
    static func selection(from start: CGPoint, to end: CGPoint, within display: CGRect) -> CGRect? {
        guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite), isUsable(display) else { return nil }
        let raw = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        let clamped = raw.intersection(display)
        guard !clamped.isNull, clamped.width >= minimumSide, clamped.height >= minimumSide else { return nil }
        return clamped.integral.intersection(display)
    }

    /// Converts an AppKit global rectangle to Core Graphics global display
    /// coordinates, using the primary display's AppKit frame.
    static func coreGraphicsRect(fromAppKit rect: CGRect, primaryDisplay: CGRect) -> CGRect? {
        guard isUsable(rect), isUsable(primaryDisplay) else { return nil }
        return CGRect(
            x: rect.minX,
            y: primaryDisplay.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Inverse of `coreGraphicsRect(fromAppKit:primaryDisplay:)`.
    static func appKitRect(fromCoreGraphics rect: CGRect, primaryDisplay: CGRect) -> CGRect? {
        guard isUsable(rect), isUsable(primaryDisplay) else { return nil }
        return CGRect(
            x: rect.minX,
            y: primaryDisplay.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The Core Graphics global point for an AppKit global point.
    static func coreGraphicsPoint(fromAppKit point: CGPoint, primaryDisplay: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, isUsable(primaryDisplay) else { return nil }
        return CGPoint(x: point.x, y: primaryDisplay.maxY - point.y)
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
