import AppKit
import Combine
import Darwin
import Foundation
import PersonalIslandCore
import SwiftUI

@MainActor
final class IslandCoordinator: ObservableObject {
    static let shared = IslandCoordinator()

    struct DisplayOption: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let hasNotch: Bool
        let isEnabled: Bool
    }

    enum ShelfAvailability: Equatable {
        case notStarted
        case preparing
        case ready
        case unavailable
    }

    @Published private(set) var islandsVisible = true
    @Published var expandOnHover = false {
        didSet {
            guard expandOnHover != oldValue else { return }
            for presenter in presenters.values {
                presenter.setHoverEnabled(expandOnHover)
            }
        }
    }
    @Published private(set) var displays: [DisplayOption] = []
    @Published private(set) var shelfItems: [ShelfItem] = []
    @Published private(set) var shelfAvailability: ShelfAvailability = .notStarted
    /// Short status text, e.g. a capture failure. Never contains image data.
    @Published private(set) var shelfMessage: String?
    @Published private(set) var thumbnails: [ShelfItemID: NSImage] = [:]
    @Published private(set) var isCapturing = false
    /// Items a drag carries together. Order follows the shelf.
    @Published private(set) var selectedItemIDs: Set<ShelfItemID> = []
    @Published private(set) var captureShortcutRegistered = false
    /// Turning this off unregisters the shortcut immediately.
    @Published var captureShortcutEnabled = true {
        didSet {
            guard captureShortcutEnabled != oldValue else { return }
            updateCaptureShortcut()
        }
    }

    let captureShortcutName = GlobalHotKey.Combination.captureRegion.displayName

    private var disabledDisplays: Set<CGDirectDisplayID> = []
    private var presenters: [CGDirectDisplayID: IslandPanelController] = [:]
    private var screenObserver: (any NSObjectProtocol)?
    private var settingsWindowController: NSWindowController?
    private var coreStore: ShelfStore?
    private var coreInitialization: Task<ShelfStore, any Error>?
    private var isRunning = false
    private var cleanupTimer: Timer?
    private let regionSelector = RegionSelector()
    private lazy var captureShortcut = GlobalHotKey(.captureRegion) { [weak self] in
        self?.captureRegion()
    }
    private lazy var captureFlow = CaptureFlow(environment: CaptureFlow.Environment(
        hasPermission: { ScreenRegionCapture.hasPermission() },
        requestPermission: { ScreenRegionCapture.requestPermission() },
        hideIslands: { [weak self] in self?.setPresentersHiddenForCapture(true) },
        restoreIslands: { [weak self] in self?.setPresentersHiddenForCapture(false) },
        selectRegion: { [weak self] in await self?.regionSelector.select() },
        cancelSelection: { [weak self] in self?.regionSelector.cancel() },
        captureRegion: { region in try await ScreenRegionCapture.capture(region: region) },
        admit: { [weak self] png in
            guard let self else { throw CancellationError() }
            try await self.admitScreenshot(png)
        },
        classify: { error in
            switch error as? ShelfError {
            case .capacityExceeded?: .shelfFull
            case .some: .shelfUnavailable
            case nil: .capture
            }
        }
    ))
    private var hiddenForCapture = false
    private lazy var dragFlow = makeDragFlow()

    private func makeDragFlow() -> ShelfDragFlow<ShelfItemID, PersonalIslandCore.DragSession> {
        ShelfDragFlow(environment: .init(
            begin: { [weak self] ids in
                guard let self else { throw CancellationError() }
                return try await self.beginCoreDrag(ids)
            },
            end: { [weak self] session in
                try await self?.endCoreDrag(session)
            },
            hold: { [weak self] held in
                guard let self else { return }
                for presenter in self.presenters.values { presenter.setHeld(held) }
            },
            report: { [weak self] error in
                self?.shelfMessage = (error as? ShelfError) == .exportCapacityExceeded
                    ? "Too many temporary files are in use. Try again later."
                    : "The screenshot could not be prepared for dragging."
            }
        ))
    }

    private func beginCoreDrag(_ ids: [ShelfItemID]) async throws -> PersonalIslandCore.DragSession {
        guard let coreStore else { throw ShelfError.emptyDrag }
        return try await coreStore.beginFileDrag(itemIDs: ids)
    }

    private func endCoreDrag(_ session: PersonalIslandCore.DragSession) async throws {
        try await coreStore?.endDrag(session.id)
    }

    private static let cleanupInterval: TimeInterval = 30 * 60

    var shelfItemCount: Int { shelfItems.count }

    func start() {
        guard screenObserver == nil else { return }
        isRunning = true
        refreshDisplays()
        updateCaptureShortcut()
        startExportCleanup()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDisplays() }
        }
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        isRunning = false
        captureFlow.cancel()
        updateCaptureShortcut()
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        for presenter in presenters.values { presenter.close() }
        presenters.removeAll()
        coreInitialization?.cancel()
    }

    func setIslandsVisible(_ visible: Bool) {
        islandsVisible = visible
        refreshDisplays()
    }

    func setDisplayEnabled(_ id: CGDirectDisplayID, enabled: Bool) {
        if enabled {
            disabledDisplays.remove(id)
        } else {
            disabledDisplays.insert(id)
        }
        refreshDisplays()
    }

    func refreshDisplays() {
        let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (number.uint32Value, screen)
        }
        let connectedIDs = Set(screens.map(\.0))
        for id in Array(presenters.keys) where !connectedIDs.contains(id) {
            presenters.removeValue(forKey: id)?.close()
        }

        displays = screens.map { id, screen in
            DisplayOption(
                id: id,
                name: screen.localizedName,
                hasNotch: screen.safeAreaInsets.top > 0,
                isEnabled: !disabledDisplays.contains(id)
            )
        }

        for (id, screen) in screens {
            guard islandsVisible, !hiddenForCapture, !disabledDisplays.contains(id) else {
                presenters[id]?.hide()
                continue
            }
            if let presenter = presenters[id] {
                presenter.update(screen: screen)
                presenter.show()
            } else {
                let presenter = IslandPanelController(screen: screen, coordinator: self)
                presenters[id] = presenter
                presenter.show()
            }
        }
    }

    func showSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 550, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Personal Island"
            window.minSize = NSSize(width: 500, height: 460)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(coordinator: self))
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Capture

    /// Starts one region capture. Repeated requests while one is running are
    /// ignored. Screen Recording access is requested only from here.
    func captureRegion() {
        guard isRunning, !isCapturing else { return }
        isCapturing = true
        shelfMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.captureFlow.run()
            self.isCapturing = false
            self.handle(outcome)
        }
    }

    private func handle(_ outcome: CaptureFlow.Outcome) {
        switch outcome {
        case .captured:
            peekShelfOnPointerDisplay()
        case .cancelled, .busy:
            break
        case .permissionNeeded:
            shelfMessage = "Allow Personal Island under Screen Recording in System Settings, then quit and reopen it."
            peekShelfOnPointerDisplay()
        case .failed(.shelfFull):
            shelfMessage = "The shelf is full. Remove a screenshot to capture another."
            peekShelfOnPointerDisplay()
        case .failed(.shelfUnavailable):
            shelfMessage = "The temporary shelf is unavailable."
            peekShelfOnPointerDisplay()
        case .failed(.capture):
            shelfMessage = "The screenshot could not be taken."
            peekShelfOnPointerDisplay()
        }
    }

    private func setPresentersHiddenForCapture(_ hidden: Bool) {
        hiddenForCapture = hidden
        if hidden {
            for presenter in presenters.values { presenter.hide() }
        } else if isRunning {
            refreshDisplays()
        }
    }

    private func peekShelfOnPointerDisplay() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.screens.first
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        presenters[number.uint32Value]?.peek()
    }

    private func updateCaptureShortcut() {
        if isRunning && captureShortcutEnabled {
            captureShortcutRegistered = captureShortcut.register()
        } else {
            captureShortcut.unregister()
            captureShortcutRegistered = false
        }
    }

    // MARK: - Shelf

    func toggleShelfSelection(_ id: ShelfItemID) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    /// Drags the selection if the dragged tile is part of it, otherwise just
    /// that tile. `start` begins the platform drag once files are ready.
    func beginShelfDrag(
        from id: ShelfItemID,
        start: @escaping @MainActor (PersonalIslandCore.DragSession, [ShelfItemID: NSImage], [ShelfItemID: Data]) -> Bool
    ) {
        let ids = selectedItemIDs.contains(id)
            ? shelfItems.map(\.id).filter { selectedItemIDs.contains($0) }
            : [id]
        var pngData: [ShelfItemID: Data] = [:]
        for item in shelfItems where ids.contains(item.id) {
            if case .screenshot(let png) = item.payload { pngData[item.id] = png }
        }
        let images = thumbnails
        shelfMessage = nil
        Task { @MainActor [weak self] in
            await self?.dragFlow.request(ids) { session in start(session, images, pngData) }
        }
    }

    func shelfDragMouseReleased() { dragFlow.mouseReleasedBeforeStart() }

    func shelfDragEnded() {
        Task { @MainActor [weak self] in await self?.dragFlow.dragEnded() }
    }

    private func admitScreenshot(_ png: Data) async throws {
        let store = try await shelfStore()
        try await store.addScreenshot(encodedPNG: png)
        await refreshShelf(from: store)
    }

    func removeShelfItem(_ id: ShelfItemID) {
        guard let coreStore else { return }
        Task { @MainActor [weak self] in
            await coreStore.remove([id])
            await self?.refreshShelf(from: coreStore)
        }
    }

    /// Releases screenshot memory. Retained exports follow their grace period;
    /// original imported files are never touched.
    func clearShelf() {
        guard let coreStore else { return }
        shelfMessage = nil
        Task { @MainActor [weak self] in
            await coreStore.clear()
            await self?.refreshShelf(from: coreStore)
        }
    }

    /// Explicit user action: puts the image on the general pasteboard.
    func copyShelfItem(_ id: ShelfItemID) {
        guard let item = shelfItems.first(where: { $0.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        switch item.payload {
        case .screenshot(let png):
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        case .fileReference(let reference):
            pasteboard.clearContents()
            pasteboard.writeObjects([reference.url as NSURL])
        }
    }

    private func refreshShelf(from store: ShelfStore) async {
        let items = await store.snapshot().items
        var next: [ShelfItemID: NSImage] = [:]
        for item in items {
            if let existing = thumbnails[item.id] {
                next[item.id] = existing
            } else if case .screenshot(let png) = item.payload,
                      let image = ScreenRegionCapture.thumbnail(for: png) {
                next[item.id] = image
            }
        }
        shelfItems = items
        thumbnails = next
        selectedItemIDs.formIntersection(items.map(\.id))
    }

    // MARK: - Export cleanup

    /// Cleanup runs once the store opens at launch and then periodically while
    /// the app runs. It only removes expired files this app created.
    private func startExportCleanup() {
        prepareShelfIfNeeded()
        cleanupTimer?.invalidate()
        let timer = Timer(timeInterval: Self.cleanupInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepExports() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    private func sweepExports() {
        guard isRunning, let coreStore else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await coreStore.sweepExpiredExports()
            } catch {
                self?.shelfMessage = "Temporary file cleanup stopped because of unexpected files. Nothing was deleted."
            }
        }
    }

    /// The app shell initializes only its own export storage. No pasteboard,
    /// media, calendar, or network adapter is constructed; capture adapters
    /// run only on an explicit capture request.
    func prepareShelfIfNeeded(retry: Bool = false) {
        guard shelfAvailability == .notStarted || (retry && shelfAvailability == .unavailable) else { return }
        shelfAvailability = .preparing
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try await self.shelfStore()
                await self.refreshShelf(from: store)
                self.shelfAvailability = .ready
                self.sweepExports()
            } catch {
                self.shelfAvailability = .unavailable
            }
        }
    }

    private func shelfStore() async throws -> ShelfStore {
        if let coreStore { return coreStore }
        let task: Task<ShelfStore, any Error>
        if let coreInitialization {
            task = coreInitialization
        } else {
            task = Task.detached(priority: .utility) {
                let root = try Self.makeExportRoot()
                return try ShelfStore(exportRoot: root)
            }
            coreInitialization = task
        }
        do {
            let store = try await task.value
            coreStore = store
            return store
        } catch {
            coreInitialization = nil
            throw error
        }
    }

    nonisolated private static func makeExportRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalIsland", isDirectory: true)
        if mkdir(parent.path, 0o700) != 0, errno != EEXIST {
            throw ShelfError.storageFailure(operation: "create private app directory", code: errno)
        }
        var info = stat()
        guard lstat(parent.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700 else {
            throw ShelfError.invalidRoot
        }
        return parent.appendingPathComponent("Exports", isDirectory: true)
    }
}
