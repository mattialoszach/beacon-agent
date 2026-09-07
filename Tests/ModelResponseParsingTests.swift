import Foundation
import XCTest
@testable import Beacon

final class ModelResponseParsingTests: XCTestCase {
    func testDecodesSpecificOutcomeAndPreservesLegacyConfirmationFallback() throws {
        let json = #"{"message":"Choose PDF","action":null,"expectedOutcome":{"type":"visualChange","description":"Format is PDF","applicationScope":"sameApplication","element":{"id":null,"labels":["Format"],"role":"AXPopUpButton","value":"PDF"},"windowTitle":null,"destinationBundleIdentifier":null}}"#
        let response = try JSONDecoder().decode(InstructorResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.expectedOutcome?.element?.value, "PDF")
        XCTAssertEqual(response.expectedOutcome?.canVerifyAutomatically, true)
        let legacy = #"{"type":"visualChange","description":"The interface changes","applicationScope":"sameApplication"}"#
        let outcome = try JSONDecoder().decode(ExpectedOutcome.self, from: Data(legacy.utf8))
        XCTAssertFalse(outcome.canVerifyAutomatically)
    }

    func testDecodesTypedStructuredResponse() throws {
        let json = #"{"message":"Click Export","action":{"type":"pointToElement","targetElementId":"e_13","targetBounds":null,"overlay":"spotlight"},"expectedOutcome":{"type":"windowAppears","description":"Export dialog appears","applicationScope":"sameApplication"}}"#
        let response = try JSONDecoder().decode(InstructorResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.message, "Click Export")
        XCTAssertEqual(response.action?.targetElementId, "e_13")
        XCTAssertEqual(response.action?.overlay, .spotlight)
        XCTAssertEqual(response.expectedOutcome?.type, .windowAppears)
        XCTAssertEqual(response.expectedOutcome?.applicationScope, .sameApplication)
    }

    func testRejectsUnknownOverlayValue() {
        let json = #"{"message":"Click Export","action":{"type":"pointToElement","targetElementId":"e_13","targetBounds":null,"overlay":"modelDrawsAnything"},"expectedOutcome":null}"#
        XCTAssertThrowsError(try JSONDecoder().decode(InstructorResponse.self, from: Data(json.utf8)))
    }

    func testRejectsUnknownExpectedApplicationScope() {
        let json = #"{"message":"Open it","action":null,"expectedOutcome":{"type":"windowAppears","description":"A window appears","applicationScope":"alwaysChange"}}"#

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

    func testOpenAIDecodesMessageAfterReasoningItemWithoutContent() throws {
        let response = try OpenAIProvider(model: "test", apiKey: "unused").decodeResponse(
            envelope(status: "completed"), for: emptyRequest()
        )
        XCTAssertEqual(response.message, "Ready")
    }

    func testOpenAIRejectsIncompleteOutputEvenWhenItContainsValidJSON() throws {
        XCTAssertThrowsError(try OpenAIProvider(model: "test", apiKey: "unused").decodeResponse(
            envelope(status: "incomplete"), for: emptyRequest()
        ))
    }

    func testOpenAIUsesTheExactBoundedPrompt() throws {
        let request = emptyRequest()
        let body = OpenAIProvider(model: "test", apiKey: "unused").requestBody(for: request)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let user = try XCTUnwrap(input.last?["content"] as? [[String: Any]])
        XCTAssertEqual(user.first?["text"] as? String,
                       ModelContextBuilder(maximumElements: 100, maximumCharacters: 12_000)
                        .build(for: request).userPrompt)
    }

    private func envelope(status: String) throws -> Data {
        let payload = #"{"message":"Ready","action":null,"expectedOutcome":null,"taskComplete":false}"#
        return try JSONSerialization.data(withJSONObject: [
            "status": status,
            "output": [
                ["type": "reasoning", "summary": []],
                ["type": "message", "content": [["type": "output_text", "text": payload]]]
            ]
        ])
    }

    private func emptyRequest() -> InstructorRequest {
        InstructorRequest(question: "Explain", scene: ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Fixture", bundleIdentifier: "test.fixture", processIdentifier: 1),
            activeWindow: nil, screenshot: nil, elements: [], displays: []
        ), mode: .ask)
    }
}

/// Provider-level validation of cloud output: nothing invented may reach grounding, and
/// a readable refusal or truncation must be reported as such.
final class OpenAIResponseValidationTests: XCTestCase {
    private let provider = OpenAIProvider(model: "test", apiKey: "unused")

    func testHallucinatedElementIDIsRejected() {
        let payload = #"""
        {"message":"Click it","action":{"type":"pointToElement","targetElementId":"e_999",
        "targetBounds":null,"targetMark":null,"overlay":"spotlight"},
        "expectedOutcome":null,"taskComplete":false}
        """#
        XCTAssertThrowsError(try provider.decodeResponse(completed(payload), for: request())) { error in
            XCTAssertEqual(error as? GroundingError, .elementNotFound("e_999"))
        }
    }

    func testOutOfRangeBoundsAreRejected() {
        let payload = #"""
        {"message":"Look here","action":{"type":"pointToElement","targetElementId":null,
        "targetBounds":{"x":0.95,"y":0.1,"width":0.2,"height":0.1},"targetMark":null,
        "overlay":"rectangle"},"expectedOutcome":null,"taskComplete":false}
        """#
        XCTAssertThrowsError(try provider.decodeResponse(completed(payload), for: request())) { error in
            XCTAssertEqual(error as? GroundingError, .invalidBounds)
        }
    }

    func testMarkThatIsNotInTheTableIsRejected() {
        let payload = #"""
        {"message":"Use badge three","action":{"type":"pointToElement","targetElementId":null,
        "targetBounds":null,"targetMark":3,"overlay":"rectangle"},
        "expectedOutcome":null,"taskComplete":false}
        """#
        XCTAssertThrowsError(try provider.decodeResponse(completed(payload), for: request())) { error in
            XCTAssertEqual(error as? GroundingError, .markNotFound(3))
        }
    }

    func testWhitespaceOnlyMessageIsRejected() {
        let payload = #"{"message":"   ","action":null,"expectedOutcome":null,"taskComplete":false}"#
        XCTAssertThrowsError(try provider.decodeResponse(completed(payload), for: request())) { error in
            XCTAssertEqual(error as? CloudProviderError, .invalidResponse)
        }
    }

    func testKnownElementIDIsAccepted() throws {
        let payload = #"""
        {"message":"Choose Save","action":{"type":"pointToElement","targetElementId":"e_save",
        "targetBounds":null,"targetMark":null,"overlay":"spotlight"},
        "expectedOutcome":null,"taskComplete":false}
        """#
        let response = try provider.decodeResponse(completed(payload), for: request())
        XCTAssertEqual(response.action?.targetElementId, "e_save")
    }

    func testRefusalIsReportedAsARefusalNotAnUnreadableResponse() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [["type": "message", "content": [
                ["type": "refusal", "refusal": "I can't help with that."]
            ]]]
        ])
        XCTAssertThrowsError(try provider.decodeResponse(data, for: request())) { error in
            XCTAssertEqual(error as? CloudProviderError, .refused("I can't help with that."))
        }
    }

    func testTruncatedResponseReportsItsReason() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "incomplete",
            "incomplete_details": ["reason": "max_output_tokens"],
            "output": []
        ])
        XCTAssertThrowsError(try provider.decodeResponse(data, for: request())) { error in
            XCTAssertEqual(error as? CloudProviderError, .incomplete("max_output_tokens"))
            XCTAssertTrue(
                error.localizedDescription.contains("smaller part"),
                "The message must tell the user what to do: \(error.localizedDescription)"
            )
        }
    }

    private func completed(_ payload: String) -> Data {
        let escaped = payload
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"\#(escaped)"}]}]}"#.utf8)
    }

    private func request() -> InstructorRequest {
        InstructorRequest(question: "How do I save?", scene: ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Fixture", bundleIdentifier: "test.fixture", processIdentifier: 1),
            activeWindow: nil,
            screenshot: nil,
            elements: [
                UIElementDescriptor(
                    id: "e_save", role: "AXButton", subrole: nil, label: "Save", title: nil,
                    value: nil, enabled: true, focused: false,
                    bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.05), windowID: nil
                )
            ],
            displays: []
        ), mode: .guide)
    }
}
