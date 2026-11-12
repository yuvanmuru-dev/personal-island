import Foundation
import Testing
@testable import PersonalIslandPresentation

@Test func onlyHttpsUrlsOnSpotifysImageHostAreAccepted() {
    #expect(SpotifyArtwork.validatedURL("https://i.scdn.co/image/ab67616d0000b273abc")?.host == "i.scdn.co")
    #expect(SpotifyArtwork.validatedURL("https://I.SCDN.CO/image/x") != nil)
    #expect(SpotifyArtwork.validatedURL("https://i.scdn.co:443/image/x") != nil)
    for rejected in [
        nil, "", "http://i.scdn.co/image/x", "file:///tmp/x.jpg", "https://i.scdn.co.example.com/image/x",
        "https://example.com/i.scdn.co/x", "https://user:secret@i.scdn.co/image/x", "https://i.scdn.co:8443/image/x",
        "https://mosaic.scdn.co/640/x", "spotify:image:abc", "https://i.scdn.co/" + String(repeating: "a", count: 600),
    ] {
        #expect(SpotifyArtwork.validatedURL(rejected) == nil)
    }
}

@Test func onlyCommonImageTypesAreDecoded() {
    #expect(SpotifyArtwork.isImage(mimeType: "image/jpeg"))
    #expect(SpotifyArtwork.isImage(mimeType: "IMAGE/PNG"))
    #expect(!SpotifyArtwork.isImage(mimeType: "text/html"))
    #expect(!SpotifyArtwork.isImage(mimeType: "image/svg+xml"))
    #expect(!SpotifyArtwork.isImage(mimeType: nil))
}

@MainActor
private final class FakeArtworkPlatform {
    var replies: [(trackID: String?, url: String?)] = []
    var lookups = 0
    var fetched: [URL] = []
    var images: [URL: Data] = [:]
    /// When set, fetches wait until `release()`.
    var holdFetch = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func loader() -> SpotifyArtworkLoader {
        SpotifyArtworkLoader(environment: .init(
            lookup: { [unowned self] in
                self.lookups += 1
                return self.replies.isEmpty ? (nil, nil) : self.replies.removeFirst()
            },
            fetch: { [unowned self] url in
                self.fetched.append(url)
                if self.holdFetch { await withCheckedContinuation { self.held.append($0) } }
                return self.images[url]
            },
            retryDelay: {}
        ))
    }

    func release() {
        let pending = held
        held = []
        for continuation in pending { continuation.resume() }
    }
}

private let coverA = URL(string: "https://i.scdn.co/image/a")!
private let coverB = URL(string: "https://i.scdn.co/image/b")!

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@Test @MainActor func coverIsFetchedOncePerTrackAndClearedOnStop() async {
    let platform = FakeArtworkPlatform()
    platform.replies = [("track:a", coverA.absoluteString)]
    platform.images[coverA] = Data([1, 2, 3])
    let loader = platform.loader()
    var changes = 0
    loader.onChange = { changes += 1 }
    loader.show(trackID: "track:a")
    loader.show(trackID: "track:a")
    await settle()
    #expect(loader.imageData == Data([1, 2, 3]))
    #expect(platform.lookups == 1 && platform.fetched == [coverA])
    loader.stop()
    #expect(loader.imageData == nil && loader.trackID == nil)
    #expect(changes == 2)
}

@Test @MainActor func aSlowCoverForAnEarlierTrackNeverReplacesTheCurrentOne() async {
    let platform = FakeArtworkPlatform()
    platform.replies = [("track:a", coverA.absoluteString), ("track:b", coverB.absoluteString)]
    platform.images = [coverA: Data([0xA]), coverB: Data([0xB])]
    platform.holdFetch = true
    let loader = platform.loader()
    loader.show(trackID: "track:a")
    await settle()
    loader.show(trackID: "track:b")
    await settle()
    platform.release()
    await settle()
    #expect(loader.imageData == Data([0xB]))
    loader.stop()
    platform.release()
    await settle()
    #expect(loader.imageData == nil)
}

@Test @MainActor func aStaleTrackReplyIsRetriedOnceThenGivesNoCover() async {
    let platform = FakeArtworkPlatform()
    platform.images[coverA] = Data([1])
    platform.replies = [("track:old", coverB.absoluteString), ("track:a", coverA.absoluteString)]
    let loader = platform.loader()
    loader.show(trackID: "track:a")
    await settle()
    #expect(loader.imageData == Data([1]) && platform.lookups == 2)

    platform.replies = [("track:old", coverB.absoluteString), ("track:old", coverB.absoluteString)]
    loader.show(trackID: "track:c")
    await settle()
    #expect(loader.imageData == nil && platform.lookups == 4)
    #expect(platform.fetched == [coverA])   // never fetched the other track's cover
}

@Test @MainActor func unexpectedHostsEmptyAndOversizedImagesShowNothing() async {
    let platform = FakeArtworkPlatform()
    let loader = platform.loader()
    platform.replies = [("track:a", "https://tracker.example.com/pixel.jpg")]
    loader.show(trackID: "track:a")
    await settle()
    #expect(platform.fetched.isEmpty && loader.imageData == nil)

    platform.replies = [("track:b", coverB.absoluteString)]
    platform.images[coverB] = Data()
    loader.show(trackID: "track:b")
    await settle()
    #expect(loader.imageData == nil)

    platform.replies = [("track:c", coverA.absoluteString)]
    platform.images[coverA] = Data(count: SpotifyArtwork.maximumBytes + 1)
    loader.show(trackID: "track:c")
    await settle()
    #expect(loader.imageData == nil)
}
