/*
 * Personal Island — AppKit drag source for shelf tiles.
 * Written for this personal project; no upstream file copied.
 */

import AppKit
import PersonalIslandCore
import SwiftUI

/// A transparent AppKit view placed over a tile's thumbnail. A click selects;
/// a drag asks the coordinator to prepare file representations and then
/// starts a native drag carrying a file URL plus PNG data for each item.
struct ShelfDragSource: NSViewRepresentable {
    let itemID: ShelfItemID
    let coordinator: IslandCoordinator

    func makeNSView(context: Context) -> ShelfDragSourceView {
        ShelfDragSourceView(itemID: itemID, coordinator: coordinator)
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        view.itemID = itemID
    }
}

@MainActor
final class ShelfDragSourceView: NSView, NSDraggingSource {
    var itemID: ShelfItemID
    private weak var coordinator: IslandCoordinator?
    private var mouseDownEvent: NSEvent?
    private var latestDragEvent: NSEvent?
    private var dragRequested = false
    private static let dragThreshold: CGFloat = 3

    init(itemID: ShelfItemID, coordinator: IslandCoordinator) {
        self.itemID = itemID
        self.coordinator = coordinator
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        latestDragEvent = nil
        dragRequested = false
    }

    override func mouseDragged(with event: NSEvent) {
        latestDragEvent = event
        guard !dragRequested, let start = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x,
                             event.locationInWindow.y - start.locationInWindow.y)
        guard distance >= Self.dragThreshold, let coordinator else { return }
        dragRequested = true
        coordinator.beginShelfDrag(from: itemID) { [weak self] session, images, pngData in
            self?.startDragging(session, images: images, pngData: pngData) ?? false
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            latestDragEvent = nil
        }
        if dragRequested {
            // Only meaningful while the drag is still being prepared.
            coordinator?.shelfDragMouseReleased()
        } else {
            coordinator?.toggleShelfSelection(itemID)
        }
    }

    private func startDragging(
        _ session: PersonalIslandCore.DragSession,
        images: [ShelfItemID: NSImage],
        pngData: [ShelfItemID: Data]
    ) -> Bool {
        // The export can finish after the user has already let go.
        guard NSEvent.pressedMouseButtons & 1 == 1,
              let event = latestDragEvent ?? mouseDownEvent,
              window != nil else { return false }
        let origin = convert(event.locationInWindow, from: nil)
        var draggingItems: [NSDraggingItem] = []
        for (offset, item) in session.items.enumerated() {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)
            // Image data alongside the file lets destinations that prefer
            // pasted images use it; the in-memory copy avoids a disk read.
            if let data = pngData[item.itemID] {
                pasteboardItem.setData(data, forType: .png)
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let image = images[item.itemID] ?? NSWorkspace.shared.icon(for: .png)
            let size = Self.dragImageSize(for: image)
            let stagger = CGFloat(min(offset, 3)) * 6
            draggingItem.setDraggingFrame(
                CGRect(x: origin.x - size.width / 2 + stagger, y: origin.y - size.height / 2 - stagger,
                       width: size.width, height: size.height),
                contents: image
            )
            draggingItems.append(draggingItem)
        }
        guard !draggingItems.isEmpty else { return false }
        let draggingSession = beginDraggingSession(with: draggingItems, event: event, source: self)
        draggingSession.animatesToStartingPositionsOnCancelOrFail = true
        draggingSession.draggingFormation = .pile
        return true
    }

    private static func dragImageSize(for image: NSImage) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: 64, height: 64) }
        let scale = min(1, 96 / max(size.width, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    // MARK: NSDraggingSource

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Destinations receive a copy; the shelf item stays for repeated drags.
        context == .outsideApplication ? .copy : []
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        MainActor.assumeIsolated {
            dragRequested = false
            coordinator?.shelfDragEnded()
        }
    }
}
