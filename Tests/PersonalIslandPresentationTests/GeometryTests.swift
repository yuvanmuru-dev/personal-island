import CoreGraphics
import Testing
@testable import PersonalIslandPresentation

private func macBookDisplay() -> IslandGeometry.Display {
    IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
        safeAreaTop: 37,
        auxiliaryTopLeft: CGRect(x: 0, y: 945, width: 660, height: 37),
        auxiliaryTopRight: CGRect(x: 852, y: 945, width: 660, height: 37)
    )
}

private func dellDisplay() -> IslandGeometry.Display {
    IslandGeometry.Display(
        frame: CGRect(x: 1512, y: -80, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: -80, width: 1920, height: 1056),
        safeAreaTop: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil
    )
}

private func translated(_ display: IslandGeometry.Display, x: CGFloat, y: CGFloat) -> IslandGeometry.Display {
    IslandGeometry.Display(
        frame: display.frame.offsetBy(dx: x, dy: y),
        visibleFrame: display.visibleFrame.offsetBy(dx: x, dy: y),
        safeAreaTop: display.safeAreaTop,
        auxiliaryTopLeft: display.auxiliaryTopLeft?.offsetBy(dx: x, dy: y),
        auxiliaryTopRight: display.auxiliaryTopRight?.offsetBy(dx: x, dy: y)
    )
}

private func expectContained(_ inner: CGRect, in outer: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(inner.width > 0 && inner.height > 0, sourceLocation: sourceLocation)
    #expect(inner.minX >= outer.minX && inner.maxX <= outer.maxX, sourceLocation: sourceLocation)
    #expect(inner.minY >= outer.minY && inner.maxY <= outer.maxY, sourceLocation: sourceLocation)
}

@Test func macBookUsesTheActualCameraGapAndSafeArea() {
    let display = macBookDisplay()
    let layout = IslandGeometry.layout(for: display)
    #expect(layout.hasNotch)
    #expect(layout.reservedNotchWidth == 192)
    #expect(layout.topContentInset == 37)
    #expect(layout.compactSize.width >= layout.reservedNotchWidth)
    #expect(layout.compactSize.height >= display.safeAreaTop)
    for expanded in [false, true] {
        let panel = layout.panelFrame(expanded: expanded)
        #expect(panel.maxY == display.frame.maxY)
        #expect(panel.midX == display.frame.midX)
        expectContained(panel, in: display.frame)
    }
}

@Test func externalCapsuleClearsTheMenuBarWithoutReservingCameraSpace() {
    let display = dellDisplay()
    let layout = IslandGeometry.layout(for: display)
    #expect(!layout.hasNotch)
    #expect(layout.reservedNotchWidth == 0)
    #expect(layout.topContentInset == 0)
    for expanded in [false, true] {
        let panel = layout.panelFrame(expanded: expanded)
        #expect(panel.maxY <= display.visibleFrame.maxY - 8)
        #expect(panel.midX == display.frame.midX)
        expectContained(panel, in: display.frame)
    }
}

@Test func expansionKeepsTheTopAnchorAndCenterOnEachDisplay() {
    for display in [macBookDisplay(), dellDisplay()] {
        let layout = IslandGeometry.layout(for: display)
        let compact = layout.panelFrame(expanded: false)
        let expanded = layout.panelFrame(expanded: true)
        #expect(expanded.maxY == compact.maxY)
        #expect(expanded.midX == compact.midX)
        #expect(expanded.width >= compact.width)
        #expect(expanded.height >= compact.height)
    }
}

@Test func displaysLeftAboveAndBelowMainRetainTheirOwnCoordinateSpace() {
    for display in [macBookDisplay(), dellDisplay()] {
        let base = IslandGeometry.layout(for: display)
        for offset in [CGPoint(x: -3000, y: 0), CGPoint(x: 0, y: 1800), CGPoint(x: -1920, y: -1080)] {
            let moved = IslandGeometry.layout(for: translated(display, x: offset.x, y: offset.y))
            #expect(moved.compactSize == base.compactSize)
            #expect(moved.expandedSize == base.expandedSize)
            for expanded in [false, true] {
                #expect(moved.panelFrame(expanded: expanded) == base.panelFrame(expanded: expanded).offsetBy(dx: offset.x, dy: offset.y))
            }
        }
    }
}

@Test func sideDockDoesNotPullTheCapsuleAwayFromTheDisplayCenter() {
    let display = IslandGeometry.Display(
        frame: CGRect(x: -2560, y: 120, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -2480, y: 120, width: 2480, height: 1416),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
    let panel = IslandGeometry.layout(for: display).panelFrame(expanded: true)
    #expect(panel.midX == display.frame.midX)
    #expect(panel.maxY <= display.visibleFrame.maxY - 8)
    expectContained(panel, in: display.frame)
}

@Test func missingCameraAreaMetadataFallsBackToAContainedNotch() {
    let base = macBookDisplay()
    let display = IslandGeometry.Display(
        frame: base.frame, visibleFrame: base.visibleFrame,
        safeAreaTop: base.safeAreaTop, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
    let layout = IslandGeometry.layout(for: display)
    #expect(layout.hasNotch)
    #expect(layout.reservedNotchWidth > 0)
    #expect(layout.reservedNotchWidth < layout.compactSize.width)
    expectContained(layout.panelFrame(expanded: false), in: display.frame)
    expectContained(layout.panelFrame(expanded: true), in: display.frame)
}

@Test func nonpositiveSafeAreaDoesNotCreateAPhysicalNotch() {
    for safeArea in [CGFloat(0), CGFloat(-12)] {
        let base = dellDisplay()
        let display = IslandGeometry.Display(
            frame: base.frame, visibleFrame: base.visibleFrame,
            safeAreaTop: safeArea,
            auxiliaryTopLeft: CGRect(x: 0, y: 0, width: 10, height: 10),
            auxiliaryTopRight: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let layout = IslandGeometry.layout(for: display)
        #expect(!layout.hasNotch)
        #expect(layout.reservedNotchWidth == 0)
        #expect(layout.topContentInset == 0)
    }
}

@Test func narrowScreenShrinksThePanelRatherThanCrossingItsSides() {
    let display = IslandGeometry.Display(
        frame: CGRect(x: -140, y: -80, width: 140, height: 300),
        visibleFrame: CGRect(x: -140, y: -80, width: 140, height: 276),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
    let layout = IslandGeometry.layout(for: display)
    for expanded in [false, true] {
        let panel = layout.panelFrame(expanded: expanded)
        expectContained(panel, in: display.frame)
        #expect(panel.midX == display.frame.midX)
    }
}

@Test func tinyFloatingScreenPreservesMenuBarClearanceAndContainment() {
    let display = IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 80, height: 48),
        visibleFrame: CGRect(x: 0, y: 0, width: 80, height: 24),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
    let layout = IslandGeometry.layout(for: display)
    for expanded in [false, true] {
        let panel = layout.panelFrame(expanded: expanded)
        expectContained(panel, in: display.frame)
        #expect(panel.maxY <= display.visibleFrame.maxY - 8)
    }
}

@Test func tinyFramesNeverProduceNegativeSizesOrEscapeTheDisplay() {
    for width in [CGFloat(1), 8, 16, 24, 64, 300] {
        for height in [CGFloat(1), 8, 16, 48, 200] {
            let frame = CGRect(x: -400, y: -300, width: width, height: height)
            let display = IslandGeometry.Display(
                frame: frame, visibleFrame: frame,
                safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
            )
            let layout = IslandGeometry.layout(for: display)
            for expanded in [false, true] {
                let panel = layout.panelFrame(expanded: expanded)
                #expect(panel.origin.x.isFinite && panel.origin.y.isFinite)
                expectContained(panel, in: frame)
            }
        }
    }
}

@Test func malformedCameraWidthsCannotMakeThePanelWiderThanItsDisplay() {
    let display = IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 100, height: 180),
        visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 150),
        safeAreaTop: 30,
        auxiliaryTopLeft: CGRect(x: 0, y: 0, width: 900, height: 30),
        auxiliaryTopRight: CGRect(x: 0, y: 0, width: 900, height: 30)
    )
    let layout = IslandGeometry.layout(for: display)
    #expect(layout.reservedNotchWidth >= 0)
    for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: display.frame) }
}
