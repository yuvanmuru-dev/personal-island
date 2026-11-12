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
                                    Text(display.hasNotch ? "Below the notch" : "Floating below the menu bar")
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
