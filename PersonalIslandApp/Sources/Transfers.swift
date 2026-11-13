/*
 * Personal Island — AirDrop progress model and lifecycle.
 * Written for this personal project; no upstream file copied.
 * Progress comes from what AirDrop publishes for files it receives into
 * Downloads; browser downloads are ignored and the folder is never read.
 */

import Combine
import Foundation

enum TransferState: Equatable {
    case active
    case finished
    case cancelled
}

struct Transfer: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// Where the received file is, for Show in Finder.
    let fileURL: URL
    let isCancellable: Bool
    var completedBytes: Int64 = 0
    /// nil while the size is unknown.
    var totalBytes: Int64?
    var state: TransferState = .active
    let startedAt: Date
    var endedAt: Date?
    /// Bytes per second, smoothed; nil until there is enough to measure.
    var bytesPerSecond: Double?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    /// Seconds left at the current speed.
    var secondsRemaining: Double? {
        guard state == .active, let totalBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return max(0, Double(totalBytes - completedBytes) / bytesPerSecond)
    }
}

/// What the platform reports about one published progress.
enum TransferEvent: Equatable {
    case started(id: UUID, fileURL: URL, operation: String?, cancellable: Bool)
    case progressed(id: UUID, completed: Int64, total: Int64)
    case ended(id: UUID, cancelled: Bool)
}

enum Transfers {
    /// Finished and cancelled transfers listed, newest first.
    static let maximumRecent = 10
    /// How long the list keeps a finished transfer.
    static let recentLifetime: TimeInterval = 30 * 60
    /// UI updates are coalesced to at most this often.
    static let updateInterval: TimeInterval = 0.25

    /// AirDrop publishes "receiving"; browser downloads, copies and uploads
    /// in Downloads are ignored.
    static func isAirDrop(operation: String?) -> Bool {
        operation == "NSProgressFileOperationKindReceiving"
    }

    /// Bounded, control-character-free display name.
    static func displayName(for url: URL) -> String {
        let scalars = url.lastPathComponent.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let name = String(String.UnicodeScalarView(scalars))
        guard !name.isEmpty else { return "File" }
        return name.count > 120 ? String(name.prefix(120)) + "…" : name
    }

    /// Smoothed speed: new readings move the estimate a third of the way.
    static func speed(previous: Double?, bytes: Int64, seconds: TimeInterval) -> Double? {
        guard bytes >= 0, seconds > 0.05, seconds.isFinite else { return previous }
        let sample = Double(bytes) / seconds
        guard let previous else { return sample }
        return previous + (sample - previous) / 3
    }

    /// "12 MB of 45 MB", "12 MB" when the size is unknown.
    static func sizeText(_ transfer: Transfer) -> String {
        let done = ByteCountFormatter.string(fromByteCount: transfer.completedBytes, countStyle: .file)
        guard let total = transfer.totalBytes, total > 0 else { return done }
        return done + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// "2 min left", "40 sec left".
    static func remainingText(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite else { return nil }
        if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) sec left" }
        if seconds < 3_600 { return "\(Int((seconds / 60).rounded())) min left" }
        return "\(Int(seconds / 3_600)) hr \(Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)) min left"
    }
}

/// Follows AirDrop transfers while the switch is on. Platform access is injected so
/// tests never subscribe to real progress or touch the Downloads folder.
@MainActor
final class TransferController {
    struct Environment {
        /// Starts receiving events for files arriving in Downloads.
        var subscribe: @MainActor (_ handler: @escaping @MainActor (TransferEvent) -> Void) -> AnyObject?
        var unsubscribe: @MainActor (AnyObject) -> Void
        /// Asks the sending app to cancel; it reports the end itself.
        var cancel: @MainActor (UUID) -> Void
        var now: @MainActor () -> Date
        var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable
    }

    /// Active transfers first (oldest first), then recent ones (newest first).
    private(set) var transfers: [Transfer] = []
    var onChange: (@MainActor () -> Void)?
    /// Called once when a file is received (not when cancelled).
    var onFinish: (@MainActor (Transfer) -> Void)?

    private let environment: Environment
    private var subscription: AnyObject?
    private var isRunning = false
    private var generation = 0
    private var pendingUpdate: AnyCancellable?
    private var lastSample: [UUID: (bytes: Int64, at: Date)] = [:]

    init(environment: Environment) {
        self.environment = environment
    }

    var active: [Transfer] { transfers.filter { $0.state == .active } }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let session = generation
        subscription = environment.subscribe { [weak self] event in
            guard let self, session == self.generation else { return }
            self.handle(event)
        }
    }

    /// Stops following transfers and forgets the list. Transfers themselves
    /// continue in their apps.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        if let subscription { environment.unsubscribe(subscription) }
        subscription = nil
        pendingUpdate?.cancel()
        pendingUpdate = nil
        lastSample = [:]
        let changed = !transfers.isEmpty
        transfers = []
        if changed { onChange?() }
    }

    func cancel(_ id: UUID) {
        guard let transfer = transfers.first(where: { $0.id == id }),
              transfer.state == .active, transfer.isCancellable else { return }
        environment.cancel(id)
    }

    /// Removes finished and cancelled transfers from the list.
    func clearRecent() {
        let kept = transfers.filter { $0.state == .active }
        guard kept != transfers else { return }
        transfers = kept
        onChange?()
    }

    private func handle(_ event: TransferEvent) {
        let now = environment.now()
        switch event {
        case .started(let id, let url, let operation, let cancellable):
            guard Transfers.isAirDrop(operation: operation),
                  !transfers.contains(where: { $0.id == id }) else { return }
            transfers.insert(Transfer(id: id, name: Transfers.displayName(for: url), fileURL: url,
                                      isCancellable: cancellable, startedAt: now),
                             at: active.count)
            lastSample[id] = (0, now)
            onChange?()
        case .progressed(let id, let completed, let total):
            guard let index = transfers.firstIndex(where: { $0.id == id && $0.state == .active }) else { return }
            var transfer = transfers[index]
            transfer.completedBytes = max(0, completed)
            transfer.totalBytes = total > 0 ? total : nil
            if let sample = lastSample[id], now.timeIntervalSince(sample.at) >= 0.5 {
                transfer.bytesPerSecond = Transfers.speed(previous: transfer.bytesPerSecond,
                                                          bytes: transfer.completedBytes - sample.bytes,
                                                          seconds: now.timeIntervalSince(sample.at))
                lastSample[id] = (transfer.completedBytes, now)
            }
            transfers[index] = transfer
            scheduleUpdate()
        case .ended(let id, let cancelled):
            guard let index = transfers.firstIndex(where: { $0.id == id && $0.state == .active }) else { return }
            var transfer = transfers.remove(at: index)
            // Senders can end short of the reported total (or report no
            // total), so only an actual cancel counts as stopped.
            let complete = !cancelled
            transfer.state = complete ? .finished : .cancelled
            transfer.endedAt = now
            transfer.bytesPerSecond = nil
            if complete, let total = transfer.totalBytes { transfer.completedBytes = total }
            lastSample[id] = nil
            transfers.insert(transfer, at: active.count)
            pruneRecent(now: now)
            onChange?()
            if complete { onFinish?(transfer) }
        }
    }

    /// Progress can arrive many times a second; the island redraws at most
    /// four times a second.
    private func scheduleUpdate() {
        guard pendingUpdate == nil else { return }
        let session = generation
        pendingUpdate = environment.schedule(Transfers.updateInterval) { [weak self] in
            guard let self, session == self.generation else { return }
            self.pendingUpdate = nil
            self.onChange?()
        }
    }

    private func pruneRecent(now: Date) {
        var recentCount = 0
        transfers = transfers.filter { transfer in
            guard transfer.state != .active else { return true }
            recentCount += 1
            let fresh = now.timeIntervalSince(transfer.endedAt ?? now) < Transfers.recentLifetime
            return fresh && recentCount <= Transfers.maximumRecent
        }
    }
}
