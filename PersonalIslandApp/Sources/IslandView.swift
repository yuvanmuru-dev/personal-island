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
    }

    private var backgroundCornerRadius: CGFloat {
        presentation.isExpanded ? 24 : presentation.layout.compactSize.height / 2
    }

    private var compactContent: some View {
        Button {
            presentation.toggle()
        } label: {
            Group {
                if presentation.layout.hasNotch {
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
        .accessibilityLabel("Open shelf, \(coordinator.shelfItemCount) items")
        .help("Open shelf")
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if coordinator.availableTabs.count > 1 {
                    ForEach(coordinator.availableTabs, id: \.self) { tab in
                        switch tab {
                        case .media: tabButton(.media, symbol: "music.note", title: "Media")
                        case .calendar: tabButton(.calendar, symbol: "calendar", title: "Calendar")
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

    private func tabButton(_ tab: IslandCoordinator.ExpandedTab, symbol: String, title: String, count: Int? = nil) -> some View {
        let selected = coordinator.visibleTab == tab
        return Button {
            coordinator.expandedTab = tab
            if tab == .media { coordinator.islandDidExpand() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
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

    @ViewBuilder
    private func trackView(_ track: NowPlaying) -> some View {
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
