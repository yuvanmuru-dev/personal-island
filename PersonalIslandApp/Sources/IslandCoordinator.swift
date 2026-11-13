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
            saveSettings()
            for presenter in presenters.values {
                presenter.setHoverEnabled(expandOnHover)
            }
        }
    }
    @Published private(set) var displays: [DisplayOption] = []
    /// Read from macOS, not remembered: System Settings can change it too.
    /// Shows a ringing call beside the notch. Turning it off stops watching
    /// Notification Center.
    @Published var callsEnabled = false {
        didSet {
            guard callsEnabled != oldValue else { return }
            saveSettings()
            updateCalls()
        }
    }
    @Published private(set) var callStatus: IncomingCallStatus = .off
    private lazy var calls: IncomingCallController = {
        let controller = IncomingCallController(environment: IncomingCallsAdapter.environment())
        controller.onChange = { [weak self, unowned controller] in
            self?.callStatusChanged(controller.status)
        }
        return controller
    }()
    @Published private(set) var loginItemState: LoginItemState = .off
    @Published private(set) var loginItemMessage: String?
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
            saveSettings()
            updateCaptureShortcut()
        }
    }

    let captureShortcutName = GlobalHotKey.Combination.captureRegion.displayName

    enum ExpandedTab: Equatable { case media, calendar, timers, transfers, stats, clipboard, shelf }

    /// Sections the open island offers, in display order.
    var availableTabs: [ExpandedTab] {
        (spotifyEnabled || allMediaEnabled ? [.media] : []) + (calendarEnabled ? [.calendar] : [])
            + (timersEnabled ? [.timers] : []) + (transfersEnabled ? [.transfers] : []) + (statsEnabled ? [.stats] : [])
            + (clipboardEnabled ? [.clipboard] : []) + [.shelf]
    }

    /// The section actually shown, falling back if its feature was turned off.
    var visibleTab: ExpandedTab {
        availableTabs.contains(expandedTab) ? expandedTab : .shelf
    }

    /// Turning this off stops all calendar observation and forgets events.
    @Published var calendarEnabled = false {
        didSet {
            guard calendarEnabled != oldValue else { return }
            saveSettings()
            updateCalendar(askAccess: calendarEnabled)
        }
    }
    @Published var hiddenCalendarIDs: Set<String> = [] {
        didSet {
            guard hiddenCalendarIDs != oldValue else { return }
            saveSettings()
            calendarController.hiddenCalendarIDs = hiddenCalendarIDs
        }
    }
    @Published private(set) var calendarStatus: CalendarStatus = .off
    @Published private(set) var todayEvents: [AgendaEvent] = []
    @Published private(set) var nextEvent: AgendaEvent?
    @Published private(set) var upcomingEvent: AgendaEvent?
    @Published private(set) var calendarEventDays: Set<Int> = []
    @Published private(set) var calendarMonthEvents: [AgendaEvent] = []
    @Published private(set) var calendarMonthOffset = 0
    @Published private(set) var calendarShownMonth: Date?
    @Published private(set) var calendars: [CalendarSummary] = []
    /// Which section the open island shows; shared by both displays.
    @Published var expandedTab: ExpandedTab = .shelf {
        didSet { if expandedTab != oldValue { updateStatsSampling() } }
    }
    /// Turning this off stops all Spotify observation and Apple Events.
    @Published var spotifyEnabled = false {
        didSet {
            guard spotifyEnabled != oldValue else { return }
            saveSettings()
            updateSpotify(askPermission: spotifyEnabled)
        }
    }
    /// Media from every app (browsers, Spotify, Music…) through the helper.
    /// Turning it off stops the helper process.
    @Published var allMediaEnabled = false {
        didSet {
            guard allMediaEnabled != oldValue else { return }
            saveSettings()
            updateAllMedia(selectTab: allMediaEnabled)
        }
    }
    @Published private(set) var mediaStatus: MediaStatus = .off
    @Published private(set) var mediaSessions: [MediaSession] = []
    private lazy var mediaController: MediaSessionsController = {
        let controller = MediaSessionsController(environment: MediaBridgeAdapter.environment())
        controller.onChange = { [weak self, unowned controller] in
            self?.mediaStatus = controller.status
            self?.mediaSessions = controller.sessions
        }
        return controller
    }()
    @Published private(set) var spotifyStatus: SpotifyStatus = .off
    @Published private(set) var nowPlaying: NowPlaying? {
        didSet { if nowPlaying?.trackID != oldValue?.trackID { updateArtwork() } }
    }
    /// The only network use: cover images from Spotify's image server.
    @Published var spotifyArtworkEnabled = false {
        didSet {
            guard spotifyArtworkEnabled != oldValue else { return }
            saveSettings()
            updateArtwork()
        }
    }
    /// The current track's cover, in memory only.
    @Published private(set) var artwork: NSImage?
    /// Turning this off removes the power-source observer and forgets readings.
    @Published var batteryEnabled = false {
        didSet {
            guard batteryEnabled != oldValue else { return }
            saveSettings()
            updateBattery()
        }
    }
    @Published var batteryLowAlerts = true {
        didSet {
            guard batteryLowAlerts != oldValue else { return }
            saveSettings()
            battery.lowAlertsEnabled = batteryLowAlerts
        }
    }
    @Published var batteryChargedAlert = true {
        didSet {
            guard batteryChargedAlert != oldValue else { return }
            saveSettings()
            battery.chargedAlertEnabled = batteryChargedAlert
        }
    }
    /// Turning this off cancels every timer and its wake-up.
    @Published var timersEnabled = false {
        didSet {
            guard timersEnabled != oldValue else { return }
            saveSettings()
            updateTimers(selectTab: timersEnabled)
        }
    }
    @Published var timerSound = true {
        didSet { if timerSound != oldValue { saveSettings() } }
    }
    @Published var timerInNotch = true {
        didSet {
            guard timerInNotch != oldValue else { return }
            saveSettings()
            applyTimerLive()
        }
    }
    /// Samples only while the Stats tab is on screen in an open island.
    @Published var statsEnabled = false {
        didSet {
            guard statsEnabled != oldValue else { return }
            saveSettings()
            if statsEnabled { expandedTab = .stats }
            if !statsEnabled && expandedTab == .stats { expandedTab = availableTabs.first ?? .shelf }
            updateStatsSampling()
        }
    }
    /// Turning this off stops watching the clipboard and forgets the history.
    @Published var clipboardEnabled = false {
        didSet {
            guard clipboardEnabled != oldValue else { return }
            saveSettings()
            updateClipboard(selectTab: clipboardEnabled)
        }
    }
    /// AirDrop progress. Turning this off stops following transfers (they
    /// continue in AirDrop) and forgets the list.
    @Published var transfersEnabled = false {
        didSet {
            guard transfersEnabled != oldValue else { return }
            saveSettings()
            updateTransfers(selectTab: transfersEnabled)
        }
    }
    @Published private(set) var transfers: [Transfer] = []
    var activeTransfers: [Transfer] { transfers.filter { $0.state == .active } }
    @Published private(set) var clipboardItems: [ClipboardItem] = []
    @Published private(set) var clipboardStatus: ClipboardStatus = .off
    @Published private(set) var clipboardThumbnails: [UUID: NSImage] = [:]
    @Published private(set) var stats: StatsReading?
    @Published private(set) var statsHistory = StatsHistory()
    @Published private(set) var timers: [IslandTimer] = []
    @Published private(set) var stopwatch = Stopwatch()
    var featuredTimer: IslandTimer? { timerController.featured }
    var canAddTimer: Bool { timersEnabled && timerController.canAdd }
    @Published private(set) var batteryStatus: BatteryStatus = .off
    @Published private(set) var power: PowerSnapshot?

    private var disabledDisplays: Set<CGDirectDisplayID> = []
    private let settingsStore: IslandSettingsStore

    init(settingsStore: IslandSettingsStore = .userDefaults()) {
        self.settingsStore = settingsStore
        let settings = settingsStore.read()
        islandsVisible = settings.islandsVisible
        expandOnHover = settings.expandOnHover
        captureShortcutEnabled = settings.captureShortcutEnabled
        disabledDisplays = Set(settings.disabledDisplays)
        spotifyEnabled = settings.spotifyEnabled
        allMediaEnabled = settings.allMediaEnabled
        spotifyArtworkEnabled = settings.spotifyArtworkEnabled
        calendarEnabled = settings.calendarEnabled
        hiddenCalendarIDs = Set(settings.hiddenCalendarIDs)
        batteryEnabled = settings.batteryEnabled
        timersEnabled = settings.timersEnabled
        statsEnabled = settings.statsEnabled
        clipboardEnabled = settings.clipboardEnabled
        transfersEnabled = settings.transfersEnabled
        callsEnabled = settings.callsEnabled
        timerSound = settings.timerSound
        timerInNotch = settings.timerInNotch
        batteryLowAlerts = settings.batteryLowAlerts
        batteryChargedAlert = settings.batteryChargedAlert
        expandedTab = settings.spotifyEnabled ? .media : settings.calendarEnabled ? .calendar : .shelf
    }

    private func saveSettings() {
        var settings = IslandSettings()
        settings.islandsVisible = islandsVisible
        settings.expandOnHover = expandOnHover
        settings.captureShortcutEnabled = captureShortcutEnabled
        settings.disabledDisplays = disabledDisplays.sorted()
        settings.spotifyEnabled = spotifyEnabled
        settings.allMediaEnabled = allMediaEnabled
        settings.spotifyArtworkEnabled = spotifyArtworkEnabled
        settings.calendarEnabled = calendarEnabled
        settings.hiddenCalendarIDs = hiddenCalendarIDs.sorted()
        settings.batteryEnabled = batteryEnabled
        settings.timersEnabled = timersEnabled
        settings.statsEnabled = statsEnabled
        settings.clipboardEnabled = clipboardEnabled
        settings.transfersEnabled = transfersEnabled
        settings.callsEnabled = callsEnabled
        settings.timerSound = timerSound
        settings.timerInNotch = timerInNotch
        settings.batteryLowAlerts = batteryLowAlerts
        settings.batteryChargedAlert = batteryChargedAlert
        settingsStore.write(settings)
    }
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
        selectTarget: { [weak self] in await self?.regionSelector.select() },
        cancelSelection: { [weak self] in self?.regionSelector.cancel() },
        capture: { target in try await ScreenRegionCapture.capture(target) },
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
    private let calendarAdapter = CalendarAdapter()
    private lazy var calendarController: CalendarController = {
        let controller = CalendarController(environment: calendarAdapter.environment())
        controller.hiddenCalendarIDs = hiddenCalendarIDs
        controller.onChange = { [weak self, unowned controller] in
            self?.calendarStatus = controller.status
            self?.todayEvents = controller.todayEvents
            self?.nextEvent = controller.nextEvent
            self?.upcomingEvent = controller.upcomingEvent
            self?.calendarEventDays = controller.eventDays
            self?.calendarMonthEvents = controller.monthEvents
            self?.calendarMonthOffset = controller.monthOffset
            self?.calendarShownMonth = controller.shownMonth
            self?.calendars = controller.calendars
        }
        return controller
    }()
    private lazy var spotify: SpotifyController = {
        let controller = SpotifyController(environment: SpotifyAdapter.environment())
        controller.onChange = { [weak self, unowned controller] in
            self?.spotifyStatus = controller.status
            self?.nowPlaying = controller.nowPlaying
        }
        return controller
    }()
    private lazy var artworkLoader: SpotifyArtworkLoader = {
        let loader = SpotifyArtworkLoader(environment: SpotifyAdapter.artworkEnvironment())
        loader.onChange = { [weak self, unowned loader] in
            // Decoded once here; undecodable data shows no artwork.
            self?.artwork = loader.imageData.flatMap { NSImage(data: $0) }
        }
        return loader
    }()
    private lazy var timerController: TimerController = {
        let controller = TimerController(environment: .init(
            now: { Date() },
            schedule: { date, action in
                let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
                    MainActor.assumeIsolated { action() }
                }
                timer.tolerance = 0.2
                RunLoop.main.add(timer, forMode: .common)
                return AnyCancellable { timer.invalidate() }
            }
        ))
        controller.onChange = { [weak self, unowned controller] in
            self?.timers = controller.timers
            self?.stopwatch = controller.stopwatch
            self?.applyTimerLive()
        }
        controller.onFinish = { [weak self] timer in self?.timerFinished(timer) }
        return controller
    }()
    private var timerWakeObserver: (any NSObjectProtocol)?
    private let transfersAdapter = TransfersAdapter()
    private lazy var transferController: TransferController = {
        let controller = TransferController(environment: transfersAdapter.environment())
        controller.onChange = { [weak self, unowned controller] in
            self?.transfers = controller.transfers
            self?.applyTimerLive()
        }
        controller.onFinish = { [weak self] _ in
            guard let self, !self.hiddenForCapture else { return }
            for presenter in self.presenters.values { presenter.showActivity(.airDropReceived) }
        }
        return controller
    }()
    private lazy var clipboard: ClipboardController = {
        let controller = ClipboardController(environment: ClipboardAdapter.environment())
        controller.onChange = { [weak self, unowned controller] in
            guard let self else { return }
            self.clipboardItems = controller.items
            self.clipboardStatus = controller.status
            var thumbnails: [UUID: NSImage] = [:]
            for item in controller.items {
                guard case .image(let data, _, _) = item.content else { continue }
                thumbnails[item.id] = self.clipboardThumbnails[item.id] ?? ClipboardAdapter.thumbnail(data)
            }
            self.clipboardThumbnails = thumbnails
        }
        return controller
    }()
    private lazy var statsController: StatsController = {
        let controller = StatsController(environment: SystemStatsAdapter.environment())
        controller.onChange = { [weak self, unowned controller] in
            self?.stats = controller.reading
            self?.statsHistory = StatsHistory(cpu: controller.cpuHistory, memory: controller.memoryHistory,
                                              network: controller.networkHistory, disk: controller.diskHistory)
        }
        return controller
    }()
    private lazy var loginItem: LoginItemController = {
        let controller = LoginItemController(environment: LoginItemAdapter.environment())
        controller.onChange = { [weak self, unowned controller] in
            self?.loginItemState = controller.state
            self?.loginItemMessage = controller.message
        }
        return controller
    }()
    private lazy var battery: BatteryController = {
        let controller = BatteryController(environment: BatteryAdapter.environment())
        controller.lowAlertsEnabled = batteryLowAlerts
        controller.chargedAlertEnabled = batteryChargedAlert
        controller.onChange = { [weak self, unowned controller] in
            self?.batteryStatus = controller.status
            self?.power = controller.snapshot
        }
        controller.onActivity = { [weak self] activity in
            guard let self, !self.hiddenForCapture else { return }
            for presenter in self.presenters.values { presenter.showActivity(.battery(activity)) }
        }
        return controller
    }()
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
        updateSpotify(askPermission: false)
        updateCalendar(askAccess: false)
        updateAllMedia(selectTab: false)
        updateBattery()
        updateTimers(selectTab: false)
        updateClipboard(selectTab: false)
        updateTransfers(selectTab: false)
        updateCalls()
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
        spotify.stop()
        artworkLoader.stop()
        mediaController.stop()
        calendarController.stop()
        battery.stop()
        calls.stop()
        updateTimers(selectTab: false)
        updateClipboard(selectTab: false)
        updateTransfers(selectTab: false)
        updateStatsSampling()
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
        saveSettings()
        refreshDisplays()
    }

    func setDisplayEnabled(_ id: CGDirectDisplayID, enabled: Bool) {
        if enabled {
            disabledDisplays.remove(id)
        } else {
            disabledDisplays.insert(id)
        }
        saveSettings()
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
                presenter.setLive(liveInNotch)
            }
        }
        updateStatsSampling()
    }

    var opensAtLogin: Bool { loginItem.isOn }

    /// Explicit user action from Settings only; never turned on automatically.
    func setOpensAtLogin(_ enabled: Bool) { loginItem.setEnabled(enabled) }

    func openLoginItemsSettings() { LoginItemAdapter.openLoginItemsSettings() }

    func showSettings() {
        loginItem.refresh(force: true)
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
            expandedTab = .shelf
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

    // MARK: - Media from all apps

    private func updateAllMedia(selectTab: Bool) {
        if isRunning && allMediaEnabled {
            if selectTab { expandedTab = .media }
            mediaController.start()
        } else {
            mediaController.stop()
            if expandedTab == .media && !spotifyEnabled { expandedTab = availableTabs.first ?? .shelf }
        }
    }

    func mediaCommand(_ command: MediaCommand, on id: String) { mediaController.perform(command, on: id) }
    func retryMedia() { mediaController.retry() }

    // MARK: - Spotify

    private func updateSpotify(askPermission: Bool) {
        if isRunning && spotifyEnabled {
            if askPermission { expandedTab = .media }
            Task { @MainActor [weak self] in await self?.spotify.start(askPermission: askPermission) }
        } else {
            spotify.stop()
            artworkLoader.stop()
            if expandedTab == .media && !allMediaEnabled { expandedTab = availableTabs.first ?? .shelf }
        }
    }

    private func updateArtwork() {
        if isRunning && spotifyEnabled && spotifyArtworkEnabled {
            artworkLoader.show(trackID: nowPlaying?.trackID)
        } else {
            artworkLoader.stop()
        }
    }

    func spotifyCommand(_ command: SpotifyCommand) {
        Task { @MainActor [weak self] in await self?.spotify.perform(command) }
    }

    /// Shows the system Automation prompt if macOS has not asked yet.
    func requestSpotifyPermission() {
        Task { @MainActor [weak self] in await self?.spotify.refresh(askPermission: true) }
    }

    /// Explicit user action only; the feature itself never launches Spotify.
    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyPlayback.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Re-reads the playback position when someone opens the island to look.
    func islandDidExpand() {
        prepareShelfIfNeeded()
        guard spotify.isActive, visibleTab == .media else { return }
        Task { @MainActor [weak self] in await self?.spotify.refresh() }
    }

    // MARK: - Incoming calls

    private func updateCalls() {
        if isRunning && callsEnabled { calls.start() } else { calls.stop() }
    }

    func openAccessibilitySettings() { IncomingCallsAdapter.openAccessibilitySettings() }

    private func callStatusChanged(_ status: IncomingCallStatus) {
        callStatus = status
        var notice: IslandActivity?
        if case .ringing(let call) = status { notice = .incomingCall(callerFirstName: call.callerFirstName) }
        for presenter in presenters.values { presenter.setStickyNotice(notice) }
    }

    // MARK: - AirDrop

    private func updateTransfers(selectTab: Bool) {
        if isRunning && transfersEnabled {
            if selectTab { expandedTab = .transfers }
            transferController.start()
        } else {
            transferController.stop()
            if expandedTab == .transfers { expandedTab = availableTabs.first ?? .shelf }
        }
        applyTimerLive()
    }

    func cancelTransfer(_ id: UUID) { transferController.cancel(id) }
    func clearRecentTransfers() { transferController.clearRecent() }
    func showTransferInFinder(_ transfer: Transfer) { TransfersAdapter.showInFinder(transfer) }

    // MARK: - Clipboard history

    private func updateClipboard(selectTab: Bool) {
        if isRunning && clipboardEnabled {
            if selectTab { expandedTab = .clipboard }
            clipboard.start()
        } else {
            clipboard.stop()
            if expandedTab == .clipboard { expandedTab = availableTabs.first ?? .shelf }
        }
    }

    func setClipboardPaused(_ paused: Bool) { clipboard.setPaused(paused) }
    func clearClipboard() { clipboard.clear() }
    func removeClipboardItem(_ id: UUID) { clipboard.remove(id) }
    @discardableResult
    func copyClipboardItem(_ id: UUID) -> Bool { clipboard.copyBack(id) }

    func openClipboardPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - System activity

    func islandExpansionChanged() { updateStatsSampling() }

    private func updateStatsSampling() {
        let visible = isRunning && statsEnabled && visibleTab == .stats
            && presenters.values.contains { $0.isExpanded }
        if visible { statsController.start() } else { statsController.stop() }
    }

    // MARK: - Timers

    private func updateTimers(selectTab: Bool) {
        if isRunning && timersEnabled {
            if selectTab { expandedTab = .timers }
            if timerWakeObserver == nil {
                // Timers keep counting during sleep; finish anything due on wake.
                timerWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.timerController.reconcile() }
                }
            }
        } else {
            if let timerWakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(timerWakeObserver)
                self.timerWakeObserver = nil
            }
            timerController.stop()
            if expandedTab == .timers { expandedTab = availableTabs.first ?? .shelf }
        }
        applyTimerLive()
    }

    func startTimer(minutes: Int) {
        guard isRunning, timersEnabled else { return }
        timerController.start(seconds: TimeInterval(minutes) * 60)
    }

    func startStopwatch() { if isRunning && timersEnabled { timerController.startStopwatch() } }
    func pauseStopwatch() { timerController.pauseStopwatch() }
    func lapStopwatch() { timerController.lapStopwatch() }
    func resetStopwatch() { timerController.resetStopwatch() }

    func pauseTimer(_ id: UUID) { timerController.pause(id) }
    func resumeTimer(_ id: UUID) { timerController.resume(id) }
    func cancelTimer(_ id: UUID) { timerController.cancel(id) }

    /// Something ongoing to show beside the notch: a transfer, a timer or a
    /// running stopwatch.
    private var liveInNotch: Bool {
        guard isRunning else { return false }
        let transfer = transfersEnabled && !activeTransfers.isEmpty
        let timer = timersEnabled && timerInNotch && (!timers.isEmpty || stopwatch.isRunning)
        return transfer || timer
    }

    private func applyTimerLive() {
        let live = liveInNotch
        for presenter in presenters.values { presenter.setLive(live) }
    }

    private func timerFinished(_ timer: IslandTimer) {
        if timerSound { NSSound(named: "Glass")?.play() }
        guard !hiddenForCapture else { return }
        for presenter in presenters.values { presenter.showActivity(.timerDone(duration: timer.duration)) }
    }

    // MARK: - Battery

    private func updateBattery() {
        if isRunning && batteryEnabled {
            battery.start()
        } else {
            battery.stop()
        }
    }

    // MARK: - Calendar

    private func updateCalendar(askAccess: Bool) {
        if isRunning && calendarEnabled {
            if askAccess { expandedTab = .calendar }
            Task { @MainActor [weak self] in await self?.calendarController.start(askAccess: askAccess) }
        } else {
            calendarController.stop()
            if expandedTab == .calendar { expandedTab = availableTabs.first ?? .shelf }
        }
    }

    /// Shows the system Calendar prompt if macOS has not asked yet.
    func requestCalendarAccess() {
        Task { @MainActor [weak self] in await self?.calendarController.requestAccess() }
    }

    func openCalendarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    func openInCalendar(_ event: AgendaEvent) { CalendarAdapter.openInCalendar(event) }

    /// Moves the month grid by whole months; 0 returns to this month.
    func showCalendarMonth(offset: Int) { calendarController.showMonth(offset: offset) }

    /// Opens a validated https meeting link (see CalendarAgenda.meetingLink).
    func joinMeeting(_ event: AgendaEvent) {
        guard let url = event.meetingURL, url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func setCalendar(_ id: String, visible: Bool) {
        if visible { hiddenCalendarIDs.remove(id) } else { hiddenCalendarIDs.insert(id) }
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
