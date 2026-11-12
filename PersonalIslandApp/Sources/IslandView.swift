import AppKit
import SwiftUI
import PersonalIslandCore

struct IslandView: View {
    @ObservedObject var coordinator: IslandCoordinator
    @ObservedObject var presentation: IslandPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if presentation.isExpanded {
                expandedContent
            } else {
                compactContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if presentation.layout.hasNotch {
                if presentation.isExpanded {
                    NotchShape(topCornerRadius: 6, bottomCornerRadius: 22)
                        .fill(.black)
                } else if presentation.isWidened {
                    // Wings beside the housing join it seamlessly in black.
                    NotchShape(topCornerRadius: 6, bottomCornerRadius: 12)
                        .fill(.black)
                } else {
                    // The compact window is the camera housing itself. Paint
                    // nothing visible: square black corners would show beside
                    // the housing's rounded bottom corners.
                    Rectangle().fill(.black.opacity(0.01))
                }
            } else {
                RoundedRectangle(cornerRadius: backgroundCornerRadius, style: .continuous)
                    .fill(.black)
                    .overlay {
                        RoundedRectangle(cornerRadius: backgroundCornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.13), lineWidth: 1)
                    }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onExitCommand { presentation.collapse() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: presentation.isExpanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.activity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.showsLive)
    }

    private var backgroundCornerRadius: CGFloat {
        presentation.isExpanded ? 24 : presentation.layout.compactSize.height / 2
    }

    private var compactContent: some View {
        Button {
            presentation.toggle()
        } label: {
            Group {
                if let activity = presentation.activity {
                    activityContent(activity)
                } else if presentation.showsLive, let timer = coordinator.featuredTimer {
                    liveTimerContent(timer)
                } else if presentation.showsLive, coordinator.stopwatch.isRunning {
                    liveStopwatchContent(coordinator.stopwatch)
                } else if presentation.layout.hasNotch {
                    // Under the camera housing there are no pixels to show
                    // content; the compact island is only a hover/click target.
                    Color.clear
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 11, weight: .medium))
                        Text("\(coordinator.shelfItemCount)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation.activity.map(Self.activityDescription)
            ?? (presentation.showsLive && coordinator.featuredTimer != nil ? "Timer running. Open island"
                : presentation.showsLive && coordinator.stopwatch.isRunning ? "Stopwatch running. Open island"
                : "Open shelf, \(coordinator.shelfItemCount) items"))
        .help("Open shelf")
    }

    /// Something on the left wing, text on the right; the center stays clear
    /// for the camera housing (or holds the pill's spacing).
    private func wings<Leading: View>(@ViewBuilder leading: () -> Leading, trailing: Text, tint: Color) -> some View {
        let notch = presentation.layout.hasNotch
        let wing = presentation.layout.activityWingWidth
        return HStack(spacing: 0) {
            leading()
                .frame(width: notch ? wing : nil)
                .frame(maxWidth: notch ? nil : .infinity)
            if notch {
                Spacer(minLength: presentation.layout.compactSize.width)
            }
            trailing
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: notch ? wing : nil)
                .frame(maxWidth: notch ? nil : .infinity)
        }
        .padding(.horizontal, notch ? 0 : 8)
        .transition(.opacity)
    }

    @ViewBuilder
    private func activityContent(_ activity: IslandActivity) -> some View {
        switch activity {
        case .battery(let battery):
            wings(leading: {
                BatteryGlyph(percent: battery.percent, charging: Self.showsBolt(battery), tint: Self.tint(battery))
            }, trailing: Text(Self.activityText(battery)), tint: Self.tint(battery))
        case .timerDone:
            wings(leading: {
                Image(systemName: "bell.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.bounce, options: .repeat(3))
            }, trailing: Text("Done"), tint: .orange)
        }
    }

    /// A running stopwatch: its icon and the elapsed time.
    private func liveStopwatchContent(_ stopwatch: Stopwatch) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            wings(leading: {
                Image(systemName: "stopwatch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.cyan)
            }, trailing: Text(IslandTimers.stopwatchShortText(stopwatch.elapsed(at: context.date))), tint: .cyan)
        }
    }

    /// A running timer: a small progress ring and the time left.
    private func liveTimerContent(_ timer: IslandTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            wings(leading: {
                TimerRing(progress: timer.progress(at: context.date), paused: timer.isPaused, size: 14)
            }, trailing: Text(IslandTimers.clockText(timer.remaining(at: context.date))),
            tint: timer.isPaused ? .white.opacity(0.55) : .orange)
        }
    }

    private static func showsBolt(_ activity: BatteryActivity) -> Bool {
        switch activity {
        case .pluggedIn, .charged: true
        case .unplugged, .low: false
        }
    }

    private static func tint(_ activity: BatteryActivity) -> Color {
        switch activity {
        case .pluggedIn, .charged: .green
        case .low(let percent), .unplugged(let percent): BatteryGlyph.tint(percent: percent, pluggedIn: false)
        }
    }

    private static func activityText(_ activity: BatteryActivity) -> String {
        switch activity {
        case .charged(let percent): percent >= 100 ? "Full" : "\(percent)%"
        default: "\(activity.percent)%"
        }
    }

    static func activityDescription(_ activity: IslandActivity) -> String {
        switch activity {
        case .battery(let battery): batteryDescription(battery)
        case .timerDone(let duration): "\(IslandTimers.lengthText(duration)) timer done"
        }
    }

    static func batteryDescription(_ activity: BatteryActivity) -> String {
        switch activity {
        case .pluggedIn(let p): "Charging, \(p) percent"
        case .unplugged(let p): "On battery, \(p) percent"
        case .low(let p): "Low battery, \(p) percent"
        case .charged(let p): "Charged, \(p) percent"
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if coordinator.availableTabs.count > 1 {
                    ForEach(coordinator.availableTabs, id: \.self) { tab in
                        switch tab {
                        case .media: tabButton(.media, symbol: "music.note", title: "Media")
                        case .calendar: tabButton(.calendar, symbol: "calendar", title: "Calendar")
                        case .stats: tabButton(.stats, symbol: "gauge.with.dots.needle.50percent", title: "Stats")
                        case .timers: tabButton(.timers, symbol: "timer", title: "Timers",
                                                count: coordinator.timers.isEmpty ? nil : coordinator.timers.count)
                        case .shelf: tabButton(.shelf, symbol: "tray.fill", title: "Shelf", count: coordinator.shelfItemCount)
                        }
                    }
                } else {
                    Image(systemName: "tray.fill")
                        .foregroundStyle(.white.opacity(0.72))
                    Text("Shelf")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(coordinator.shelfItemCount)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let power = coordinator.power {
                    HStack(spacing: 4) {
                        Text("\(power.percent)%")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7))
                        BatteryGlyph(percent: power.percent, charging: power.isPluggedIn,
                                     tint: BatteryGlyph.tint(percent: power.percent, pluggedIn: power.isPluggedIn))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Battery \(power.percent) percent\(power.isPluggedIn ? ", plugged in" : "")")
                    .help(Self.powerHelp(power))
                }
                if showsShelf && !coordinator.shelfItems.isEmpty {
                    headerButton("trash", label: "Clear shelf") { coordinator.clearShelf() }
                }
                headerButton("camera.viewfinder", label: "Capture (\(coordinator.captureShortcutName))") {
                    presentation.collapse()
                    coordinator.captureRegion()
                }
                .disabled(coordinator.isCapturing)
                Button {
                    presentation.collapse()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close shelf")
                .help("Close shelf")
            }

            Group {
                switch coordinator.visibleTab {
                case .shelf: shelfContent
                case .media: MediaContent(coordinator: coordinator)
                case .calendar: CalendarContent(coordinator: coordinator)
                case .timers: TimersContent(coordinator: coordinator)
                case .stats: StatsContent(coordinator: coordinator)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = coordinator.shelfMessage {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }

            HStack {
                Text("PREVIEW")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.38))
                Spacer()
                Button("Settings") { coordinator.showSettings() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, presentation.layout.topContentInset + 12)
        .padding(.bottom, 18)
    }

    private var showsShelf: Bool { coordinator.visibleTab == .shelf }

    private static func powerHelp(_ power: PowerSnapshot) -> String {
        func duration(_ minutes: Int) -> String { "\(minutes / 60):" + String(format: "%02d", minutes % 60) }
        if power.isPluggedIn {
            if power.isCharged || power.percent == 100 { return "Charged" }
            if let minutes = power.minutesToFull, power.isCharging { return "\(duration(minutes)) until full" }
            return power.isCharging ? "Charging" : "Plugged in, not charging"
        }
        if let minutes = power.minutesToEmpty { return "\(duration(minutes)) remaining" }
        return "On battery"
    }

    private func tabButton(_ tab: IslandCoordinator.ExpandedTab, symbol: String, title: String, count: Int? = nil) -> some View {
        let selected = coordinator.visibleTab == tab
        return Button {
            coordinator.expandedTab = tab
            if tab == .media { coordinator.islandDidExpand() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                // With many sections, only the selected one is labeled so the
                // header still fits beside the battery and buttons.
                if selected || coordinator.availableTabs.count <= 3 {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.5))
            .background(.white.opacity(selected ? 0.12 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }

    @ViewBuilder
    private var shelfContent: some View {
        if coordinator.shelfAvailability == .unavailable {
            VStack(spacing: 9) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Temporary shelf unavailable")
                    .font(.system(size: 13, weight: .medium))
                Button("Try again") { coordinator.prepareShelfIfNeeded(retry: true) }
                    .font(.system(size: 12))
                    .buttonStyle(.bordered)
            }
        } else if coordinator.shelfItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.36))
                Text("Your shelf is empty")
                    .font(.system(size: 13, weight: .medium))
                Text("Press \(coordinator.captureShortcutName), then drag a region, press Space for a window, or Return for the screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.48))
            }
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(coordinator.shelfItems, id: \.id) { item in
                        ShelfTile(
                            item: item,
                            coordinator: coordinator,
                            isSelected: coordinator.selectedItemIDs.contains(item.id),
                            thumbnail: coordinator.thumbnails[item.id],
                            symbol: symbol(for: item),
                            label: label(for: item),
                            onCopy: { coordinator.copyShelfItem(item.id) },
                            onRemove: { coordinator.removeShelfItem(item.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func symbol(for item: ShelfItem) -> String {
        switch item.payload {
        case .screenshot: "photo"
        case .fileReference: "doc"
        }
    }

    private func label(for item: ShelfItem) -> String {
        switch item.payload {
        case .screenshot: "Screenshot"
        case .fileReference: "File"
        }
    }
}

/// One shelf item: thumbnail, capture time, and Copy/Remove on hover. Click
/// to select; drag to send the selection (or this item) to another app. The
/// controls stay reachable by keyboard and accessibility without hovering.
private struct ShelfTile: View {
    let item: ShelfItem
    let coordinator: IslandCoordinator
    let isSelected: Bool
    let thumbnail: NSImage?
    let symbol: String
    let label: String
    let onCopy: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 24, weight: .light))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 96, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.12),
                                      lineWidth: isSelected ? 2 : 1)
                }
                .overlay { ShelfDragSource(itemID: item.id, coordinator: coordinator) }
                .help("Drag into another app. Click to select several.")

                HStack(spacing: 4) {
                    tileButton("doc.on.doc", label: "Copy \(label.lowercased())", action: onCopy)
                    tileButton("xmark", label: "Remove \(label.lowercased())", action: onRemove)
                }
                .padding(4)
                .opacity(hovering ? 1 : 0)
            }
            Text(item.createdAt, style: .time)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tileButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.65), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Current Spotify track and controls. Shows why control is unavailable
/// instead of failing silently, and never opens Spotify by itself.
private struct MediaContent: View {
    @ObservedObject var coordinator: IslandCoordinator

    var body: some View {
        VStack(spacing: 10) {
            switch coordinator.spotifyStatus {
            case .notRunning:
                notice("Spotify isn't running", button: "Open Spotify") { coordinator.openSpotify() }
            case .needsPermission where coordinator.nowPlaying == nil:
                notice("Allow Personal Island to control Spotify", button: "Allow…") {
                    coordinator.requestSpotifyPermission()
                }
            case .denied where coordinator.nowPlaying == nil:
                notice("Spotify control is off in System Settings", button: "Open Settings") {
                    coordinator.openAutomationSettings()
                }
            default:
                if let track = coordinator.nowPlaying {
                    trackView(track)
                } else if coordinator.spotifyStatus == .unavailable {
                    notice("Spotify didn't answer", button: "Try again") { coordinator.requestSpotifyPermission() }
                } else {
                    notice("Nothing playing in Spotify", button: nil) {}
                }
            }
        }
    }

    private var canControl: Bool { coordinator.spotifyStatus == .ready }

    /// The cover, or a placeholder while it loads or when there is none.
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.08))
            if let artwork = coordinator.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func trackView(_ track: NowPlaying) -> some View {
        HStack(spacing: 12) {
            if coordinator.spotifyArtworkEnabled {
                cover
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }

        // Redraws only while visible; the slider owns its own drag state so
        // timeline ticks cannot fight a drag in progress.
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            PlaybackScrubber(
                position: track.position(at: context.date),
                duration: track.duration,
                enabled: canControl || coordinator.spotifyStatus == .needsPermission,
                onSeek: { coordinator.spotifyCommand(.seek($0)) }
            )
        }

        HStack(spacing: 26) {
            control("backward.fill", label: "Previous track") { coordinator.spotifyCommand(.previous) }
            control(track.isPlaying ? "pause.fill" : "play.fill", label: track.isPlaying ? "Pause" : "Play", size: 18) {
                coordinator.spotifyCommand(.playPause)
            }
            // Swap the symbol in place; no cross-fade or resize between states.
            .transaction { $0.animation = nil }
            control("forward.fill", label: "Next track") { coordinator.spotifyCommand(.next) }
        }
        if !canControl {
            Text(coordinator.spotifyStatus == .denied
                 ? "Allow control under Privacy & Security › Automation."
                 : "Pressing a control will ask for permission.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func control(_ symbol: String, label: String, size: CGFloat = 14, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(coordinator.spotifyStatus == .denied ? 0.35 : 0.9))
        .disabled(coordinator.spotifyStatus == .denied)
        .accessibilityLabel(label)
        .help(label)
    }

    private func notice(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "music.note")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text(text)
                .font(.system(size: 13, weight: .medium))
            if let button {
                Button(button, action: action)
                    .font(.system(size: 12))
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Track position that can be dragged to seek. While dragging, the thumb
/// follows the pointer and incoming position updates are ignored; releasing
/// sends one seek. Arrow keys seek by five seconds for keyboard users.
private struct PlaybackScrubber: View {
    let position: TimeInterval
    let duration: TimeInterval?
    let enabled: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var dragPosition: TimeInterval?

    private var shown: TimeInterval { dragPosition ?? position }
    private var canSeek: Bool { enabled && (duration ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let fraction = duration.map { $0 > 0 ? min(1, max(0, shown / $0)) : 0 } ?? 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                    Capsule().fill(.white.opacity(0.85)).frame(width: width * fraction, height: 4)
                    if canSeek {
                        Circle()
                            .fill(.white)
                            .frame(width: dragPosition == nil ? 9 : 12, height: dragPosition == nil ? 9 : 12)
                            .offset(x: width * fraction - (dragPosition == nil ? 4.5 : 6))
                    }
                }
                .frame(height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard canSeek, let duration else { return }
                            dragPosition = min(max(0, value.location.x / width), 1) * duration
                        }
                        .onEnded { value in
                            guard canSeek, let duration else { return }
                            let target = min(max(0, value.location.x / width), 1) * duration
                            onSeek(target)
                            // Keep the thumb where it was dropped until the
                            // next update arrives, instead of jumping back.
                            dragPosition = target
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                if dragPosition == target { dragPosition = nil }
                            }
                        }
                )
            }
            .frame(height: 14)
            HStack {
                Text(SpotifyPlayback.timeText(shown))
                Spacer()
                Text(duration.map(SpotifyPlayback.timeText) ?? "")
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(SpotifyPlayback.timeText(shown)) of \(duration.map(SpotifyPlayback.timeText) ?? "unknown")")
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            onSeek(shown + (direction == .increment ? 5 : -5))
        }
    }
}

/// Next event and today's agenda, read-only. Clicking an event opens it in
/// Apple Calendar; Join appears only for validated meeting links.
private struct CalendarContent: View {
    @ObservedObject var coordinator: IslandCoordinator

    var body: some View {
        switch coordinator.calendarStatus {
        case .needsAccess, .off:
            notice("Allow Personal Island to read your calendars", button: "Allow…") {
                coordinator.requestCalendarAccess()
            }
        case .denied:
            notice("Calendar access is off in System Settings", button: "Open Settings") {
                coordinator.openCalendarSettings()
            }
        case .ready:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                agenda(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func agenda(now: Date) -> some View {
        let rows = coordinator.todayEvents
        // Once today has nothing left, show what comes next (any later day).
        let todayDone = rows.allSatisfy { $0.end <= now }
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Today")
                if rows.isEmpty {
                    Text("No events")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                } else {
                    ForEach(rows) { event in row(event, now: now, showDay: false) }
                }
                if todayDone {
                    sectionLabel("Next event")
                    if let upcoming = coordinator.upcomingEvent {
                        row(upcoming, now: now, showDay: true)
                    } else {
                        Text("Nothing in the next \(CalendarAgenda.lookaheadDays) days")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.top, 2)
    }

    private func row(_ event: AgendaEvent, now: Date, showDay: Bool) -> some View {
        let isNext = event.id == coordinator.nextEvent?.id || (showDay && event.id == coordinator.upcomingEvent?.id)
        let finished = event.end <= now
        return HStack(spacing: 8) {
            Circle()
                .fill(Color(.sRGB, red: event.color[safe: 0], green: event.color[safe: 1], blue: event.color[safe: 2]))
                .frame(width: 7, height: 7)
            Text(timeText(event, now: now, showDay: showDay))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(isNext ? 0.85 : 0.5))
                .frame(width: showDay ? 132 : 92, alignment: .leading)
            Text(event.title)
                .font(.system(size: 12, weight: isNext ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isNext, event.meetingURL != nil {
                Button("Join") { coordinator.joinMeeting(event) }
                    .font(.system(size: 10.5, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .opacity(finished ? 0.45 : 1)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isNext ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { coordinator.openInCalendar(event) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens in Calendar")
    }

    private func timeText(_ event: AgendaEvent, now: Date, showDay: Bool) -> String {
        if showDay && event.start > now {
            let calendar = Calendar.autoupdatingCurrent
            let day = CalendarAgenda.dayLabel(for: event.start, now: now, calendar: calendar)
            return day + " · " + (event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
        }
        if event.isAllDay { return "All day" }
        if event.start <= now && event.end > now { return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes >= 0 && minutes < 60 && !showDay { return "in \(max(1, minutes)) min" }
        return event.start.formatted(date: .omitted, time: .shortened)
    }

    private func notice(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "calendar")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text(text)
                .font(.system(size: 13, weight: .medium))
            if let button {
                Button(button, action: action)
                    .font(.system(size: 12))
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double { indices.contains(index) ? self[index] : 0.6 }
}

/// A small battery outline filled to the level, with a bolt while charging.
private struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool
    let tint: Color

    private static let bodySize = CGSize(width: 25, height: 12)
    private static let inset: CGFloat = 2

    var body: some View {
        let inner = Self.bodySize.width - 2 * Self.inset
        let fill = inner * CGFloat(min(100, max(0, percent))) / 100
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, fill), height: Self.bodySize.height - 2 * Self.inset)
                    .padding(.leading, Self.inset)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8.5, weight: .heavy))
                        // Dark on a filled body, light on a nearly empty one.
                        .foregroundStyle(percent >= 45 ? Color.black.opacity(0.8) : .white)
                        .frame(width: Self.bodySize.width)
                }
            }
            .frame(width: Self.bodySize.width, height: Self.bodySize.height)
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.5))
                .frame(width: 1.5, height: 4.5)
        }
        .accessibilityHidden(true)
    }

    /// Green while plugged in; on battery the color follows the level.
    static func tint(percent: Int, pluggedIn: Bool) -> Color {
        if pluggedIn { return .green }
        switch percent {
        case ...10: return .red
        case ...20: return .orange
        case ...50: return .yellow
        default: return .green
        }
    }
}

/// A ring that empties as the timer runs down.
private struct TimerRing: View {
    let progress: Double
    let paused: Bool
    let size: CGFloat

    var body: some View {
        let width = max(1.5, size / 9)
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: width)
            Circle()
                .trim(from: 0, to: max(0, 1 - progress))
                .stroke(paused ? Color.white.opacity(0.5) : .orange,
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Timers (running and paused, presets, custom length) or the stopwatch.
private struct TimersContent: View {
    @ObservedObject var coordinator: IslandCoordinator
    @State private var customMinutes = 20
    @State private var showsStopwatch: Bool?

    /// Opens on the stopwatch if it is in use and no timer is.
    private var stopwatchSelected: Bool {
        showsStopwatch ?? (coordinator.timers.isEmpty && coordinator.stopwatch.isActive)
    }

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: Binding(get: { stopwatchSelected }, set: { showsStopwatch = $0 })) {
                Text("Timers").tag(false)
                Text("Stopwatch").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 190)
            .padding(.top, 8)
            if stopwatchSelected {
                StopwatchContent(coordinator: coordinator)
            } else {
                timersBody
            }
        }
    }

    private var timersBody: some View {
        VStack(spacing: 8) {
            if coordinator.timers.isEmpty {
                Spacer(minLength: 0)
                Text("Start a timer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(coordinator.timers) { timer in row(timer) }
                    }
                }
            }
            Spacer(minLength: 0)
            presets
            custom
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func row(_ timer: IslandTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                TimerRing(progress: timer.progress(at: context.date), paused: timer.isPaused, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(IslandTimers.clockText(timer.remaining(at: context.date)))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timer.isPaused ? .white.opacity(0.55) : .white)
                    Text("\(IslandTimers.lengthText(timer.duration)) timer\(timer.isPaused ? " · Paused" : "")")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                roundButton(timer.isPaused ? "play.fill" : "pause.fill", label: timer.isPaused ? "Resume" : "Pause") {
                    if timer.isPaused { coordinator.resumeTimer(timer.id) } else { coordinator.pauseTimer(timer.id) }
                }
                roundButton("xmark", label: "Cancel timer") { coordinator.cancelTimer(timer.id) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(IslandTimers.lengthText(timer.duration)) timer, \(IslandTimers.clockText(timer.remaining(at: context.date))) left\(timer.isPaused ? ", paused" : "")")
        }
    }

    private var presets: some View {
        HStack(spacing: 5) {
            ForEach(IslandTimers.presetMinutes, id: \.self) { minutes in
                Button {
                    coordinator.startTimer(minutes: minutes)
                } label: {
                    Text(minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(.white.opacity(0.1), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start \(IslandTimers.lengthText(Double(minutes) * 60)) timer")
            }
        }
        .disabled(!coordinator.canAddTimer)
        .opacity(coordinator.canAddTimer ? 1 : 0.4)
    }

    private var custom: some View {
        HStack(spacing: 8) {
            Text(coordinator.canAddTimer ? "Custom" : "Up to \(IslandTimers.maximumCount) timers")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            roundButton("minus", label: "One minute less") { step(-1) }
                .disabled(customMinutes <= IslandTimers.customMinutes.lowerBound)
            Text(IslandTimers.lengthText(Double(customMinutes) * 60))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 74)
            roundButton("plus", label: "One minute more") { step(1) }
                .disabled(customMinutes >= IslandTimers.customMinutes.upperBound)
            Button("Start") { coordinator.startTimer(minutes: customMinutes) }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(.orange.opacity(coordinator.canAddTimer ? 0.85 : 0.3), in: Capsule())
                .disabled(!coordinator.canAddTimer)
        }
        .accessibilityElement(children: .contain)
    }

    private func step(_ delta: Int) {
        // Small steps near the start, larger ones for longer timers.
        let size = customMinutes + (delta > 0 ? 0 : -1) >= 60 ? 5 : 1
        let next = customMinutes + delta * size
        customMinutes = min(IslandTimers.customMinutes.upperBound, max(IslandTimers.customMinutes.lowerBound, next))
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Elapsed time with tenths, Start/Pause, Lap and Reset, and recent laps.
private struct StopwatchContent: View {
    @ObservedObject var coordinator: IslandCoordinator

    var body: some View {
        let stopwatch = coordinator.stopwatch
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(IslandTimers.stopwatchText(stopwatch.elapsed(at: context.date)))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(stopwatch.isRunning || !stopwatch.isActive ? .white : .white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Stopwatch \(IslandTimers.stopwatchShortText(stopwatch.elapsed(at: context.date)))")
                }
                pill(stopwatch.isRunning ? "Lap" : "Reset", tint: .white.opacity(0.14)) {
                    if stopwatch.isRunning { coordinator.lapStopwatch() } else { coordinator.resetStopwatch() }
                }
                .disabled(!stopwatch.isActive)
                .opacity(stopwatch.isActive ? 1 : 0.4)
                pill(stopwatch.isRunning ? "Pause" : stopwatch.isActive ? "Resume" : "Start",
                     tint: stopwatch.isRunning ? .orange.opacity(0.85) : .green.opacity(0.75)) {
                    if stopwatch.isRunning { coordinator.pauseStopwatch() } else { coordinator.startStopwatch() }
                }
            }
            if stopwatch.lapMarks.isEmpty {
                Spacer(minLength: 0)
            } else {
                laps(stopwatch)
            }
        }
        .padding(.bottom, 4)
    }

    /// Most recent first; the fastest and slowest are marked once there are
    /// at least three laps.
    private func laps(_ stopwatch: Stopwatch) -> some View {
        let lengths = stopwatch.lapLengths
        let fastest = lengths.count >= 3 ? lengths.min() : nil
        let slowest = lengths.count >= 3 ? lengths.max() : nil
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(Array(lengths.enumerated()).reversed(), id: \.offset) { index, length in
                    HStack {
                        Text("Lap \(index + 1)")
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Text(IslandTimers.stopwatchText(length))
                            .foregroundStyle(length == fastest ? .green : length == slowest ? .orange : .white)
                        Text(IslandTimers.stopwatchText(stopwatch.lapMarks[index]))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 11.5, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                }
            }
        }
    }

    private func pill(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 62, height: 28)
                .background(tint, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// CPU, GPU, memory, network, disk activity and free space, each with a
/// short graph. Readings exist only while this tab is on screen.
private struct StatsContent: View {
    @ObservedObject var coordinator: IslandCoordinator

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        let reading = coordinator.stats
        let history = coordinator.statsHistory
        LazyVGrid(columns: columns, spacing: 8) {
            tile("CPU", symbol: "cpu", value: SystemStats.percentText(reading?.cpuPercent),
                 detail: nil, graph: history.cpu, scale: 100, tint: .orange)
            tile("GPU", symbol: "square.stack.3d.up", value: SystemStats.percentText(reading?.gpuPercent),
                 detail: reading == nil || reading?.gpuPercent != nil ? nil : "Not reported", graph: [], scale: 100, tint: .purple)
            tile("Memory", symbol: "memorychip", value: SystemStats.percentText(reading?.memoryPercent),
                 detail: reading?.memoryUsed.map { used in
                     "\(SystemStats.bytesText(Double(used), binary: true)) of \(SystemStats.bytesText(reading?.memoryTotal.map { Double($0) }, binary: true))"
                 }, graph: history.memory, scale: 100, tint: .green)
            tile("Network", symbol: "arrow.up.arrow.down", value: "↓ " + SystemStats.rateText(reading?.networkInPerSecond),
                 detail: "↑ " + SystemStats.rateText(reading?.networkOutPerSecond), graph: history.network, scale: nil, tint: .cyan)
            tile("Disk", symbol: "internaldrive", value: "R " + SystemStats.rateText(reading?.diskReadPerSecond),
                 detail: "W " + SystemStats.rateText(reading?.diskWritePerSecond), graph: history.disk, scale: nil, tint: .blue)
            tile("Storage", symbol: "externaldrive", value: SystemStats.bytesText(reading?.diskFree.map { Double($0) }),
                 detail: reading?.diskTotal.map { "free of " + SystemStats.bytesText(Double($0)) }, graph: [], scale: nil, tint: .gray)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func tile(_ title: String, symbol: String, value: String, detail: String?,
                      graph: [Double], scale: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Sparkline(values: graph, scale: scale)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .frame(height: 12)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)\(detail.map { ", " + $0 } ?? "")")
    }
}

/// A line through the values, right-aligned so the newest is at the edge.
private struct Sparkline: Shape {
    let values: [Double]
    /// Fixed top of the scale (percentages), or nil to fit the largest value.
    let scale: Double?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let top = max(scale ?? (values.max() ?? 0), 1)
        let step = rect.width / CGFloat(SystemStats.historyLength - 1)
        let startX = rect.maxX - step * CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: startX + step * CGFloat(index),
                                y: rect.maxY - rect.height * CGFloat(min(1, max(0, value / top))))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
