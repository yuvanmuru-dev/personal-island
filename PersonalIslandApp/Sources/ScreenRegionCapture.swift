/*
 * Personal Island — on-demand region capture adapter.
 * Written for this personal project; no upstream file copied.
 */

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures one rectangle on request with ScreenCaptureKit and encodes it as
/// PNG in memory. Nothing is written to disk or the pasteboard, global
/// screenshot preferences are untouched, and no stream keeps recording.
enum ScreenRegionCapture {
    enum CaptureError: Error {
        case invalidRegion
        case encodingFailed
    }

    /// Does not prompt. Reflects the permission the running process holds.
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system request the first time. Once it has been answered,
    /// macOS no longer prompts, so open the Screen Recording settings pane
    /// instead. Nothing is changed there on the user's behalf.
    @MainActor
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// `region` is in AppKit global points.
    @MainActor
    static func capture(region: CGRect) async throws -> Data {
        guard let primary = NSScreen.screens.first?.frame,
              let rect = CaptureGeometry.coreGraphicsRect(fromAppKit: region, primaryDisplay: primary) else {
            throw CaptureError.invalidRegion
        }
        // Give the window server a moment to remove the selection overlay
        // and hidden islands from the composited screen.
        try await Task.sleep(for: .milliseconds(80))
        let image = try await SCScreenshotManager.captureImage(in: rect)
        return try encodePNG(image)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0 else { throw CaptureError.encodingFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw CaptureError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else {
            throw CaptureError.encodingFailed
        }
        return data as Data
    }

    /// A small preview for the shelf, decoded from the stored PNG.
    static func thumbnail(for png: Data, maximumPixelSize: Int = 240) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
