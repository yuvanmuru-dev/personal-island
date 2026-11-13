import Combine
import Foundation
import Testing
@testable import PersonalIslandPresentation

private let downloading = "NSProgressFileOperationKindDownloading"
private let receiving = "NSProgressFileOperationKindReceiving"
private let folder = URL(fileURLWithPath: "/tmp/fixture-downloads", isDirectory: true)

@Test func onlyAirDropIsFollowed() {
    #expect(Transfers.isAirDrop(operation: receiving))
    #expect(!Transfers.isAirDrop(operation: downloading))
    #expect(!Transfers.isAirDrop(operation: "NSProgressFileOperationKindDecompressingAfterDownloading"))
    #expect(!Transfers.isAirDrop(operation: "NSProgressFileOperationKindCopying"))
    #expect(!Transfers.isAirDrop(operation: nil))
}

@Test func namesAreCleanedAndBounded() {
    #expect(Transfers.displayName(for: folder.appendingPathComponent("photo.HEIC")) == "photo.HEIC")
    #expect(Transfers.displayName(for: folder.appendingPathComponent("a\u{0007}b.zip")) == "ab.zip")
    #expect(Transfers.displayName(for: folder.appendingPathComponent(String(repeating: "x", count: 300))).count == 121)
}

@Test func speedIsSmoothedAndTextReadsNaturally() {
    #expect(Transfers.speed(previous: nil, bytes: 1_000, seconds: 1) == 1_000)
    #expect(Transfers.speed(previous: 1_000, bytes: 4_000, seconds: 1) == 2_000)
    #expect(Transfers.speed(previous: 500, bytes: 100, seconds: 0) == 500)
    #expect(Transfers.speed(previous: 500, bytes: -5, seconds: 1) == 500)
    #expect(Transfers.remainingText(30) == "30 sec left")
    #expect(Transfers.remainingText(150) == "3 min left")
    #expect(Transfers.remainingText(3_900) == "1 hr 5 min left")
    #expect(Transfers.remainingText(.infinity) == nil)
    var transfer = Transfer(id: UUID(), name: "a", fileURL: folder, isCancellable: true,
                            startedAt: Date(timeIntervalSinceReferenceDate: 0))
    transfer.completedBytes = 50
    transfer.totalBytes = 200
    transfer.bytesPerSecond = 10
    #expect(transfer.fraction == 0.25 && transfer.secondsRemaining == 15)
    transfer.totalBytes = nil
    #expect(transfer.fraction == nil && transfer.secondsRemaining == nil)
}

// MARK: - Following transfers

private final class Flag: @unchecked Sendable { var cancelled = false }

@MainActor
private final class FakeProgress {
    var handler: (@MainActor (TransferEvent) -> Void)?
    var subscriptions = 0
    var unsubscriptions = 0
    var cancelled: [UUID] = []
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var updates: [(action: @MainActor () -> Void, flag: Flag)] = []

    func controller() -> TransferController {
        TransferController(environment: .init(
            subscribe: { [unowned self] handler in
                self.handler = handler
                self.subscriptions += 1
                return NSObject()
            },
            unsubscribe: { [unowned self] _ in self.unsubscriptions += 1 },
            cancel: { [unowned self] id in self.cancelled.append(id) },
            now: { [unowned self] in self.now },
            schedule: { [unowned self] _, action in
                let flag = Flag()
                self.updates.append((action, flag))
                return AnyCancellable { flag.cancelled = true }
            }
        ))
    }

    func send(_ event: TransferEvent) { handler?(event) }

    func flush() {
        let pending = updates.filter { !$0.flag.cancelled }
        updates = []
        pending.forEach { $0.action() }
    }
}

@Test @MainActor func anAirDropIsFollowedFromStartToFinish() {
    let platform = FakeProgress()
    let controller = platform.controller()
    var finished: [String] = []
    var changes = 0
    controller.onChange = { changes += 1 }
    controller.onFinish = { finished.append($0.name) }
    controller.start()
    let id = UUID()
    platform.send(.started(id: id, fileURL: folder.appendingPathComponent("Report.pdf"),
                           operation: receiving, cancellable: true))
    #expect(controller.active.map(\.name) == ["Report.pdf"])
    platform.now = platform.now.addingTimeInterval(1)
    platform.send(.progressed(id: id, completed: 500, total: 1_000))
    platform.send(.progressed(id: id, completed: 600, total: 1_000))   // coalesced
    #expect(platform.updates.count == 1)
    let before = changes
    platform.flush()
    #expect(changes == before + 1)
    #expect(controller.transfers[0].fraction == 0.6)
    #expect(controller.transfers[0].bytesPerSecond == 500)
    platform.send(.progressed(id: id, completed: 1_000, total: 1_000))   // final numbers, then the end
    platform.send(.ended(id: id, cancelled: false))
    #expect(controller.active.isEmpty && controller.transfers[0].state == .finished)
    #expect(controller.transfers[0].completedBytes == 1_000)
    #expect(finished == ["Report.pdf"])
}

@Test @MainActor func onlyAnActualCancelCountsAsStopped() {
    let platform = FakeProgress()
    let controller = platform.controller()
    var finished = 0
    controller.onFinish = { _ in finished += 1 }
    controller.start()
    let a = UUID(), b = UUID()
    platform.send(.started(id: a, fileURL: folder.appendingPathComponent("a.zip"), operation: receiving, cancellable: true))
    platform.send(.started(id: b, fileURL: folder.appendingPathComponent("b.zip"), operation: receiving, cancellable: false))
    platform.send(.progressed(id: b, completed: 10, total: 100))
    controller.cancel(a)
    controller.cancel(b)                                                    // this one can't be cancelled
    #expect(platform.cancelled == [a])
    platform.send(.ended(id: a, cancelled: true))
    #expect(finished == 0)
    // Ending short of the reported total without a cancel still counts as
    // received: senders don't always report the last bytes.
    platform.send(.ended(id: b, cancelled: false))
    #expect(Set(controller.transfers.map(\.state)) == [.cancelled, .finished])
    #expect(finished == 1)
}

@Test @MainActor func aLateProgressUpdateAfterTheEndChangesNothing() {
    let platform = FakeProgress()
    let controller = platform.controller()
    controller.start()
    let id = UUID()
    platform.send(.started(id: id, fileURL: folder.appendingPathComponent("a.zip"), operation: receiving, cancellable: true))
    platform.send(.progressed(id: id, completed: 1_000, total: 1_000))
    platform.send(.ended(id: id, cancelled: false))
    platform.send(.progressed(id: id, completed: 10, total: 1_000))         // queued update delivered late
    #expect(controller.transfers[0].state == .finished && controller.transfers[0].completedBytes == 1_000)
}

@Test @MainActor func browserDownloadsCopiesUnknownAndRepeatedEventsAreIgnored() {
    let platform = FakeProgress()
    let controller = platform.controller()
    controller.start()
    let id = UUID()
    platform.send(.started(id: id, fileURL: folder.appendingPathComponent("setup.dmg.crdownload"),
                           operation: downloading, cancellable: true))
    platform.send(.started(id: UUID(), fileURL: folder.appendingPathComponent("copy.txt"),
                           operation: "NSProgressFileOperationKindCopying", cancellable: true))
    platform.send(.progressed(id: id, completed: 5, total: 10))
    platform.send(.ended(id: id, cancelled: false))
    platform.send(.progressed(id: UUID(), completed: 5, total: 10))
    #expect(controller.transfers.isEmpty)
    let real = UUID()
    platform.send(.started(id: real, fileURL: folder.appendingPathComponent("x"), operation: receiving, cancellable: true))
    platform.send(.started(id: real, fileURL: folder.appendingPathComponent("x"), operation: receiving, cancellable: true))
    platform.send(.ended(id: real, cancelled: false))
    platform.send(.ended(id: real, cancelled: false))
    #expect(controller.transfers.count == 1)
}

@Test @MainActor func activeTransfersComeFirstAndRecentOnesAreBoundedAndExpire() {
    let platform = FakeProgress()
    let controller = platform.controller()
    controller.start()
    for index in 0..<(Transfers.maximumRecent + 3) {
        let id = UUID()
        platform.send(.started(id: id, fileURL: folder.appendingPathComponent("f\(index)"), operation: receiving, cancellable: true))
        platform.send(.ended(id: id, cancelled: false))
    }
    let running = UUID()
    platform.send(.started(id: running, fileURL: folder.appendingPathComponent("running"), operation: receiving, cancellable: true))
    #expect(controller.transfers.first?.id == running)
    #expect(controller.transfers.count == Transfers.maximumRecent + 1)
    #expect(controller.transfers[1].name == "f\(Transfers.maximumRecent + 2)")    // newest finished next
    platform.now = platform.now.addingTimeInterval(Transfers.recentLifetime + 1)
    let late = UUID()
    platform.send(.started(id: late, fileURL: folder.appendingPathComponent("late"), operation: receiving, cancellable: true))
    platform.send(.ended(id: late, cancelled: false))
    #expect(controller.transfers.map(\.name) == ["running", "late"])
    controller.clearRecent()
    #expect(controller.transfers.map(\.name) == ["running"])
}

@Test @MainActor func stoppingUnsubscribesForgetsTheListAndIgnoresLateEvents() {
    let platform = FakeProgress()
    let controller = platform.controller()
    controller.start()
    controller.start()
    #expect(platform.subscriptions == 1)
    let id = UUID()
    platform.send(.started(id: id, fileURL: folder.appendingPathComponent("a"), operation: receiving, cancellable: true))
    platform.send(.progressed(id: id, completed: 1, total: 2))
    controller.stop()
    controller.stop()
    #expect(platform.unsubscriptions == 1 && controller.transfers.isEmpty)
    var changes = 0
    controller.onChange = { changes += 1 }
    platform.send(.ended(id: id, cancelled: false))                        // late unpublish after stop
    platform.flush()                                                       // cancelled coalesced update
    #expect(controller.transfers.isEmpty && changes == 0)
}
