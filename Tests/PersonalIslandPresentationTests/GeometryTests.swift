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
        auxiliaryTopRight: display.auxiliaryTopRight?.offsetBy(dx: x, dy: y),
        menuBarHeight: display.menuBarHeight
    )
}

private func expectContained(_ inner: CGRect, in outer: CGRect, allowEmpty: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
    if allowEmpty {
        #expect(inner.width >= 0 && inner.height >= 0, sourceLocation: sourceLocation)
    } else {
        #expect(inner.width > 0 && inner.height > 0, sourceLocation: sourceLocation)
    }
    #expect(inner.origin.x.isFinite && inner.origin.y.isFinite && inner.width.isFinite && inner.height.isFinite, sourceLocation: sourceLocation)
    #expect(inner.minX >= outer.minX && inner.maxX <= outer.maxX, sourceLocation: sourceLocation)
    #expect(inner.minY >= outer.minY && inner.maxY <= outer.maxY, sourceLocation: sourceLocation)
}

private func expectProtectedMenuBand(
    _ layout: IslandGeometry.Layout,
    protectedHeight: CGFloat,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let frame = layout.displayFrame
    let band = CGRect(x: frame.minX, y: frame.maxY - protectedHeight, width: frame.width, height: protectedHeight)
    #expect(layout.protectedTopInset == protectedHeight, sourceLocation: sourceLocation)
    for expanded in [false, true] {
        let panel = layout.panelFrame(expanded: expanded)
        #expect(panel.maxY <= band.minY, sourceLocation: sourceLocation)
        #expect(panel.intersection(band).isEmpty, sourceLocation: sourceLocation)
    }
}

@Test func macBookKeepsCameraMetadataButMovesTheWholePanelBelowItsMenuBand() {
    let display = macBookDisplay()
    let layout = IslandGeometry.layout(for: display)
    #expect(layout.hasNotch)
    #expect(layout.cameraHousingWidth == 192)
    #expect(layout.topContentInset == 0)
    #expect(layout.compactSize.width == 192)
    #expect(layout.compactSize.height == 34)
    #expect(layout.expandedSize.height == 228)
    #expect(layout.hasUsableArea)
    expectProtectedMenuBand(layout, protectedHeight: 37)
    for expanded in [false, true] {
        let panel = layout.panelFrame(expanded: expanded)
        #expect(panel.maxY == display.frame.maxY - 37)
        #expect(panel.midX == display.frame.midX)
        expectContained(panel, in: display.frame)
    }
}

@Test func externalCapsuleClearsTheMenuBarWithoutReservingCameraSpace() {
    let display = dellDisplay()
    let layout = IslandGeometry.layout(for: display)
    #expect(!layout.hasNotch)
    #expect(layout.cameraHousingWidth == 0)
    #expect(layout.topContentInset == 0)
    #expect(layout.hasUsableArea)
    expectProtectedMenuBand(layout, protectedHeight: 24)
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
    var largerMenu = dellDisplay()
    largerMenu.menuBarHeight = 40
    for display in [macBookDisplay(), dellDisplay(), largerMenu] {
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
    #expect(layout.cameraHousingWidth == 180)
    #expect(layout.topContentInset == 0)
    #expect(layout.compactSize.width == 180)
    expectProtectedMenuBand(layout, protectedHeight: 37)
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
        #expect(layout.cameraHousingWidth == 0)
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
                expectContained(panel, in: frame, allowEmpty: !layout.hasUsableArea)
                #expect(layout.hasUsableArea == (height > 24))
                #expect(panel.maxY <= frame.maxY - min(height, 24))
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
    #expect(layout.cameraHousingWidth >= 0)
    #expect(layout.compactSize.width <= 240)
    for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: display.frame) }
}

@Test func autoHiddenExternalMenuStillReservesTheExplicitPointHeight() {
    let frame = CGRect(x: 1512, y: -80, width: 1920, height: 1080)
    let display = IslandGeometry.Display(
        frame: frame, visibleFrame: frame, safeAreaTop: 0,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 24
    )
    let layout = IslandGeometry.layout(for: display)
    expectProtectedMenuBand(layout, protectedHeight: 24)
    #expect(layout.topEdge == frame.maxY - 24 - 8)
    for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: frame) }
}

@Test func autoHiddenMacBookMenuStillReservesTheCameraSafeArea() {
    let base = macBookDisplay()
    let display = IslandGeometry.Display(
        frame: base.frame, visibleFrame: base.frame, safeAreaTop: 37,
        auxiliaryTopLeft: base.auxiliaryTopLeft, auxiliaryTopRight: base.auxiliaryTopRight
    )
    let layout = IslandGeometry.layout(for: display)
    expectProtectedMenuBand(layout, protectedHeight: 37)
    #expect(layout.topEdge == base.frame.maxY - 37)
}

@Test func theLargestSafeVisibleOrExplicitMenuInsetProtectsBothStates() {
    let frame = CGRect(x: -1512, y: 982, width: 1512, height: 982)
    for (safeTop, visibleTop, explicitTop, expected) in [
        (CGFloat(37), CGFloat(24), CGFloat(24), CGFloat(37)),
        (20, 48, 24, 48),
        (0, 24, 40, 40),
        (0, 48, 24, 48),
    ] {
        let visible = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - visibleTop)
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: frame, visibleFrame: visible, safeAreaTop: safeTop,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: explicitTop
        ))
        expectProtectedMenuBand(layout, protectedHeight: expected)
        #expect(layout.topContentInset == 0)
        for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: frame) }
    }
}

@Test func bottomDockDoesNotGetMistakenForExtraMenuHeight() {
    let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let display = IslandGeometry.Display(
        frame: frame,
        visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 966),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
    let layout = IslandGeometry.layout(for: display)
    expectProtectedMenuBand(layout, protectedHeight: 24)
    #expect(layout.topEdge == 1048)
}

@Test func logicalDisplayResolutionsKeepTheMenuBandInLayoutPoints() {
    for size in [CGSize(width: 1920, height: 1080), CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160)] {
        let frame = CGRect(origin: CGPoint(x: -400, y: 120), size: size)
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: frame, visibleFrame: frame, safeAreaTop: 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 32
        ))
        expectProtectedMenuBand(layout, protectedHeight: 32)
        #expect(frame.maxY - layout.topEdge == 40)
        #expect(layout.compactSize == CGSize(width: 164, height: 34))
        #expect(layout.expandedSize == CGSize(width: 420, height: 228))
    }
}

@Test func invalidExplicitMenuHeightsUseAConservativeTwentyFourPointFallback() {
    let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    for height in [CGFloat(0), -12, .nan, .infinity, -.infinity] {
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: frame, visibleFrame: frame, safeAreaTop: 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: height
        ))
        expectProtectedMenuBand(layout, protectedHeight: 24)
        #expect(layout.hasUsableArea)
        for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: frame) }
    }
}

@Test func nonfiniteSafeAreasAndVisibleMetadataDoNotPoisonPanelFrames() {
    let frame = CGRect(x: -1920, y: -80, width: 1920, height: 1080)
    let invalidVisibleFrames: [CGRect] = [
        .zero, .null,
        CGRect(x: CGFloat.nan, y: 0, width: 1920, height: 1080),
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1080),
    ]
    for safeTop in [CGFloat.nan, .infinity, -.infinity] {
        for visible in invalidVisibleFrames {
            let layout = IslandGeometry.layout(for: IslandGeometry.Display(
                frame: frame, visibleFrame: visible, safeAreaTop: safeTop,
                auxiliaryTopLeft: nil, auxiliaryTopRight: nil
            ))
            #expect(!layout.hasNotch)
            expectProtectedMenuBand(layout, protectedHeight: 24)
            for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: frame) }
        }
    }
}

@Test func missingOrMalformedCameraMetadataUsesOnlyABoundedMetadataFallback() {
    let base = macBookDisplay()
    let invalidAreas: [CGRect?] = [
        nil, .zero,
        CGRect(x: CGFloat.nan, y: 945, width: 660, height: 37),
        CGRect(x: 0, y: 945, width: CGFloat.infinity, height: 37),
        CGRect(x: 0, y: 945, width: 9000, height: 37),
        CGRect(x: 0, y: 945, width: -100, height: 37),
    ]
    for area in invalidAreas {
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: base.frame, visibleFrame: base.visibleFrame, safeAreaTop: 37,
            auxiliaryTopLeft: area, auxiliaryTopRight: base.auxiliaryTopRight
        ))
        #expect(layout.cameraHousingWidth == 180)
        #expect(layout.compactSize.width == 180)
        #expect(layout.compactSize.height == 34)
        #expect(layout.topContentInset == 0)
        expectProtectedMenuBand(layout, protectedHeight: 37)
    }
}

@Test func aBandThatConsumesTheDisplayProducesNoInteractiveArea() {
    let frame = CGRect(x: -80, y: 120, width: 80, height: 24)
    for (safeTop, menuTop) in [(CGFloat(0), CGFloat(24)), (.greatestFiniteMagnitude, 24), (0, .greatestFiniteMagnitude)] {
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: frame, visibleFrame: frame, safeAreaTop: safeTop,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: menuTop
        ))
        #expect(!layout.hasUsableArea)
        expectProtectedMenuBand(layout, protectedHeight: 24)
        #expect(layout.compactSize.height == 0)
        #expect(layout.expandedSize.height == 0)
        for expanded in [false, true] {
            expectContained(layout.panelFrame(expanded: expanded), in: frame, allowEmpty: true)
        }
    }
}

@Test func invalidDisplayFramesYieldFiniteEmptyGeometryRatherThanAnOverlappingWindow() {
    let invalidFrames: [CGRect] = [
        .zero, .null,
        CGRect(x: 0, y: 0, width: -100, height: 200),
        CGRect(x: CGFloat.nan, y: 0, width: 100, height: 200),
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 200),
        CGRect(x: 0, y: CGFloat.greatestFiniteMagnitude, width: 100, height: CGFloat.greatestFiniteMagnitude),
    ]
    for frame in invalidFrames {
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: frame, visibleFrame: frame, safeAreaTop: 37,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        ))
        #expect(!layout.hasUsableArea)
        for expanded in [false, true] {
            expectContained(layout.panelFrame(expanded: expanded), in: layout.displayFrame, allowEmpty: true)
        }
    }
}
