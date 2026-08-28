import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Beacon

final class VisualUnderstandingTests: XCTestCase {
    func testVisionAnalyzerEmitsNonTextGeometryFromSyntheticCanvas() async throws {
        let snapshot = try syntheticCanvasSnapshot()

        let elements = try await VisionSceneAnalyzer().analyze(snapshot: snapshot)

        XCTAssertTrue(elements.contains { $0.kind != .text })
        XCTAssertTrue(elements.contains { $0.kind == .rectangle || $0.kind == .circle })
    }

    func testShapeClassifierDistinguishesCircleAndRectangle() throws {
        let circle = (0..<48).map { index in
            let angle = Double(index) / 48 * Double.pi * 2
            return CGPoint(x: 0.5 + cos(angle) * 0.15, y: 0.5 + sin(angle) * 0.15)
        }
        let rectangle = [
            CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.6, y: 0.2),
            CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.2, y: 0.4)
        ]

        XCTAssertEqual(
            VisualShapeClassifier.classify(points: circle, imageSize: .init(width: 500, height: 500))?.kind,
            .circle
        )
        XCTAssertEqual(
            VisualShapeClassifier.classify(
                points: rectangle,
                imageSize: .init(width: 500, height: 500),
                simplifiedPointCount: 4
            )?.kind,
            .rectangle
        )
    }

    func testSetOfMarksIncludesUncoveredVisualShapes() throws {
        let button = element(id: "e_save", label: "Save", x: 0.1)
        let circle = VisualElementDescriptor(
            id: "v_circle",
            text: "Circle",
            bounds: .init(x: 0.7, y: 0.4, width: 0.08, height: 0.08),
            confidence: 0.88,
            kind: .circle
        )
        var scene = makeScene(elements: [button])
        scene.visualElements = [circle]

        let marks = SetOfMarksBuilder().build(scene: scene)

        XCTAssertEqual(marks.count, 2)
        XCTAssertNotNil(marks.first(where: { $0.elementID == "e_save" }))
        let visualMark = try XCTUnwrap(marks.first(where: { $0.visualElementID == "v_circle" }))
        XCTAssertEqual(visualMark.source, .visualShape)
        XCTAssertEqual(visualMark.visualKind, .circle)
    }

    func testAutomaticMarkMatcherUsesShapeAndPosition() throws {
        var scene = makeScene(elements: [])
        scene.visualElements = [
            VisualElementDescriptor(
                id: "v_left", text: "Circle",
                bounds: .init(x: 0.1, y: 0.4, width: 0.08, height: 0.08),
                confidence: 0.8, kind: .circle
            ),
            VisualElementDescriptor(
                id: "v_right", text: "Circle",
                bounds: .init(x: 0.8, y: 0.4, width: 0.08, height: 0.08),
                confidence: 0.8, kind: .circle
            )
        ]
        let marks = SetOfMarksBuilder().build(scene: scene)

        let match = try XCTUnwrap(SetOfMarksMatcher.bestMatch(for: "Select the circle on the right", in: marks))

        XCTAssertEqual(match.mark.visualElementID, "v_right")
    }

    func testQuestionRelevantShapeSurvivesMarkBudget() {
        var scene = makeScene(elements: [])
        scene.visualElements = (0..<40).map { index in
            VisualElementDescriptor(
                id: "v_generic_\(index)",
                text: "Icon",
                bounds: .init(x: Double(index % 10) * 0.08, y: Double(index / 10) * 0.08, width: 0.03, height: 0.03),
                confidence: 0.95,
                kind: .icon
            )
        } + [
            VisualElementDescriptor(
                id: "v_requested_circle",
                text: "Circle",
                bounds: .init(x: 0.82, y: 0.6, width: 0.06, height: 0.06),
                confidence: 0.55,
                kind: .circle
            )
        ]

        let marks = SetOfMarksBuilder().build(
            scene: scene,
            maximumMarks: 10,
            query: "Select the circle on the right"
        )

        XCTAssertTrue(marks.contains { $0.visualElementID == "v_requested_circle" })
    }

    func testMarkGrounderResolvesVisualCandidate() async throws {
        var scene = makeScene(elements: [])
        let bounds = NormalizedRect(x: 0.6, y: 0.3, width: 0.1, height: 0.1)
        scene.visualElements = [
            VisualElementDescriptor(id: "v_shape", text: "Canvas shape", bounds: bounds, confidence: 0.7, kind: .canvasShape)
        ]
        let marks = SetOfMarksBuilder().build(scene: scene)
        let mark = try XCTUnwrap(marks.first)

        let result = try await SetOfMarksGrounder(marks: marks).resolve(
            intention: UIIntention(
                question: "Select the shape",
                preferredElementID: nil,
                preferredBounds: nil,
                preferredMark: mark.id
            ),
            scene: scene
        )

        XCTAssertEqual(result.target, .visualRegion(bounds: bounds))
        XCTAssertEqual(result.strategy, "Set of Marks")
    }

    private func element(id: String, label: String, x: Double) -> UIElementDescriptor {
        UIElementDescriptor(
            id: id, role: "AXButton", subrole: nil, label: label, title: nil,
            value: nil, enabled: true, focused: false,
            bounds: .init(x: x, y: 0.1, width: 0.12, height: 0.06)
        )
    }

    private func makeScene(elements: [UIElementDescriptor]) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Fixture", bundleIdentifier: "test", processIdentifier: 1),
            activeWindow: .init(title: "Fixture", bounds: .init(x: 0, y: 0, width: 1, height: 1)),
            screenshot: nil,
            elements: elements,
            displays: []
        )
    }

    private func syntheticCanvasSnapshot() throws -> ScreenSnapshot {
        let width = 600
        let height = 400
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(6)
        context.stroke(CGRect(x: 80, y: 90, width: 180, height: 100))
        context.strokeEllipse(in: CGRect(x: 380, y: 180, width: 90, height: 90))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return ScreenSnapshot(
            capturedAt: Date(),
            displayID: 1,
            pixelWidth: width,
            pixelHeight: height,
            displayBounds: .init(x: 0, y: 0, width: 1, height: 1),
            pngData: data as Data,
            redactionCount: 0
        )
    }
}
