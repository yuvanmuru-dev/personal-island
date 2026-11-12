import Combine
import Foundation
import Testing
@testable import PersonalIslandPresentation

private let date = Date(timeIntervalSinceReferenceDate: 0)

@Test func passwordManagerAndTransientCopiesAreSkippedByTypeAlone() {
    #expect(ClipboardHistory.isSkipped(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
    #expect(ClipboardHistory.isSkipped(types: ["com.agilebits.onepassword"]))
    #expect(ClipboardHistory.isSkipped(types: ["org.nspasteboard.TransientType"]))
    #expect(!ClipboardHistory.isSkipped(types: ["public.utf8-plain-text", "public.html"]))
    #expect(!ClipboardHistory.isSkipped(types: []))
}

@Test func aSingleWebAddressBecomesALinkAndEverythingElseStaysText() {
    #expect(ClipboardHistory.content(fromText: " https://example.com/a?b=1 \n") == .link(URL(string: "https://example.com/a?b=1")!))
    #expect(ClipboardHistory.content(fromText: "see https://example.com") == .text("see https://example.com"))
    #expect(ClipboardHistory.content(fromText: "javascript:alert(1)") == .text("javascript:alert(1)"))
    #expect(ClipboardHistory.content(fromText: "file:///etc/hosts") == .text("file:///etc/hosts"))
    #expect(ClipboardHistory.content(fromText: "https://") == .text("https://"))
}

@Test func newestFirstDuplicatesMoveUpAndTheListIsBounded() {
    var items: [ClipboardItem] = []
    items = ClipboardHistory.adding(.text("a"), at: date, sourceApp: "Notes", to: items)
    items = ClipboardHistory.adding(.text("b"), at: date.addingTimeInterval(1), sourceApp: nil, to: items)
    let firstID = items[1].id
    items = ClipboardHistory.adding(.text("a"), at: date.addingTimeInterval(2), sourceApp: nil, to: items)
    #expect(items.map(\.content) == [.text("a"), .text("b")])
    #expect(items[0].id == firstID && items[0].sourceApp == "Notes")
    #expect(items[0].copiedAt == date.addingTimeInterval(2))
    for index in 0..<(ClipboardHistory.maximumItems + 10) {
        items = ClipboardHistory.adding(.text("item \(index)"), at: date, sourceApp: nil, to: items)
    }
    #expect(items.count == ClipboardHistory.maximumItems)
    #expect(items.first?.content == .text("item \(ClipboardHistory.maximumItems + 9)"))
}

@Test func emptyOversizedAndUnsafeContentIsRefusedOrCut() {
    #expect(ClipboardHistory.adding(.text("  \n\t"), at: date, sourceApp: nil, to: []).isEmpty)
    #expect(ClipboardHistory.adding(.image(Data(), width: 0, height: 0), at: date, sourceApp: nil, to: []).isEmpty)
    let huge = Data(count: ClipboardHistory.maximumImageBytes + 1)
    #expect(ClipboardHistory.adding(.image(huge, width: 1, height: 1), at: date, sourceApp: nil, to: []).isEmpty)
    let long = String(repeating: "x", count: ClipboardHistory.maximumTextLength + 50)
    let cut = ClipboardHistory.adding(.text(long), at: date, sourceApp: nil, to: [])
    #expect(cut.first?.content.byteCount == ClipboardHistory.maximumTextLength)
    #expect(ClipboardHistory.adding(.files([URL(string: "https://example.com")!]), at: date, sourceApp: nil, to: []).isEmpty)
    #expect(ClipboardHistory.bounded(.link(URL(string: "ftp://example.com")!)) == .text("ftp://example.com"))
}

@Test func imagesBeyondTheTotalBudgetAreDroppedOldestFirst() {
    let size = ClipboardHistory.maximumImageBytes
    var items: [ClipboardItem] = []
    for index in 0..<10 {
        var data = Data(count: size)
        data[0] = UInt8(index)
        items = ClipboardHistory.adding(.image(data, width: 1, height: 1), at: date, sourceApp: nil, to: items)
        items = ClipboardHistory.adding(.text("t\(index)"), at: date, sourceApp: nil, to: items)
    }
    let imageBytes = items.reduce(0) { total, item in
        if case .image(let data, _, _) = item.content { return total + data.count }
        return total
    }
    #expect(imageBytes <= ClipboardHistory.maximumTotalImageBytes)
    #expect(items.filter { if case .text = $0.content { true } else { false } }.count == 10)
    if case .image(let data, _, _) = items[1].content { #expect(data[0] == 9) } else { Issue.record("newest image dropped") }
}

@Test func searchIgnoresCaseAndAccentsAndCoversSourcesAndFileNames() {
    let items = [
        ClipboardItem(id: UUID(), content: .text("Crème brûlée recipe"), copiedAt: date, sourceApp: "Safari"),
        ClipboardItem(id: UUID(), content: .files([URL(fileURLWithPath: "/tmp/Report.pdf")]), copiedAt: date, sourceApp: nil),
    ]
    #expect(items.filter { ClipboardHistory.matches($0, query: "creme") }.count == 1)
    #expect(items.filter { ClipboardHistory.matches($0, query: "report") }.count == 1)
    #expect(items.filter { ClipboardHistory.matches($0, query: "safari") }.count == 1)
    #expect(items.filter { ClipboardHistory.matches($0, query: "  ") }.count == 2)
    #expect(ClipboardHistory.preview(.text("a\n\n  b\tc")) == "a b c")
    #expect(ClipboardHistory.preview(.files([URL(fileURLWithPath: "/a/x.txt"), URL(fileURLWithPath: "/a/y.txt")])) == "x.txt and 1 more")
}

// MARK: - Watching lifecycle

private final class Flag: @unchecked Sendable { var cancelled = false }

@MainActor
private final class FakePasteboard {
    var changeCount = 10
    var access: ClipboardAccess = .allowed
    var next: ClipboardRead = .content(.text("hello"))
    var reads = 0
    var writes: [ClipboardContent] = []
    var ticks: [(action: @MainActor () -> Void, flag: Flag)] = []

    func controller() -> ClipboardController {
        ClipboardController(environment: .init(
            changeCount: { [unowned self] in self.changeCount },
            access: { [unowned self] in self.access },
            read: { [unowned self] in
                self.reads += 1
                return self.next
            },
            write: { [unowned self] content in
                self.writes.append(content)
                self.changeCount += 1
                return self.changeCount
            },
            frontmostApp: { "Notes" },
            now: { date },
            repeating: { [unowned self] _, action in
                let flag = Flag()
                self.ticks.append((action, flag))
                return AnyCancellable { flag.cancelled = true }
            }
        ))
    }

    var running: Int { ticks.filter { !$0.flag.cancelled }.count }

    func copy(_ read: ClipboardRead) {
        changeCount += 1
        next = read
        ticks.last?.action()
    }
}

@Test @MainActor func onlyCopiesMadeAfterStartingAreRecordedAndOnlyWhenChanged() {
    let board = FakePasteboard()
    let controller = board.controller()
    controller.start()
    board.ticks[0].action()
    #expect(board.reads == 0 && controller.items.isEmpty)   // existing clipboard untouched
    board.copy(.content(.text("first")))
    board.ticks[0].action()                                  // no new change
    #expect(board.reads == 1)
    #expect(controller.items.map(\.content) == [.text("first")])
    #expect(controller.items.first?.sourceApp == "Notes")
    #expect(controller.status == .recording)
}

@Test @MainActor func concealedCopiesAreNeverStored() {
    let board = FakePasteboard()
    let controller = board.controller()
    controller.start()
    board.copy(.skipped)
    board.copy(.unsupported)
    #expect(controller.items.isEmpty)
}

@Test @MainActor func copiesWhilePausedOrWithoutAccessAreNeverReadEvenLater() {
    let board = FakePasteboard()
    let controller = board.controller()
    controller.start()
    controller.setPaused(true)
    #expect(controller.status == .paused)
    board.copy(.content(.text("while paused")))
    controller.setPaused(false)
    board.ticks[0].action()
    #expect(board.reads == 0 && controller.items.isEmpty)

    board.access = .asksEachTime
    board.copy(.content(.text("would prompt")))
    #expect(controller.status == .needsAccess && board.reads == 0)
    board.access = .denied
    board.copy(.content(.text("denied")))
    #expect(board.reads == 0)
    board.access = .allowed
    board.ticks[0].action()
    #expect(controller.status == .recording && board.reads == 0)   // missed copies stay unread
    board.copy(.content(.text("allowed")))
    #expect(controller.items.map(\.content) == [.text("allowed")])
}

@Test @MainActor func copyingBackMovesTheItemUpWithoutRecordingItAgain() {
    let board = FakePasteboard()
    let controller = board.controller()
    controller.start()
    board.copy(.content(.text("a")))
    board.copy(.content(.text("b")))
    let a = controller.items[1].id
    #expect(controller.copyBack(a))
    #expect(board.writes == [.text("a")])
    board.ticks[0].action()
    #expect(board.reads == 2)
    #expect(controller.items.map(\.content) == [.text("a"), .text("b")])
    #expect(!controller.copyBack(UUID()))
}

@Test @MainActor func removeClearAndStopForgetTheHistoryAndStopWatching() {
    let board = FakePasteboard()
    let controller = board.controller()
    controller.start()
    controller.start()
    #expect(board.running == 1)
    board.copy(.content(.text("a")))
    board.copy(.content(.text("b")))
    controller.remove(controller.items[0].id)
    #expect(controller.items.map(\.content) == [.text("a")])
    controller.clear()
    #expect(controller.items.isEmpty)
    board.copy(.content(.text("c")))
    controller.stop()
    #expect(board.running == 0 && controller.items.isEmpty && controller.status == .off)
    let reads = board.reads
    board.changeCount += 1
    board.ticks[0].action()                                   // stale tick after stop
    #expect(board.reads == reads && controller.items.isEmpty)
}

// MARK: - Opened view

@Test func theOpenedViewShowsEverythingUpToALimitAndSaysWhenItIsCut() {
    let short = ClipboardHistory.displayText(.text("line one\nline two"))
    #expect(short.text == "line one\nline two" && !short.isCut)   // line breaks kept, unlike the preview
    let long = String(repeating: "a", count: ClipboardHistory.displayLimit + 5)
    let shown = ClipboardHistory.displayText(.text(long))
    #expect(shown.isCut && shown.text.count == ClipboardHistory.displayLimit)
    let files = ClipboardHistory.displayText(.files([URL(fileURLWithPath: "/a/x.txt"), URL(fileURLWithPath: "/b/y.txt")]))
    #expect(files.text == "/a/x.txt\n/b/y.txt")
    #expect(ClipboardHistory.displayText(.link(URL(string: "https://example.com/a")!)).text == "https://example.com/a")
}

@Test func sizesDescribeWhatWasCopied() {
    #expect(ClipboardHistory.sizeDescription(.text("a")) == "1 character")
    #expect(ClipboardHistory.sizeDescription(.text("hello")) == "5 characters")
    #expect(ClipboardHistory.sizeDescription(.files([URL(fileURLWithPath: "/a")])) == "1 file")
    #expect(ClipboardHistory.sizeDescription(.link(URL(string: "https://example.com")!)) == nil)
    #expect(ClipboardHistory.sizeDescription(.image(Data(count: 2_000), width: 1, height: 1)) != nil)
}

@Test @MainActor func copyingAnOpenedItemKeepsItsIdentity() {
    let board = FakePasteboard()
    let controller = board.controller()
    controller.start()
    board.copy(.content(.text("long text")))
    board.copy(.content(.text("newer")))
    let opened = controller.items[1].id
    #expect(controller.copyBack(opened))
    #expect(controller.items.first?.id == opened)   // the opened view stays on the same item
}
