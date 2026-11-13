import CoreGraphics
import Testing
@testable import PersonalIslandPresentation

private func macBookDisplay() -> IslandGeometry.Display {
    IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTop: 37,
        auxiliaryTopLeft: CGRect(x: 0, y: 945, width: 660, height: 37),
        auxiliaryTopRight: CGRect(x: 852, y: 945, width: 660, height: 37)
    )
}

private func dellDisplay() -> IslandGeometry.Display {
    IslandGeometry.Display(
        frame: CGRect(x: 1512, y: -80, width: 1920, height: 1080),
        safeAreaTop: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil
    )
}

private func translated(_ display: IslandGeometry.Display, x: CGFloat, y: CGFloat) -> IslandGeometry.Display {
    IslandGeometry.Display(
        frame: display.frame.offsetBy(dx: x, dy: y),
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

/// The camera housing as reported by the public auxiliary-area metadata.
private func cameraHousing(of display: IslandGeometry.Display) -> CGRect {
    let left = display.auxiliaryTopLeft!, right = display.auxiliaryTopRight!
    return CGRect(
        x: left.maxX, y: display.frame.maxY - display.safeAreaTop,
        width: right.minX - left.maxX, height: display.safeAreaTop
    )
}

/// Menu/status regions: the full menu row minus the camera housing.
private func menuItemRegions(of display: IslandGeometry.Display) -> [CGRect] {
    let housing = cameraHousing(of: display)
    let top = display.frame.maxY - display.safeAreaTop
    return [
        CGRect(x: display.frame.minX, y: top, width: housing.minX - display.frame.minX, height: display.safeAreaTop),
        CGRect(x: housing.maxX, y: top, width: display.frame.maxX - housing.maxX, height: display.safeAreaTop),
    ]
}

@Test func macBookCompactWindowIsExactlyTheCameraHousing() {
    let display = macBookDisplay()
    let layout = IslandGeometry.layout(for: display)
    #expect(layout.hasNotch)
    #expect(layout.hasUsableArea)
    #expect(layout.panelFrame(expanded: false) == cameraHousing(of: display))
    #expect(layout.panelFrame(expanded: false) == CGRect(x: 660, y: 945, width: 192, height: 37))
}

@Test func macBookCompactWindowNeverCoversMenusOrStatusItems() {
    let display = macBookDisplay()
    let compact = IslandGeometry.layout(for: display).panelFrame(expanded: false)
    for region in menuItemRegions(of: display) {
        #expect(compact.intersection(region).isEmpty)
    }
    // Nor anything below the menu row, i.e. application content.
    #expect(compact.minY >= display.frame.maxY - display.safeAreaTop)
}

@Test func macBookExpandedShelfGrowsDownFromTheTopAndStartsContentBelowTheCamera() {
    let display = macBookDisplay()
    let layout = IslandGeometry.layout(for: display)
    let expanded = layout.panelFrame(expanded: true)
    #expect(expanded.maxY == display.frame.maxY)
    #expect(expanded.midX == display.frame.midX)
    #expect(expanded.contains(cameraHousing(of: display)))
    #expect(layout.topContentInset == 37)
    #expect(layout.expandedSize == CGSize(width: IslandGeometry.expandedWidth, height: 228 + 37))
    expectContained(expanded, in: display.frame)
}

@Test func externalDisplayPillSitsInsideTheMenuBarCenter() {
    let display = dellDisplay()
    let layout = IslandGeometry.layout(for: display)
    #expect(!layout.hasNotch)
    #expect(layout.hasUsableArea)
    #expect(layout.topContentInset == 0)
    let pill = layout.panelFrame(expanded: false)
    let menuRow = CGRect(x: display.frame.minX, y: display.frame.maxY - 24, width: display.frame.width, height: 24)
    #expect(menuRow.contains(pill))
    #expect(pill.maxY < display.frame.maxY)
    #expect(pill.minY > menuRow.minY)
    #expect(pill.midX == display.frame.midX)
    #expect(pill.width == IslandGeometry.pillWidth)
    #expect(pill.height == 18)
}

@Test func externalPillFollowsATallerMenuBarButStaysAPill() {
    var display = dellDisplay()
    display.menuBarHeight = 40
    let pill = IslandGeometry.layout(for: display).panelFrame(expanded: false)
    #expect(pill.height == IslandGeometry.pillMaximumHeight)
    #expect(pill.minY >= display.frame.maxY - 40)
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
        #expect(expanded.contains(compact))
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

@Test func missingCameraAreaMetadataFallsBackToABoundedNotchAtTheTop() {
    let base = macBookDisplay()
    let display = IslandGeometry.Display(
        frame: base.frame, safeAreaTop: base.safeAreaTop,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
    let layout = IslandGeometry.layout(for: display)
    #expect(layout.hasNotch)
    #expect(layout.compactSize == CGSize(width: IslandGeometry.fallbackNotchWidth, height: 37))
    let compact = layout.panelFrame(expanded: false)
    #expect(compact.maxY == display.frame.maxY)
    #expect(compact.midX == display.frame.midX)
    expectContained(compact, in: display.frame)
    expectContained(layout.panelFrame(expanded: true), in: display.frame)
}

@Test func missingOrMalformedCameraMetadataUsesOnlyABoundedFallback() {
    let base = macBookDisplay()
    let invalidAreas: [CGRect?] = [
        nil, .zero,
        CGRect(x: CGFloat.nan, y: 945, width: 660, height: 37),
        CGRect(x: 0, y: 945, width: CGFloat.infinity, height: 37),
        CGRect(x: 0, y: 945, width: 9000, height: 37),
        CGRect(x: 0, y: 945, width: -100, height: 37),
        // Implausibly small auxiliary areas would imply a huge housing.
        CGRect(x: 0, y: 945, width: 10, height: 37),
    ]
    for area in invalidAreas {
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: base.frame, safeAreaTop: 37,
            auxiliaryTopLeft: area, auxiliaryTopRight: area == nil ? base.auxiliaryTopRight : CGRect(x: 0, y: 945, width: 10, height: 37)
        ))
        #expect(layout.compactSize == CGSize(width: IslandGeometry.fallbackNotchWidth, height: 37))
        #expect(layout.panelFrame(expanded: false).maxY == base.frame.maxY)
    }
}

@Test func implausiblyTallSafeAreasAreBoundedToANotchSizedWindow() {
    let base = macBookDisplay()
    for safeTop in [CGFloat(200), 900, .greatestFiniteMagnitude] {
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: base.frame, safeAreaTop: safeTop,
            auxiliaryTopLeft: base.auxiliaryTopLeft, auxiliaryTopRight: base.auxiliaryTopRight
        ))
        #expect(layout.compactSize.height == IslandGeometry.maximumNotchHeight)
        for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: base.frame) }
    }
}

@Test func nonpositiveOrNonfiniteSafeAreaDoesNotCreateAPhysicalNotch() {
    for safeArea in [CGFloat(0), -12, .nan, .infinity, -.infinity] {
        let base = dellDisplay()
        let display = IslandGeometry.Display(
            frame: base.frame, safeAreaTop: safeArea,
            auxiliaryTopLeft: CGRect(x: 0, y: 0, width: 10, height: 10),
            auxiliaryTopRight: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let layout = IslandGeometry.layout(for: display)
        #expect(!layout.hasNotch)
        #expect(layout.topContentInset == 0)
        #expect(layout.compactSize.width == IslandGeometry.pillWidth)
        for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: display.frame) }
    }
}

@Test func narrowScreenShrinksThePanelRatherThanCrossingItsSides() {
    for safeTop in [CGFloat(0), 30] {
        let display = IslandGeometry.Display(
            frame: CGRect(x: -140, y: -80, width: 140, height: 300),
            safeAreaTop: safeTop, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )
        let layout = IslandGeometry.layout(for: display)
        for expanded in [false, true] {
            let panel = layout.panelFrame(expanded: expanded)
            expectContained(panel, in: display.frame)
            #expect(panel.midX == display.frame.midX)
        }
    }
}

@Test func malformedCameraWidthsCannotMakeThePanelWiderThanItsDisplay() {
    let display = IslandGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 100, height: 180),
        safeAreaTop: 30,
        auxiliaryTopLeft: CGRect(x: 0, y: 0, width: 900, height: 30),
        auxiliaryTopRight: CGRect(x: 0, y: 0, width: 900, height: 30)
    )
    let layout = IslandGeometry.layout(for: display)
    for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: display.frame) }
}

@Test func tinyFramesNeverProduceNegativeSizesOrEscapeTheDisplay() {
    for width in [CGFloat(1), 8, 16, 24, 64, 300] {
        for height in [CGFloat(1), 8, 16, 48, 200] {
            for safeTop in [CGFloat(0), 37] {
                let frame = CGRect(x: -400, y: -300, width: width, height: height)
                let layout = IslandGeometry.layout(for: IslandGeometry.Display(
                    frame: frame, safeAreaTop: safeTop, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
                ))
                for expanded in [false, true] {
                    expectContained(layout.panelFrame(expanded: expanded), in: frame, allowEmpty: !layout.hasUsableArea)
                }
            }
        }
    }
}

@Test func invalidExplicitMenuHeightsUseATwentyFourPointFallback() {
    let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    for height in [CGFloat(0), -12, .nan, .infinity, -.infinity] {
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: frame, safeAreaTop: 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: height
        ))
        #expect(layout.hasUsableArea)
        let pill = layout.panelFrame(expanded: false)
        #expect(pill.height == 18)
        #expect(pill.minY >= frame.maxY - 24)
        for expanded in [false, true] { expectContained(layout.panelFrame(expanded: expanded), in: frame) }
    }
}

@Test func logicalDisplayResolutionsKeepThePillInLayoutPoints() {
    for size in [CGSize(width: 1920, height: 1080), CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160)] {
        let frame = CGRect(origin: CGPoint(x: -400, y: 120), size: size)
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: frame, safeAreaTop: 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 24
        ))
        #expect(layout.compactSize == CGSize(width: 84, height: 18))
        #expect(layout.expandedSize == CGSize(width: IslandGeometry.expandedWidth, height: 228))
        #expect(frame.maxY - layout.topEdge == 3)
    }
}

@Test func invalidDisplayFramesYieldFiniteEmptyGeometry() {
    let invalidFrames: [CGRect] = [
        .zero, .null,
        CGRect(x: 0, y: 0, width: -100, height: 200),
        CGRect(x: CGFloat.nan, y: 0, width: 100, height: 200),
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 200),
        CGRect(x: 0, y: CGFloat.greatestFiniteMagnitude, width: 100, height: CGFloat.greatestFiniteMagnitude),
    ]
    for frame in invalidFrames {
        let layout = IslandGeometry.layout(for: IslandGeometry.Display(
            frame: frame, safeAreaTop: 37,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        ))
        #expect(!layout.hasUsableArea)
        for expanded in [false, true] {
            expectContained(layout.panelFrame(expanded: expanded), in: layout.displayFrame, allowEmpty: true)
        }
    }
}

// MARK: - Animated resizing

@Test func openingGrowsTheWindowAtOnceAndNeedsNoLaterStep() {
    let layout = IslandGeometry.layout(for: macBookDisplay())
    let compact = layout.panelFrame(expanded: false), open = layout.panelFrame(expanded: true)
    let frames = IslandGeometry.animatedFrames(from: compact, to: open, animated: true)
    #expect(frames.now == open && frames.later == nil)
    #expect(layout.size(expanded: true) == open.size && layout.size(expanded: false, activity: true) == layout.activitySize)
}

@Test func closingKeepsTheWindowUntilTheIslandHasShrunkThenSettlesExactly() {
    let layout = IslandGeometry.layout(for: macBookDisplay())
    let compact = layout.panelFrame(expanded: false), open = layout.panelFrame(expanded: true)
    let frames = IslandGeometry.animatedFrames(from: open, to: compact, animated: true)
    #expect(frames.now == open && frames.later == compact)
    // Settling applies the exact frame; asking again from there is already done.
    let settled = IslandGeometry.animatedFrames(from: compact, to: compact, animated: true)
    #expect(settled.now == compact && settled.later == nil)
}

@Test func widenedNoticeAndOpenIslandHoldTheirUnionWhileSwitching() {
    let layout = IslandGeometry.layout(for: macBookDisplay())
    let wide = layout.panelFrame(expanded: false, activity: true), open = layout.panelFrame(expanded: true)
    let frames = IslandGeometry.animatedFrames(from: open, to: wide, animated: true)
    #expect(frames.now.contains(open) && frames.now.contains(wide) && frames.later == wide)
}

@Test func reducedMotionAndMovesToAnotherDisplayGoStraightToTheTarget() {
    let mac = IslandGeometry.layout(for: macBookDisplay()), dell = IslandGeometry.layout(for: dellDisplay())
    let open = mac.panelFrame(expanded: true), compact = mac.panelFrame(expanded: false)
    #expect(IslandGeometry.animatedFrames(from: open, to: compact, animated: false) == (compact, nil))
    let moved = IslandGeometry.animatedFrames(from: open, to: dell.panelFrame(expanded: false), animated: true)
    #expect(moved.now == dell.panelFrame(expanded: false) && moved.later == nil)
}
