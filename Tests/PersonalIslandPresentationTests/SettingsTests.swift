import Foundation
import Testing
@testable import PersonalIslandPresentation

private final class MemoryStorage: @unchecked Sendable {
    var data: Data?
    var writes = 0
    var store: IslandSettingsStore {
        IslandSettingsStore(load: { self.data }, save: { self.data = $0; self.writes += 1 })
    }
}

@Test func nothingStoredGivesTheDefaults() {
    let settings = MemoryStorage().store.read()
    #expect(settings == IslandSettings())
    #expect(settings.islandsVisible)
    #expect(!settings.expandOnHover)
    #expect(settings.captureShortcutEnabled)
    #expect(settings.disabledDisplays.isEmpty)
    #expect(!settings.spotifyEnabled)
    #expect(!settings.calendarEnabled)
    #expect(settings.hiddenCalendarIDs.isEmpty)
}

@Test func everyChoiceRoundTrips() {
    let storage = MemoryStorage()
    var settings = IslandSettings()
    settings.islandsVisible = false
    settings.expandOnHover = true
    settings.captureShortcutEnabled = false
    settings.disabledDisplays = [3, 1]
    settings.spotifyEnabled = true
    settings.calendarEnabled = true
    settings.hiddenCalendarIDs = ["b", "a"]
    storage.store.write(settings)
    var expected = settings
    expected.disabledDisplays = [1, 3]
    let read = storage.store.read()
    #expect(read.islandsVisible == false && read.expandOnHover && !read.captureShortcutEnabled && read.spotifyEnabled)
    #expect(Set(read.disabledDisplays) == [1, 3])
    #expect(read.calendarEnabled)
    #expect(read.hiddenCalendarIDs == ["a", "b"])
    #expect(storage.writes == 1)
}

@Test func damagedOrOversizedValuesFallBackToDefaults() {
    let storage = MemoryStorage()
    for data in [Data("not json".utf8), Data("[]".utf8), Data("null".utf8),
                 Data(repeating: 0x20, count: IslandSettingsStore.maximumBytes + 1)] {
        storage.data = data
        #expect(storage.store.read() == IslandSettings())
    }
}

@Test func missingWrongTypedAndUnknownFieldsKeepDefaultsForThoseFieldsOnly() {
    let storage = MemoryStorage()
    storage.data = Data(#"{"expandOnHover": true, "captureShortcutEnabled": "yes", "disabledDisplays": [7, 7, 2], "futureFeature": 1}"#.utf8)
    let settings = storage.store.read()
    #expect(settings.expandOnHover)
    #expect(settings.captureShortcutEnabled)   // wrong type: default kept
    #expect(settings.islandsVisible)           // missing: default kept
    #expect(settings.disabledDisplays == [2, 7])
    #expect(!settings.spotifyEnabled)
}

@Test func hiddenCalendarIdentifiersAreDeduplicatedAndBounded() {
    let storage = MemoryStorage()
    let long = String(repeating: "x", count: 300)
    storage.data = Data(#"{"hiddenCalendarIDs": ["b", "a", "b", "", "\#(long)"]}"#.utf8)
    #expect(storage.store.read().hiddenCalendarIDs == ["a", "b"])
}
