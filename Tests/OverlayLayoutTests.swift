import XCTest
@testable import Beacon

final class OverlayLayoutTests: XCTestCase {
    @MainActor
    func testNewInstructionStaysVisibleUntilThePointerMovesAndCanFadeAgainOnReturn() {
        let cursor = CursorPositionMonitor()
        cursor.recordMovement(to: CGPoint(x: 150, y: 850))
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var view = OverlayCanvasView(
            presentation: .init(target: .visualRegion(bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1)),
                                instruction: "Choose About This Mac", style: .spotlight, debugElements: []),
            screenFrame: frame,
            mapper: CoordinateSpaceMapper(virtualDesktopBounds: frame, appKitMainScreenMaxY: 1000),
            cursorPositionMonitor: cursor, cursorMovementBaseline: cursor.movementCount
        )
        XCTAssertFalse(view.shouldFadeForCursor(in: frame.size))
        cursor.recordMovement(to: CGPoint(x: 150, y: 850))
        XCTAssertFalse(view.shouldFadeForCursor(in: frame.size), "An unchanged position is not a move")
        cursor.recordMovement(to: CGPoint(x: 151, y: 850))
        XCTAssertTrue(view.shouldFadeForCursor(in: frame.size))
        cursor.recordMovement(to: CGPoint(x: 900, y: 50))
        XCTAssertFalse(view.shouldFadeForCursor(in: frame.size))
        cursor.recordMovement(to: CGPoint(x: 150, y: 850))
        XCTAssertTrue(view.shouldFadeForCursor(in: frame.size), "Returning to the starting point must still fade")

        view.cursorMovementBaseline = cursor.movementCount
        XCTAssertFalse(view.shouldFadeForCursor(in: frame.size), "The next instruction starts visible")
        cursor.recordMovement(to: CGPoint(x: 152, y: 850))
        XCTAssertTrue(view.shouldFadeForCursor(in: frame.size))
    }

    @MainActor
    func testGuidanceIsNotRenderedOnADisplayWithoutTheTarget() throws {
        let mapper = CoordinateSpaceMapper(
            virtualDesktopBounds: CGRect(x: -1000, y: 0, width: 2000, height: 1000),
            appKitMainScreenMaxY: 1000
        )
        let bounds = try XCTUnwrap(mapper.normalizeAXRect(CGRect(x: 100, y: 200, width: 50, height: 50)))
        let presentation = OverlayController.Presentation(
            target: .visualRegion(bounds: bounds), instruction: "Select it", style: .spotlight, debugElements: []
        )
        let cursor = CursorPositionMonitor()
        let primary = OverlayCanvasView(
            presentation: presentation, screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            mapper: mapper, cursorPositionMonitor: cursor
        )
        let secondary = OverlayCanvasView(
            presentation: presentation, screenFrame: CGRect(x: -1000, y: 0, width: 1000, height: 1000),
            mapper: mapper, cursorPositionMonitor: cursor
        )
        XCTAssertNotNil(primary.targetRect)
        XCTAssertNil(secondary.targetRect)
    }

    func testArrowTipStopsOutsideTargetEdge() throws {
        let target = CGRect(x: 350, y: 250, width: 100, height: 100)
        let geometry = try XCTUnwrap(GuidanceArrowGeometry.layout(
            target: target,
            availableSize: CGSize(width: 800, height: 600)
        ))

        XCTAssertFalse(target.contains(geometry.end))
        XCTAssertEqual(distance(from: geometry.end, to: target), 9, accuracy: 0.001)
        XCTAssertGreaterThan(
            distance(from: geometry.start, to: target),
            distance(from: geometry.end, to: target)
        )
    }

    func testArrowUsesSpaceBelowTargetNearTopEdge() throws {
        let target = CGRect(x: 260, y: 6, width: 120, height: 54)
        let geometry = try XCTUnwrap(GuidanceArrowGeometry.layout(
            target: target,
            availableSize: CGSize(width: 700, height: 500)
        ))

        XCTAssertEqual(geometry.side, .bottom)
        XCTAssertEqual(geometry.end.y, target.maxY + 9, accuracy: 0.001)
        XCTAssertGreaterThan(geometry.start.y, geometry.end.y)
    }

    func testArrowUsesSpaceLeftOfTargetNearRightEdge() throws {
        let target = CGRect(x: 650, y: 180, width: 42, height: 80)
        let geometry = try XCTUnwrap(GuidanceArrowGeometry.layout(
            target: target,
            availableSize: CGSize(width: 700, height: 500)
        ))

        XCTAssertEqual(geometry.side, .left)
        XCTAssertEqual(geometry.end.x, target.minX - 9, accuracy: 0.001)
        XCTAssertLessThan(geometry.start.x, geometry.end.x)
    }

    func testArrowIsOmittedWhenNoExteriorSpaceExists() {
        XCTAssertNil(GuidanceArrowGeometry.layout(
            target: CGRect(x: 0, y: 0, width: 300, height: 200),
            availableSize: CGSize(width: 300, height: 200)
        ))
    }

    func testArrowRejectsNonFiniteGeometry() {
        XCTAssertNil(GuidanceArrowGeometry.layout(
            target: CGRect(x: CGFloat.nan, y: 20, width: 40, height: 20),
            availableSize: CGSize(width: 300, height: 200)
        ))
    }

    func testArrowHoverBoundsCoverTheCompleteCurve() throws {
        let geometry = try XCTUnwrap(GuidanceArrowGeometry.layout(
            target: CGRect(x: 350, y: 250, width: 100, height: 100),
            availableSize: CGSize(width: 800, height: 600)
        ))

        XCTAssertTrue(geometry.hoverBounds.contains(geometry.start))
        XCTAssertTrue(geometry.hoverBounds.contains(geometry.control))
        XCTAssertTrue(geometry.hoverBounds.contains(geometry.end))
    }

    @MainActor
    func testEveryActionableTargetStyleIncludesTheArrowFadeRegion() throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let mapper = CoordinateSpaceMapper(
            virtualDesktopBounds: frame,
            appKitMainScreenMaxY: frame.maxY
        )
        let cursor = CursorPositionMonitor()

        for style in OverlayStyle.allCases {
            let view = OverlayCanvasView(
                presentation: .init(
                    target: .visualRegion(
                        bounds: .init(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
                    ),
                    instruction: "Choose the highlighted control.",
                    style: style,
                    debugElements: []
                ),
                screenFrame: frame,
                mapper: mapper,
                cursorPositionMonitor: cursor
            )
            let target = try XCTUnwrap(view.targetRect)
            let callout = InstructionCalloutGeometry.layout(
                text: "Choose the highlighted control.",
                target: target,
                availableSize: frame.size
            )
            let arrow = try XCTUnwrap(GuidanceArrowGeometry.layout(
                target: target,
                availableSize: frame.size,
                preferredSide: callout.preferredArrowSide(relativeTo: target),
                avoiding: callout.frame
            ))
            let regions = view.fadeRegions(in: frame.size)

            XCTAssertTrue(
                regions.contains { region in
                    region.contains(arrow.start)
                        && region.contains(arrow.control)
                        && region.contains(arrow.end)
                },
                "\(style.rawValue) guidance must include the arrow in proximity fading"
            )
        }
    }

    func testArrowUsesTheSideOppositeTheCalloutWhenSpaceAllows() throws {
        let target = CGRect(x: 350, y: 250, width: 100, height: 60)
        let available = CGSize(width: 800, height: 600)
        let callout = InstructionCalloutGeometry.layout(
            text: "Choose the highlighted control.",
            target: target,
            availableSize: available
        )
        let preferred = callout.preferredArrowSide(relativeTo: target)
        let arrow = try XCTUnwrap(GuidanceArrowGeometry.layout(
            target: target,
            availableSize: available,
            preferredSide: preferred
        ))

        XCTAssertEqual(arrow.side, preferred)
        XCTAssertEqual(preferred, .top)
        XCTAssertLessThan(arrow.start.y, arrow.end.y)
    }

    func testArrowRemainsSeparateFromTheInstructionCallout() throws {
        let target = CGRect(x: 350, y: 250, width: 100, height: 60)
        let available = CGSize(width: 800, height: 600)
        let callout = InstructionCalloutGeometry.layout(
            text: "Choose the highlighted control.",
            target: target,
            availableSize: available
        )
        let preferred = callout.preferredArrowSide(relativeTo: target)
        let arrow = try XCTUnwrap(GuidanceArrowGeometry.layout(
            target: target,
            availableSize: available,
            preferredSide: preferred,
            avoiding: callout.frame
        ))

        XCTAssertEqual(arrow.side, preferred)
        XCTAssertFalse(arrow.hoverBounds.intersects(callout.frame))
    }

    func testArrowIsOmittedWhenEveryAvailablePlacementIsObstructed() {
        let target = CGRect(x: 0, y: 70, width: 300, height: 60)
        let available = CGSize(width: 300, height: 200)

        XCTAssertNil(GuidanceArrowGeometry.layout(
            target: target,
            availableSize: available,
            preferredSide: .top,
            avoiding: CGRect(origin: .zero, size: available)
        ))
    }

    func testEveryTargetStyleDimsTheBackgroundConsistently() {
        let target = CGRect(x: 100, y: 100, width: 80, height: 40)

        for style in OverlayStyle.allCases {
            XCTAssertTrue(
                OverlayDimmingPolicy.dimsBackground(for: style, targetRect: target),
                "\(style.rawValue) must use the same dimmed background"
            )
        }
        XCTAssertFalse(OverlayDimmingPolicy.dimsBackground(for: .spotlight, targetRect: nil))
        XCTAssertEqual(OverlayDimmingPolicy.opacity, 0.52)
    }

    func testPurpleInstructionPaletteHasReadableContrast() {
        XCTAssertGreaterThanOrEqual(
            contrastRatio(
                foreground: BeaconPalette.Hex.blueViolet,
                background: BeaconPalette.Hex.lavender
            ),
            4.5
        )
    }

    func testCalloutGeometryStaysInsideTheAvailableArea() {
        let availableSize = CGSize(width: 800, height: 600)
        let geometry = InstructionCalloutGeometry.layout(
            text: "Open the Format menu, then choose Font.",
            target: CGRect(x: 350, y: 250, width: 100, height: 40),
            availableSize: availableSize
        )

        XCTAssertTrue(CGRect(origin: .zero, size: availableSize).contains(geometry.frame))
        XCTAssertTrue(geometry.frame.contains(geometry.position))
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let xDistance = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let yDistance = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(xDistance, yDistance)
    }

    private func contrastRatio(foreground: Int, background: Int) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private func relativeLuminance(_ hex: Int) -> Double {
        let channels = [16, 8, 0].map { shift -> Double in
            let component = Double((hex >> shift) & 0xFF) / 255
            return component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }
}

@MainActor
final class OverlayPanelConfigurationTests: XCTestCase {
    /// The `screen:` initializer variant treats contentRect as screen-relative, which put
    /// every panel on a secondary display at twice that display's origin.
    func testPanelCoversTheExactScreenFrameOnASecondaryDisplay() {
        let frame = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

        let panel = OverlayController.makeOverlayPanel(screenFrame: frame)

        XCTAssertEqual(panel.frame, frame)
    }

    func testPanelCoversTheExactScreenFrameOnANegativeOriginDisplay() {
        let frame = CGRect(x: -2560, y: -300, width: 2560, height: 1440)

        let panel = OverlayController.makeOverlayPanel(screenFrame: frame)

        XCTAssertEqual(panel.frame, frame)
    }

    /// Release-blocking invariant: overlays must not intercept normal mouse input and
    /// must never steal keyboard focus from the app the user is working in.
    func testOverlayPanelIsClickThroughAndNeverBecomesKey() {
        let panel = OverlayController.makeOverlayPanel(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
