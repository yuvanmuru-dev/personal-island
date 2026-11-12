import CoreGraphics
import Foundation
import Testing
@testable import PersonalIslandPresentation

private func entry(_ id: Int, pid: Int = 100, layer: Int = 0, alpha: Double? = 1,
                   _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Any] {
    var value: [String: Any] = [
        kCGWindowNumber as String: id,
        kCGWindowOwnerPID as String: pid,
        kCGWindowLayer as String: layer,
        kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
    ]
    if let alpha { value[kCGWindowAlpha as String] = alpha }
    return value
}

@Test func windowListEntriesParseInOrderAndMalformedOnesAreSkipped() {
    var missingBounds = entry(9, 0, 0, 10, 10)
    missingBounds.removeValue(forKey: kCGWindowBounds as String)
    let parsed = WindowPicker.windows(from: [
        entry(3, 0, 25, 800, 600),
        missingBounds,
        entry(0, 0, 0, 100, 100),                       // invalid window number
        entry(5, 10, 10, 0, 100),                       // zero width
        entry(6, .nan, 0, 100, 100),                    // non-finite origin
        ["unexpected": "shape"],
        entry(7, pid: 200, layer: 25, alpha: nil, -1920, 0, 1920, 24),
    ])
    #expect(parsed == [
        WindowPicker.Window(id: 3, ownerPID: 100, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 25, width: 800, height: 600)),
        WindowPicker.Window(id: 7, ownerPID: 200, layer: 25, alpha: 1, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 24)),
    ])
}

@Test func theFrontmostOrdinaryWindowUnderThePointerWins() {
    let windows = WindowPicker.windows(from: [
        entry(1, pid: 50, layer: 25, 0, 0, 1512, 37),        // menu bar layer
        entry(2, pid: 999, 600, 300, 300, 300),             // our own overlay/island
        entry(3, alpha: 0, 500, 200, 400, 400),             // invisible
        entry(4, 520, 220, 10, 10),                         // tiny helper
        entry(5, 500, 200, 400, 400),                       // front ordinary window
        entry(6, 0, 0, 1512, 982),                          // behind it
    ])
    let pick = { (x: CGFloat, y: CGFloat) in
        WindowPicker.frontmost(at: CGPoint(x: x, y: y), in: windows, excludingPID: 999)?.id
    }
    #expect(pick(10, 10) == 6)       // menu bar layer skipped
    #expect(pick(650, 350) == 5)     // own window and invisible one skipped
    #expect(pick(525, 225) == 5)     // tiny helper skipped
    #expect(pick(100, 900) == 6)
    #expect(pick(2000, 100) == nil)  // no window there
    #expect(pick(.nan, 100) == nil)
}

@Test func windowsOnDisplaysWithNegativeCoordinatesCanBePicked() {
    let windows = WindowPicker.windows(from: [entry(8, -1800, -900, 1200, 800)])
    #expect(WindowPicker.frontmost(at: CGPoint(x: -1000, y: -500), in: windows, excludingPID: 1)?.id == 8)
}
