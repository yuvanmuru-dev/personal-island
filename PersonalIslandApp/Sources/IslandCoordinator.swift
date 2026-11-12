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

    private var disabledDisplays: Set<CGDirectDisplayID> = []
    private var presenters: [CGDirectDisplayID: IslandPanelController] = [:]
    private var screenObserver: (any NSObjectProtocol)?
    private var settingsWindowController: NSWindowController?
    private var coreStore: ShelfStore?
    private var coreInitialization: Task<ShelfStore, any Error>?

    var shelfItemCount: Int { shelfItems.count }

    func start() {
        guard screenObserver == nil else { return }
        refreshDisplays()
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
            guard islandsVisible, !disabledDisplays.contains(id) else {
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

    /// The app shell initializes only its own export storage, on demand. No
    /// capture, pasteboard, media, calendar, or network adapter is constructed.
    func prepareShelfIfNeeded(retry: Bool = false) {
        guard shelfAvailability == .notStarted || (retry && shelfAvailability == .unavailable) else { return }
        shelfAvailability = .preparing
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try await self.shelfStore()
                self.shelfItems = await store.snapshot().items
                self.shelfAvailability = .ready
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
