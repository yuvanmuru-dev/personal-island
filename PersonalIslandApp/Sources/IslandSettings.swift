/*
 * Personal Island — remembered settings.
 * Written for this personal project; no upstream file copied.
 */

import Foundation

/// On/off choices remembered across launches. No personal content (captures,
/// track names, events) is ever stored here. Missing or unknown fields fall
/// back to defaults so older and newer builds can read each other's values.
struct IslandSettings: Codable, Equatable {
    var islandsVisible = true
    var expandOnHover = false
    var captureShortcutEnabled = true
    /// Display IDs the user turned off. IDs can change after reconnecting a
    /// display; an unknown ID simply has no effect.
    var disabledDisplays: [UInt32] = []
    var spotifyEnabled = false

    init() {}

    init(from decoder: any Decoder) throws {
        let defaults = IslandSettings()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        islandsVisible = (try? values.decodeIfPresent(Bool.self, forKey: .islandsVisible)) ?? defaults.islandsVisible
        expandOnHover = (try? values.decodeIfPresent(Bool.self, forKey: .expandOnHover)) ?? defaults.expandOnHover
        captureShortcutEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .captureShortcutEnabled))
            ?? defaults.captureShortcutEnabled
        let displays = (try? values.decodeIfPresent([UInt32].self, forKey: .disabledDisplays)) ?? []
        disabledDisplays = Array(Set(displays)).sorted()
        spotifyEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .spotifyEnabled)) ?? defaults.spotifyEnabled
    }
}

/// Reads and writes `IslandSettings` as one JSON value. Storage is injected so
/// tests never touch the user's preferences.
struct IslandSettingsStore {
    static let key = "settings.v1"
    /// Bounds what a damaged preferences value can make the app decode.
    static let maximumBytes = 64 * 1_024

    let load: () -> Data?
    let save: (Data) -> Void

    static func userDefaults(_ defaults: UserDefaults = .standard) -> IslandSettingsStore {
        IslandSettingsStore(
            load: { defaults.data(forKey: key) },
            save: { defaults.set($0, forKey: key) }
        )
    }

    func read() -> IslandSettings {
        guard let data = load(), data.count <= Self.maximumBytes,
              let settings = try? JSONDecoder().decode(IslandSettings.self, from: data) else {
            return IslandSettings()
        }
        return settings
    }

    func write(_ settings: IslandSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        save(data)
    }
}
