import XCTest
@testable import Beacon

final class OverlayLayoutTests: XCTestCase {
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
