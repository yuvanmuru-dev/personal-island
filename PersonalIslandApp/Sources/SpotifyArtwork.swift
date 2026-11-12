/*
 * Personal Island — Spotify album artwork model and lifecycle.
 * Written for this personal project; no upstream file copied.
 */

import Foundation

enum SpotifyArtwork {
    /// Spotify's own image server; nothing else is ever contacted.
    static let allowedHosts: Set<String> = ["i.scdn.co"]
    static let maximumBytes = 2 * 1_024 * 1_024

    /// Accepts only a plain https URL on Spotify's image host, so a damaged
    /// or unexpected reply can never make the app contact another server.
    static func validatedURL(_ text: String?) -> URL? {
        guard let text, text.count <= 500, let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), allowedHosts.contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let url = components.url else { return nil }
        return url
    }

    /// Only common image types are decoded.
    static func isImage(mimeType: String?) -> Bool {
        guard let type = mimeType?.lowercased() else { return false }
        return ["image/jpeg", "image/png", "image/webp"].contains(type)
    }
}

/// Fetches the cover for the current track only. The image stays in memory
/// until the track changes or the feature stops; it is never written to disk.
@MainActor
final class SpotifyArtworkLoader {
    struct Environment {
        /// Asks Spotify for the current track's identifier and artwork URL.
        var lookup: @MainActor () async -> (trackID: String?, url: String?)
        /// Downloads at most `SpotifyArtwork.maximumBytes` of image data.
        var fetch: @MainActor (URL) async -> Data?
        /// Short wait before asking again when Spotify still reports the
        /// previous track.
        var retryDelay: @MainActor () async -> Void
    }

    private(set) var trackID: String?
    private(set) var imageData: Data?
    var onChange: (@MainActor () -> Void)?

    private let environment: Environment
    private var generation = 0
    private var task: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
    }

    /// Call whenever the current track may have changed. Repeats for the same
    /// track do nothing; nil clears the image.
    func show(trackID: String?) {
        guard trackID != self.trackID else { return }
        generation += 1
        task?.cancel()
        task = nil
        self.trackID = trackID
        if imageData != nil {
            imageData = nil
            onChange?()
        }
        guard let trackID else { return }
        let session = generation
        task = Task { @MainActor [weak self] in
            await self?.load(trackID, session: session)
        }
    }

    func stop() { show(trackID: nil) }

    private func load(_ trackID: String, session: Int) async {
        var reply = await environment.lookup()
        if reply.trackID != trackID {
            await environment.retryDelay()
            guard session == generation else { return }
            reply = await environment.lookup()
        }
        guard session == generation, reply.trackID == trackID,
              let url = SpotifyArtwork.validatedURL(reply.url) else { return }
        let data = await environment.fetch(url)
        guard session == generation, let data, !data.isEmpty,
              data.count <= SpotifyArtwork.maximumBytes else { return }
        imageData = data
        onChange?()
    }
}
