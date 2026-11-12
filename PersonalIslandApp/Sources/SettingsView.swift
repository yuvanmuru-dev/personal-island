import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: IslandCoordinator

    private let plannedFeatures: [(symbol: String, title: String)] = [
        ("camera.viewfinder", "Screenshots and file shelf"),
        ("music.note", "Spotify and other players"),
        ("calendar", "Calendar"),
        ("battery.100", "Battery and charging"),
        ("wifi", "Bluetooth, Wi-Fi, VPN and hotspot"),
        ("arrow.down.circle", "Downloads and AirDrop"),
        ("timer", "Timers"),
        ("lock.square", "Lock-screen widgets and weather"),
        ("chart.bar", "System statistics"),
        ("doc.on.clipboard", "Clipboard history"),
        ("waveform", "Visualizer and lyrics"),
        ("eyedropper", "Color picker"),
        ("moon", "Focus and recording status")
    ]

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

                Section("Coming in later previews") {
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
            .formStyle(.grouped)
        }
        .frame(minWidth: 480, idealWidth: 550, minHeight: 440, idealHeight: 650)
    }
}
