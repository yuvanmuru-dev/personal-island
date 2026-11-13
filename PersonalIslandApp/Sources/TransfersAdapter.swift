/*
 * Personal Island — AirDrop progress adapter.
 * Written for this personal project; no upstream file copied.
 */

import AppKit
import Combine

/// Real platform access for `TransferController`, using the public file
/// progress that Finder also shows: AirDrop publishes a Progress for each
/// file it receives into Downloads, and this subscribes to those (browser
/// downloads in the same folder are ignored). The folder is never listed or
/// read. Cancel only forwards the user's request to AirDrop.
@MainActor
final class TransfersAdapter {
    private var observed: [UUID: Observed] = [:]
    /// The folder to follow; Downloads unless a check passes a scratch folder.
    private let folder: URL?

    init(folder: URL? = TransfersAdapter.downloadsFolder) {
        self.folder = folder
    }

    private final class Observed {
        let progress: Progress
        var observations: [NSKeyValueObservation] = []
        init(progress: Progress) { self.progress = progress }
    }

    private final class Subscription {
        let token: Any
        init(token: Any) { self.token = token }
    }

    func environment() -> TransferController.Environment {
        TransferController.Environment(
            subscribe: { [weak self] handler in self?.subscribe(handler) },
            unsubscribe: { [weak self] token in self?.unsubscribe(token) },
            cancel: { [weak self] id in self?.observed[id]?.progress.cancel() },
            now: { Date() },
            schedule: { delay, action in
                let timer = Timer(timeInterval: delay, repeats: false) { _ in
                    MainActor.assumeIsolated { action() }
                }
                RunLoop.main.add(timer, forMode: .common)
                return AnyCancellable { timer.invalidate() }
            }
        )
    }

    nonisolated static var downloadsFolder: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private func subscribe(_ handler: @escaping @MainActor (TransferEvent) -> Void) -> AnyObject? {
        guard let folder else { return nil }
        let token = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            // Documented to run on the main thread, as does the returned block.
            MainActor.assumeIsolated {
                guard let self else { return nil }
                return self.began(progress, handler: handler)
            }
        }
        return Subscription(token: token)
    }

    private func began(_ progress: Progress,
                       handler: @escaping @MainActor (TransferEvent) -> Void) -> Progress.UnpublishingHandler? {
        let id = UUID()
        let url = progress.userInfo[.fileURLKey] as? URL ?? progress.fileURL
        let operation = (progress.userInfo[.fileOperationKindKey] as? Progress.FileOperationKind)?.rawValue
            ?? progress.userInfo[.fileOperationKindKey] as? String
        guard let url, Transfers.isAirDrop(operation: operation) else { return nil }
        let entry = Observed(progress: progress)
        observed[id] = entry
        handler(.started(id: id, fileURL: url, operation: operation, cancellable: progress.isCancellable))
        let report: @Sendable (Progress) -> Void = { progress in
            let completed = progress.completedUnitCount, total = progress.totalUnitCount
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(.progressed(id: id, completed: completed, total: total)) }
            }
        }
        entry.observations = [
            progress.observe(\.completedUnitCount, options: [.initial]) { progress, _ in report(progress) },
            progress.observe(\.totalUnitCount) { progress, _ in report(progress) },
        ]
        return { [weak self] in
            MainActor.assumeIsolated {
                let cancelled = progress.isCancelled
                self?.observed.removeValue(forKey: id)?.observations.forEach { $0.invalidate() }
                // Progress updates are delivered asynchronously and may still be
                // queued; report the final numbers first so a complete download
                // is never mistaken for an interrupted one.
                handler(.progressed(id: id, completed: progress.completedUnitCount, total: progress.totalUnitCount))
                handler(.ended(id: id, cancelled: cancelled))
            }
        }
    }

    private func unsubscribe(_ token: AnyObject) {
        for entry in observed.values { entry.observations.forEach { $0.invalidate() } }
        observed = [:]
        if let subscription = token as? Subscription { Progress.removeSubscriber(subscription.token) }
    }

    /// Explicit user action: reveals the finished file, or the folder if the
    /// file has since been moved.
    static func showInFinder(_ transfer: Transfer) {
        if FileManager.default.fileExists(atPath: transfer.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([transfer.fileURL])
        } else {
            NSWorkspace.shared.open(transfer.fileURL.deletingLastPathComponent())
        }
    }
}
