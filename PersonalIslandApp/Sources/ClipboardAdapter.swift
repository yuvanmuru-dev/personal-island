/*
 * Personal Island — clipboard adapter.
 * Written for this personal project; no upstream file copied.
 */

import AppKit
import Combine
import ImageIO

/// Real clipboard access for `ClipboardController`. The change count and the
/// list of types are read without showing macOS's paste alert; contents are
/// read only after checking that the copy is not marked concealed/transient.
@MainActor
enum ClipboardAdapter {
    static func environment() -> ClipboardController.Environment {
        ClipboardController.Environment(
            changeCount: { NSPasteboard.general.changeCount },
            access: { access() },
            read: { read() },
            write: { write($0) },
            frontmostApp: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
                return app.localizedName
            },
            now: { Date() },
            repeating: { interval, action in
                let timer = Timer(timeInterval: interval, repeats: true) { _ in
                    MainActor.assumeIsolated { action() }
                }
                timer.tolerance = interval / 2
                RunLoop.main.add(timer, forMode: .common)
                return AnyCancellable { timer.invalidate() }
            }
        )
    }

    static func access() -> ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch NSPasteboard.general.accessBehavior {
        case .default: return .notAsked
        case .alwaysAllow: return .allowed
        case .ask: return .asksEachTime
        case .alwaysDeny: return .denied
        @unknown default: return .asksEachTime
        }
    }

    static func read() -> ClipboardRead {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        if ClipboardHistory.isSkipped(types: types) { return .skipped }
        let typeSet = Set(types)

        if typeSet.contains(NSPasteboard.PasteboardType.fileURL.rawValue),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .content(.files(urls))
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] where typeSet.contains(type.rawValue) {
            guard let data = pasteboard.data(forType: type) else { continue }
            let size = pixelSize(data)
            return .content(.image(data, width: size.width, height: size.height))
        }
        if let text = pasteboard.string(forType: .string) {
            return .content(ClipboardHistory.content(fromText: text))
        }
        return .unsupported
    }

    static func write(_ content: ClipboardContent) -> Int? {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let written: Bool
        switch content {
        case .text(let text):
            written = pasteboard.setString(text, forType: .string)
        case .link(let url):
            written = pasteboard.setString(url.absoluteString, forType: .string)
                && pasteboard.setString(url.absoluteString, forType: .URL)
        case .image(let data, _, _):
            written = pasteboard.setData(data, forType: ClipboardHistory.isPNG(data) ? .png : .tiff)
        case .files(let urls):
            written = pasteboard.writeObjects(urls.map { $0 as NSURL })
        }
        return written ? pasteboard.changeCount : nil
    }

    private static func pixelSize(_ data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return (0, 0) }
        return (width, height)
    }

    /// Thumbnail for list rows, decoded once per item by the caller.
    static func thumbnail(_ data: Data, maximumPixels: Int = 96) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
