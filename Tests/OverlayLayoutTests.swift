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
