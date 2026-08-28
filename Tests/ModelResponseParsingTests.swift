import Foundation
import XCTest
@testable import Beacon

final class ModelResponseParsingTests: XCTestCase {
    func testDecodesTypedStructuredResponse() throws {
        let json = #"{"message":"Click Export","action":{"type":"pointToElement","targetElementId":"e_13","targetBounds":null,"overlay":"spotlight"},"expectedOutcome":{"type":"windowAppears","description":"Export dialog appears"}}"#
        let response = try JSONDecoder().decode(InstructorResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.message, "Click Export")
        XCTAssertEqual(response.action?.targetElementId, "e_13")
        XCTAssertEqual(response.action?.overlay, .spotlight)
        XCTAssertEqual(response.expectedOutcome?.type, .windowAppears)
    }

    func testRejectsUnknownOverlayValue() {
        let json = #"{"message":"Click Export","action":{"type":"pointToElement","targetElementId":"e_13","targetBounds":null,"overlay":"modelDrawsAnything"},"expectedOutcome":null}"#
        XCTAssertThrowsError(try JSONDecoder().decode(InstructorResponse.self, from: Data(json.utf8)))
    }

    func testVisualGrounderRejectsOverflowingBox() async {
        let intention = UIIntention(
            question: "Find it",
            preferredElementID: nil,
            preferredBounds: .init(x: 0.95, y: 0.2, width: 0.2, height: 0.1)
        )
        let scene = ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Test", bundleIdentifier: nil, processIdentifier: 1),
            activeWindow: nil,
            screenshot: nil,
            elements: [],
            displays: []
        )

        do {
            _ = try await VisualGrounder().resolve(intention: intention, scene: scene)
            XCTFail("Expected invalid bounds")
        } catch {
            XCTAssertEqual(error as? GroundingError, .invalidBounds)
        }
    }

    func testVisualElementIDNormalizesToValidatedBounds() throws {
        let visual = VisualElementDescriptor(
            id: "v_export", text: "Export",
            bounds: .init(x: 0.7, y: 0.2, width: 0.1, height: 0.04),
            confidence: 0.95
        )
        var scene = ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Test", bundleIdentifier: nil, processIdentifier: 1),
            activeWindow: nil,
            screenshot: nil,
            elements: [],
            displays: []
        )
        scene.visualElements = [visual]
        let response = InstructorResponse(
            message: "Select Export",
            action: .init(type: .pointToElement, targetElementId: "v_export", targetBounds: nil, overlay: .rectangle),
            expectedOutcome: nil
        ).normalizingVisualTarget(in: scene)

        XCTAssertNil(response.action?.targetElementId)
        XCTAssertEqual(response.action?.targetBounds, visual.bounds)
        XCTAssertNoThrow(try response.action?.validated(in: scene))
    }

    func testValidatedMarkMustExistInCurrentMarkTable() throws {
        let scene = ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Test", bundleIdentifier: nil, processIdentifier: 1),
            activeWindow: nil,
            screenshot: nil,
            elements: [],
            displays: []
        )
        let mark = SetOfMark(
            id: 7,
            elementID: nil,
            visualElementID: "v_shape",
            bounds: .init(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
            label: "Circle",
            source: .visualShape,
            visualKind: .circle
        )
        let action = SuggestedAction(
            type: .pointToElement,
            targetElementId: nil,
            targetBounds: nil,
            targetMark: 7,
            overlay: .circle
        )

        XCTAssertNoThrow(try action.validated(in: scene, marks: [mark]))
        XCTAssertThrowsError(try action.validated(in: scene, marks: []))
    }

    func testOpenAIImageInputRequiresExplicitVisionOption() throws {
        var request = InstructorRequest(
            question: "Select the circle",
            scene: ScreenScene(
                timestamp: Date(),
                activeApplication: .init(name: "CAD", bundleIdentifier: "test.cad", processIdentifier: 1),
                activeWindow: nil,
                screenshot: nil,
                elements: [],
                displays: []
            ),
            mode: .guide
        )
        request.visualContextImage = ScreenSnapshot(
            capturedAt: Date(),
            displayID: 1,
            pixelWidth: 1,
            pixelHeight: 1,
            displayBounds: .init(x: 0, y: 0, width: 1, height: 1),
            pngData: Data([1, 2, 3]),
            redactionCount: 1
        )

        let textBody = OpenAIProvider(model: "test", apiKey: "key").requestBody(for: request)
        let visionBody = OpenAIProvider(
            model: "test",
            apiKey: "key",
            allowsVision: true
        ).requestBody(for: request)

        XCTAssertFalse(containsImage(in: textBody))
        XCTAssertTrue(containsImage(in: visionBody))
        XCTAssertEqual(visionBody["store"] as? Bool, false)
    }

    private func containsImage(in body: [String: Any]) -> Bool {
        guard let input = body["input"] as? [[String: Any]] else { return false }
        return input.contains { message in
            guard let content = message["content"] as? [[String: Any]] else { return false }
            return content.contains { $0["type"] as? String == "input_image" }
        }
    }
}
