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

/// AGENTS.md fixes the grounding priority: Accessibility element ID first, then a
/// validated visual rectangle, then marks. These pin that order.
final class HybridGrounderPriorityTests: XCTestCase {
    private let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)

    func testAccessibilityIDWinsOverModelSuppliedBounds() async throws {
        let result = try await HybridGrounder().resolve(
            intention: UIIntention(
                question: "Where is Save?",
                preferredElementID: "e_save",
                preferredBounds: .init(x: 0.8, y: 0.8, width: 0.05, height: 0.05)
            ),
            scene: scene()
        )

        guard case let .accessibilityElement(id, resolved) = result.target else {
            return XCTFail("Expected the accessible element, got \(result.target)")
        }
        XCTAssertEqual(id, "e_save")
        XCTAssertEqual(resolved, bounds, "Local bounds win over the model's rectangle")
    }

    func testValidatedBoundsAreUsedOnlyWhenNoElementMatches() async throws {
        let result = try await HybridGrounder().resolve(
            intention: UIIntention(
                question: "Point at the shape",
                preferredElementID: "e_missing",
                preferredBounds: .init(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
            ),
            scene: scene()
        )

        guard case let .visualRegion(resolved) = result.target else {
            return XCTFail("Expected a visual region, got \(result.target)")
        }
        XCTAssertEqual(resolved.x, 0.5, accuracy: 0.000_001)
    }

    func testMissingElementWithoutBoundsIsRejected() async {
        do {
            _ = try await HybridGrounder().resolve(
                intention: UIIntention(
                    question: "Point somewhere",
                    preferredElementID: "e_missing",
                    preferredBounds: nil
                ),
                scene: scene()
            )
            XCTFail("A stale element ID with no fallback must not ground")
        } catch {
            XCTAssertEqual(error as? GroundingError, .elementNotFound("e_missing"))
        }
    }

    func testMarkSelectionTakesPrecedenceOverAnAccessibilityID() async throws {
        let marked = scene()
        let marks = SetOfMarksBuilder().build(scene: marked)
        let mark = try XCTUnwrap(marks.first)

        let result = try await HybridGrounder().resolve(
            intention: UIIntention(
                question: "Use the numbered target",
                preferredElementID: "e_save",
                preferredBounds: nil,
                preferredMark: mark.id
            ),
            scene: marked
        )

        XCTAssertEqual(result.strategy, "Set of Marks")
    }

    func testRectangleOnNoDisplayIsRejectedEvenThoughItIsInsideTheDesktopUnion() {
        // Two displays side by side with a vertical offset leave a gap in the union.
        let gapScene = scene(displays: [
            DisplayDescriptor(id: 1, bounds: .init(x: 0, y: 0, width: 0.5, height: 1), scaleFactor: 2),
            DisplayDescriptor(id: 2, bounds: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5), scaleFactor: 1)
        ])
        let action = SuggestedAction(
            type: .pointToElement,
            targetElementId: nil,
            targetBounds: .init(x: 0.7, y: 0.05, width: 0.05, height: 0.05),
            overlay: .rectangle
        )

        XCTAssertThrowsError(try action.validated(in: gapScene)) { error in
            XCTAssertEqual(error as? GroundingError, .invalidBounds)
        }
    }

    func testRectangleOnARealDisplayStillValidates() throws {
        let gapScene = scene(displays: [
            DisplayDescriptor(id: 1, bounds: .init(x: 0, y: 0, width: 0.5, height: 1), scaleFactor: 2)
        ])
        let action = SuggestedAction(
            type: .pointToElement,
            targetElementId: nil,
            targetBounds: .init(x: 0.1, y: 0.1, width: 0.05, height: 0.05),
            overlay: .rectangle
        )

        XCTAssertNoThrow(try action.validated(in: gapScene))
    }

    func testRectangleThatOnlyTouchesADisplayIsRejected() {
        let gapScene = scene(displays: [
            DisplayDescriptor(id: 1, bounds: .init(x: 0, y: 0, width: 0.5, height: 1), scaleFactor: 2),
            DisplayDescriptor(id: 2, bounds: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5), scaleFactor: 1)
        ])
        let action = SuggestedAction(
            type: .pointToElement,
            targetElementId: nil,
            targetBounds: .init(x: 0.45, y: 0.1, width: 0.3, height: 0.2),
            overlay: .rectangle
        )

        XCTAssertThrowsError(try action.validated(in: gapScene)) { error in
            XCTAssertEqual(error as? GroundingError, .invalidBounds)
        }
    }

    private func scene(displays: [DisplayDescriptor] = []) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "App", bundleIdentifier: "com.example.app", processIdentifier: 7),
            activeWindow: WindowDescriptor(title: "Main", bounds: nil, id: "w1"),
            screenshot: nil,
            elements: [
                UIElementDescriptor(
                    id: "e_save", role: "AXButton", subrole: nil, label: "Save", title: nil,
                    value: nil, enabled: true, focused: false, bounds: bounds, windowID: "w1"
                )
            ],
            displays: displays
        )
    }
}

/// The focused-window filter must keep controls from anything presented over the focused
/// window, not only its immediate sheets.
final class RelatedWindowIdentityTests: XCTestCase {
    func testSheetsAndAlertsAboveThemAreAllRelated() {
        let windows = [
            window(id: "main", parent: nil),
            window(id: "sheet", parent: "main"),
            window(id: "alert", parent: "sheet"),
            window(id: "deeper", parent: "alert")
        ]

        let related = SceneIdentity.windowIDs(relatedTo: "main", in: windows)

        XCTAssertEqual(related, ["main", "sheet", "alert", "deeper"])
    }

    func testUnrelatedWindowsStayOut() {
        let windows = [
            window(id: "main", parent: nil),
            window(id: "sheet", parent: "main"),
            window(id: "other", parent: nil),
            window(id: "otherSheet", parent: "other")
        ]

        let related = SceneIdentity.windowIDs(relatedTo: "main", in: windows)

        XCTAssertEqual(related, ["main", "sheet"])
    }

    func testNoFocusedWindowRelatesToNothing() {
        XCTAssertTrue(
            SceneIdentity.windowIDs(relatedTo: nil, in: [window(id: "main", parent: nil)]).isEmpty
        )
    }

    func testACycleInParentLinksTerminates() {
        let windows = [
            window(id: "main", parent: nil),
            window(id: "a", parent: "b"),
            window(id: "b", parent: "a")
        ]

        XCTAssertEqual(SceneIdentity.windowIDs(relatedTo: "main", in: windows), ["main"])
    }

    private func window(id: String, parent: String?) -> WindowDescriptor {
        WindowDescriptor(title: id, bounds: nil, id: id, role: "AXWindow", parentWindowID: parent)
    }
}
