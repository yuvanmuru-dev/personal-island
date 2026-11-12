/*
 * Personal Island — window selection for capture.
 * Written for this personal project; no upstream file copied.
 */

import CoreGraphics
import Foundation

/// What the capture overlay selected.
enum CaptureTarget: Equatable {
    /// AppKit global points. A whole display is a region equal to its frame.
    case region(CGRect)
    /// A single window, captured on its own even when others overlap it.
    case window(CGWindowID)
}

/// Pure window hit-testing over the public on-screen window list. Only window
/// numbers, owners, layers, opacity and bounds are read; window titles and
/// contents are not needed to choose a window.
enum WindowPicker {
    struct Window: Equatable {
        let id: CGWindowID
        let ownerPID: Int32
        let layer: Int
        let alpha: Double
        /// Core Graphics global points (origin top-left of the primary display).
        let bounds: CGRect
    }

    /// Smaller windows are usually invisible helpers, not something to capture.
    static let minimumSide: CGFloat = 24

    /// Parses `CGWindowListCopyWindowInfo` entries, keeping their front-to-back
    /// order and skipping malformed ones.
    static func windows(from entries: [[String: Any]]) -> [Window] {
        entries.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  let boundsEntry = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = rect(from: boundsEntry),
                  number.int64Value > 0, number.int64Value <= Int64(UInt32.max) else { return nil }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return Window(
                id: CGWindowID(number.int64Value), ownerPID: pid.int32Value,
                layer: layer.intValue, alpha: alpha, bounds: bounds
            )
        }
    }

    /// The frontmost ordinary, visible window of another process containing
    /// `point` (Core Graphics global points). `windows` is front-to-back.
    static func frontmost(at point: CGPoint, in windows: [Window], excludingPID: Int32) -> Window? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return windows.first { window in
            window.layer == 0 && window.ownerPID != excludingPID
                && window.alpha > 0.01
                && window.bounds.width >= minimumSide && window.bounds.height >= minimumSide
                && window.bounds.contains(point)
        }
    }

    private static func rect(from entry: [String: Any]) -> CGRect? {
        guard let x = (entry["X"] as? NSNumber)?.doubleValue,
              let y = (entry["Y"] as? NSNumber)?.doubleValue,
              let width = (entry["Width"] as? NSNumber)?.doubleValue,
              let height = (entry["Height"] as? NSNumber)?.doubleValue,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
