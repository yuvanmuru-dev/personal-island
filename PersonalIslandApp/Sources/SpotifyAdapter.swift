/*
 * Personal Island — Spotify platform adapter.
 * Written for this personal project; no upstream file copied.
 * Apple Event codes come from Spotify's own scripting dictionary
 * (Spotify.app/Contents/Resources/Spotify.sdef, Spotify 1.3.8).
 */

import AppKit
import CoreServices
import os

/// Real platform access for `SpotifyController`. Apple Events go only to
/// Spotify, only while the feature is on, and never launch it. Every call
/// runs off the main thread under a hard deadline, so neither a busy Spotify
/// nor a stalled system service can freeze the feature.
enum SpotifyAdapter {
    /// Result codes only (never track, artist or account details), so a
    /// failing check can be diagnosed from the system log.
    private static let log = Logger(subsystem: "dev.personal.PersonalIsland", category: "spotify")

    @MainActor
    static func environment() -> SpotifyController.Environment {
        SpotifyController.Environment(
            isRunning: { isRunning() },
            permission: { ask in
                // Asking waits for the user to answer the system dialog.
                let result = await Deadline.run(seconds: ask ? askTimeout + 10 : quickTimeout + 3, fallback: .noAnswer) {
                    probe(askIfNeeded: ask)
                }
                log.info("permission result (ask: \(ask, privacy: .public)): \(String(describing: result), privacy: .public)")
                return result
            },
            snapshot: {
                try await Deadline.run(seconds: 12, fallback: .failure(.unexpectedReply)) {
                    Result { try snapshot() }.mapError { $0 as? SpotifyError ?? .unexpectedReply }
                }.get()
            },
            send: { command in
                try await Deadline.run(seconds: quickTimeout + 3, fallback: .failure(.unexpectedReply)) {
                    Result { try send(command) }.mapError { $0 as? SpotifyError ?? .unexpectedReply }
                }.get()
            },
            observe: { handler in Observation(handler: handler) },
            stopObserving: { token in (token as? Observation)?.invalidate() },
            now: { Date() },
            settle: { try? await Task.sleep(for: .milliseconds(700)) }
        )
    }

    /// Artwork lookups go to Spotify like the other Apple Events; downloads
    /// go only to Spotify's image host (see SpotifyArtwork.validatedURL).
    @MainActor
    static func artworkEnvironment() -> SpotifyArtworkLoader.Environment {
        SpotifyArtworkLoader.Environment(
            lookup: {
                guard isRunning() else { return (nil, nil) }
                let reply = await Deadline.run(seconds: quickTimeout + 3, fallback: ArtworkReply(trackID: nil, url: nil)) {
                    artworkReply()
                }
                return (reply.trackID, reply.url)
            },
            fetch: { url in await ArtworkDownload.fetch(url) },
            retryDelay: { try? await Task.sleep(for: .milliseconds(800)) }
        )
    }

    private struct ArtworkReply: Sendable {
        let trackID: String?
        let url: String?
    }

    private static func artworkReply() -> ArtworkReply {
        let track = property("pTrk", of: .null())
        let id = try? get(property("ID  ", of: track))?.stringValue
        let url = try? get(property("aUrl", of: track))?.stringValue
        return ArtworkReply(trackID: SpotifyPlayback.clean(id), url: url)
    }

    @MainActor
    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyPlayback.bundleIdentifier).isEmpty
    }

    // MARK: Observation

    /// Spotify's playback notification plus Spotify launch/quit. Receiving
    /// these needs no permission; nothing else is observed.
    @MainActor
    private final class Observation: NSObject {
        private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []

        init(handler: @escaping @MainActor (SpotifyEvent) -> Void) {
            super.init()
            let distributed = DistributedNotificationCenter.default()
            tokens.append((distributed, distributed.addObserver(
                forName: Notification.Name(SpotifyPlayback.notificationName), object: nil, queue: .main
            ) { notification in
                let info = notification.userInfo ?? [:]
                nonisolated(unsafe) let sendableInfo = info
                MainActor.assumeIsolated { handler(.playback(sendableInfo)) }
            }))
            let workspace = NSWorkspace.shared.notificationCenter
            for (name, launched) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                     (NSWorkspace.didTerminateApplicationNotification, false)] {
                tokens.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { notification in
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard app?.bundleIdentifier == SpotifyPlayback.bundleIdentifier else { return }
                    MainActor.assumeIsolated { handler(launched ? .launched : .terminated) }
                }))
            }
        }

        func invalidate() {
            for (center, token) in tokens { center.removeObserver(token) }
            tokens = []
        }
    }

    // MARK: Apple Events

    private static let quickTimeout: TimeInterval = 2
    private static let askTimeout: TimeInterval = 120

    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    private static var target: NSAppleEventDescriptor {
        NSAppleEventDescriptor(bundleIdentifier: SpotifyPlayback.bundleIdentifier)
    }

    /// Reads Spotify's player state to learn whether control is allowed.
    /// Without consent, "never interact" makes macOS answer at once instead of
    /// prompting. When asking, the read is sent normally: that is what shows
    /// the Automation dialog, and the call waits for the user's answer.
    /// (AEDeterminePermissionToAutomateTarget is not used: on this Mac it
    /// blocked indefinitely, so no dialog ever appeared.)
    private static func probe(askIfNeeded: Bool) -> SpotifyPermission {
        let request = event(class: "core", id: "getd")
        request.setParam(property("pPlS", of: .null()), forKeyword: AEKeyword(keyDirectObject))
        do {
            _ = try request.sendEvent(
                options: askIfNeeded ? [.waitForReply] : [.waitForReply, .neverInteract],
                timeout: askIfNeeded ? askTimeout : quickTimeout
            )
            log.info("permission check (ask: \(askIfNeeded, privacy: .public)): granted")
            return .granted
        } catch let error as NSError {
            log.error("permission check (ask: \(askIfNeeded, privacy: .public)) failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            switch error.code {
            case Int(errAEEventWouldRequireUserConsent): return .needsConsent
            case Int(errAEEventNotPermitted): return .denied
            case Int(procNotFound), Int(connectionInvalid): return .notRunning
            // A timeout or other failure says nothing about permission.
            default: return .noAnswer
            }
        }
    }

    private static func send(_ command: SpotifyCommand) throws {
        let id: String
        switch command {
        case .playPause: id = "PlPs"
        case .next: id = "Next"
        case .previous: id = "Prev"
        case .seek(let seconds):
            // `player position` is writable, in seconds.
            let request = event(class: "core", id: "setd")
            request.setParam(property("pPos", of: .null()), forKeyword: AEKeyword(keyDirectObject))
            request.setParam(NSAppleEventDescriptor(double: seconds), forKeyword: AEKeyword(keyAEData))
            _ = try perform(request)
            return
        }
        _ = try perform(event(class: "spfy", id: id))
    }

    private static func snapshot() throws -> SpotifyPlayback.Update {
        guard let state = try get(property("pPlS", of: .null()))?.enumCodeValue else {
            throw SpotifyError.unexpectedReply
        }
        let stateText: String
        switch state {
        case code("kPSP"): stateText = "Playing"
        case code("kPSp"): stateText = "Paused"
        case code("kPSS"): return .stopped
        default: throw SpotifyError.unexpectedReply
        }
        let track = property("pTrk", of: .null())
        func text(_ name: String) throws -> String? { try get(property(name, of: track))?.stringValue }
        let duration = try get(property("pDur", of: track))?.doubleValue
        let position = try get(property("pPos", of: .null()))?.doubleValue
        guard let update = SpotifyPlayback.update(
            state: stateText, trackID: try text("ID  "), title: try text("pnam"),
            artist: try text("pArt"), album: try text("pAlb"),
            // Spotify's dictionary says seconds, but it reports milliseconds,
            // matching its playback notification.
            durationMilliseconds: duration, position: position, at: Date()
        ) else { throw SpotifyError.unexpectedReply }
        return update
    }

    private static func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: AEKeyword(keyAEKeyData))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return specifier
    }

    private static func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        let request = event(class: "core", id: "getd")
        request.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        return try perform(request).paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
    }

    private static func event(class eventClass: String, id: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: code(eventClass), eventID: code(id), targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private static func perform(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        do {
            return try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: quickTimeout)
        } catch let error as NSError {
            log.error("Apple Event failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            switch error.code {
            case Int(procNotFound), Int(connectionInvalid): throw SpotifyError.notRunning
            case Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent): throw SpotifyError.notPermitted
            default: throw SpotifyError.unexpectedReply
            }
        }
    }
}

/// One ephemeral session: no cookies, credentials or disk cache, no
/// redirects, a short timeout and a size limit while reading.
private enum ArtworkDownload {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func fetch(_ url: URL) async -> Data? {
        guard SpotifyArtwork.validatedURL(url.absoluteString) != nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              SpotifyArtwork.isImage(mimeType: http.mimeType),
              http.expectedContentLength <= Int64(SpotifyArtwork.maximumBytes) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > SpotifyArtwork.maximumBytes { return nil }
            }
        } catch {
            return nil
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
