import XCTest
@testable import Beacon

final class GroundingTests: XCTestCase {
    func testSemanticMatcherUsesExportSynonyms() throws {
        let elements = [
            element(id: "e_cancel", label: "Cancel"),
            element(id: "e_share", label: "Share…"),
            element(id: "e_help", label: "Help")
        ]
        let match = try XCTUnwrap(SemanticElementMatcher.bestMatch(
            for: "How do I export this?",
            in: elements
        ))
        XCTAssertEqual(match.element.id, "e_share")
    }

    func testActionValidationRejectsUnknownElement() {
        let action = SuggestedAction(
            type: .pointToElement,
            targetElementId: "invented",
            targetBounds: nil,
            overlay: .arrow
        )
        XCTAssertThrowsError(try action.validated(in: scene(elements: [])))
    }

    func testActionValidationRejectsOutOfBoundsVisualTarget() {
        let action = SuggestedAction(
            type: .pointToElement,
            targetElementId: nil,
            targetBounds: .init(x: 0.9, y: 0.9, width: 0.2, height: 0.2),
            overlay: .rectangle
        )
        XCTAssertThrowsError(try action.validated(in: scene(elements: [])))
    }

    private func element(id: String, label: String) -> UIElementDescriptor {
        UIElementDescriptor(
            id: id, role: "AXButton", subrole: nil, label: label, title: nil,
            value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
        )
    }

    private func scene(elements: [UIElementDescriptor]) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Test", bundleIdentifier: "test", processIdentifier: 1),
            activeWindow: nil,
            screenshot: nil,
            elements: elements,
            displays: []
        )
    }
}
