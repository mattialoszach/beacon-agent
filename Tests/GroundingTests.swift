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

    func testVisualMatcherFindsOCRLabel() throws {
        let elements = [
            VisualElementDescriptor(
                id: "v_export", text: "Export", bounds: .init(x: 0.6, y: 0.2, width: 0.1, height: 0.04), confidence: 0.96
            ),
            VisualElementDescriptor(
                id: "v_cancel", text: "Cancel", bounds: .init(x: 0.4, y: 0.2, width: 0.1, height: 0.04), confidence: 0.99
            )
        ]
        let match = try XCTUnwrap(VisualElementMatcher.bestMatch(for: "Where is export?", in: elements))
        XCTAssertEqual(match.element.id, "v_export")
    }

    func testExactPDFMatchBeatsSaveSynonym() throws {
        let elements = [
            element(id: "e_save", label: "Save"),
            element(id: "e_pdf", label: "PDF")
        ]
        let match = try XCTUnwrap(SemanticElementMatcher.bestMatch(
            for: "Export this as PDF",
            in: elements
        ))
        XCTAssertEqual(match.element.id, "e_pdf")
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
