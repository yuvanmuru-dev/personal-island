import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: IslandCoordinator

    /// Kept features that are not built yet.
    private let plannedFeatures: [(symbol: String, title: String)] = []

    private var spotifyExplanation: String {
        switch coordinator.spotifyStatus {
        case .off: "Shows the current Spotify track with play, pause and skip. macOS will ask once whether Personal Island may control Spotify."
        case .notRunning: "Spotify isn't running. The island never opens it on its own."
        case .needsPermission: "Open the island's Media tab and choose Allow to let Personal Island control Spotify."
        case .denied: "Control is off: allow Personal Island under Privacy & Security › Automation › Spotify."
        case .ready: "Connected to Spotify on this Mac. Nothing is sent online."
        case .unavailable: "Spotify didn't answer. It may still be starting."
        }
    }

    private var calendarExplanation: String {
        switch coordinator.calendarStatus {
        case .off: "Shows your next event and today's agenda from calendars on this Mac, read-only. macOS will ask for Calendar access; it only offers full access, but Personal Island never changes events."
        case .needsAccess: "Open the island's Calendar tab and choose Allow."
        case .denied: "Calendar access is off: allow Personal Island under Privacy & Security › Calendars."
        case .ready: "Reading calendars on this Mac. Nothing is changed or sent online. Choose which calendars to show:"
        }
    }

    private var batteryExplanation: String {
        switch coordinator.batteryStatus {
        case .off: "Shows charging changes beside the notch and the battery level in the open island. Reads the same information as the menu bar; no permission needed."
        case .noBattery: "This Mac doesn't report a battery."
        case .ready: "Plugging in or unplugging shows a short notice beside the notch on every island. Nothing is stored or sent."
        }
    }

    private var clipboardExplanation: String {
        switch coordinator.clipboardStatus {
        case .needsAccess: "macOS is set to ask (or deny) before Personal Island reads the clipboard. To keep a history, allow it to always paste under Privacy & Security; until then nothing is read."
        default: "Keeps your last 50 copies (text, links, images and files) in memory only, cleared when you quit or turn this off. Copies marked as passwords are never read. macOS may ask once whether Personal Island can read the clipboard; choose to always allow it."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "capsule.fill")
                    .font(.system(size: 25))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Personal Island")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Preview · Your space, on both screens")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 25)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Form {
                Section("Island") {
                    Toggle("Show islands", isOn: Binding(
                        get: { coordinator.islandsVisible },
                        set: { coordinator.setIslandsVisible($0) }
                    ))
                    Toggle("Expand on hover", isOn: $coordinator.expandOnHover)
                    Toggle("Capture shortcut (\(coordinator.captureShortcutName))", isOn: $coordinator.captureShortcutEnabled)
                    Toggle("Spotify in the island", isOn: $coordinator.spotifyEnabled)
                    Text(spotifyExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if coordinator.spotifyEnabled {
                        Toggle("Show album artwork", isOn: $coordinator.spotifyArtworkEnabled)
                            .padding(.leading, 16)
                        Text("Downloads the current track's cover from Spotify's image server (i.scdn.co). Spotify's servers see the request; nothing else is sent, and images are kept in memory only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                    }
                    Toggle("Calendar in the island", isOn: $coordinator.calendarEnabled)
                    Text(calendarExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if coordinator.calendarStatus == .ready {
                        ForEach(coordinator.calendars) { calendar in
                            Toggle(isOn: Binding(
                                get: { !coordinator.hiddenCalendarIDs.contains(calendar.id) },
                                set: { coordinator.setCalendar(calendar.id, visible: $0) }
                            )) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(.sRGB, red: calendar.color[0], green: calendar.color[1], blue: calendar.color[2]))
                                        .frame(width: 8, height: 8)
                                    Text(calendar.title)
                                    Text(calendar.source).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, 16)
                        }
                    }
                    Toggle("Timers", isOn: $coordinator.timersEnabled)
                    Text("Adds a Timers tab for countdowns you start, pause and cancel in the island. Timers live in memory: quitting Personal Island or turning this off cancels them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if coordinator.timersEnabled {
                        Toggle("Show the running timer beside the notch", isOn: $coordinator.timerInNotch)
                            .padding(.leading, 16)
                        Toggle("Play a sound when a timer ends", isOn: $coordinator.timerSound)
                            .padding(.leading, 16)
                    }
                    Toggle("AirDrop", isOn: $coordinator.transfersEnabled)
                    Text("Shows files you receive by AirDrop arriving beside the notch and in an AirDrop tab. It follows the progress macOS publishes for them; your Downloads folder isn't read, and browser downloads aren't shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Clipboard history", isOn: $coordinator.clipboardEnabled)
                    Text(clipboardExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("System activity", isOn: $coordinator.statsEnabled)
                    Text("Adds a Stats tab with CPU, GPU, memory, network and disk activity and free space. Readings are taken once a second only while that tab is open, and are never stored or sent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Battery and charging", isOn: $coordinator.batteryEnabled)
                    Text(batteryExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if coordinator.batteryEnabled && coordinator.batteryStatus != .noBattery {
                        Toggle("Low battery alerts at 20% and 10%", isOn: $coordinator.batteryLowAlerts)
                            .padding(.leading, 16)
                        Toggle("Alert when charged", isOn: $coordinator.batteryChargedAlert)
                            .padding(.leading, 16)
                    }
                    if coordinator.captureShortcutEnabled && !coordinator.captureShortcutRegistered {
                        Text("\(coordinator.captureShortcutName) is already used by another app.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Click an island to open its shelf. Escape closes it when the island has keyboard focus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Displays") {
                    ForEach(coordinator.displays) { display in
                        Toggle(isOn: Binding(
                            get: { coordinator.displays.first(where: { $0.id == display.id })?.isEnabled ?? false },
                            set: { coordinator.setDisplayEnabled(display.id, enabled: $0) }
                        )) {
                            HStack(spacing: 10) {
                                Image(systemName: display.hasNotch ? "laptopcomputer" : "display")
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(display.name)
                                    Text(display.hasNotch ? "In the notch" : "Pill in the menu bar")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Both displays share the same shelf.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !plannedFeatures.isEmpty {
                    Section("Coming next") {
                        ForEach(plannedFeatures, id: \.title) { feature in
                            HStack(spacing: 10) {
                                Image(systemName: feature.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(feature.title)
                                Spacer()
                                Text("Planned")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 480, idealWidth: 550, minHeight: 440, idealHeight: 650)
    }
}
