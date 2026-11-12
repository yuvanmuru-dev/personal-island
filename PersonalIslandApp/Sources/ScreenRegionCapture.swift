/*
 * Personal Island — on-demand region capture adapter.
 * Written for this personal project; no upstream file copied.
 */

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures one rectangle or one window on request with ScreenCaptureKit and
/// encodes it as PNG in memory. Nothing is written to disk or the pasteboard, global
/// screenshot preferences are untouched, and no stream keeps recording.
enum ScreenRegionCapture {
    enum CaptureError: Error {
        case invalidRegion
        case windowUnavailable
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

    @MainActor
    static func capture(_ target: CaptureTarget) async throws -> Data {
        switch target {
        case .region(let region): try await capture(region: region)
        case .window(let id): try await capture(windowID: id)
        }
    }

    /// Captures one window on its own, without windows that overlap it, at
    /// its display's full pixel density. The window must still be on screen.
    /// Deliberately not main-actor isolated: ScreenCaptureKit's shareable
    /// content is not Sendable in older SDKs (Xcode 16.4 in CI), so it is
    /// fetched and used here and only the encoded PNG crosses back.
    nonisolated static func capture(windowID: CGWindowID) async throws -> Data {
        try await Task.sleep(for: .milliseconds(80))
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try encodePNG(image)
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
