import Foundation
import XCTest
@testable import Beacon

final class ModelContextBuilderTests: XCTestCase {
    func testLargeAccessibilityTreeIsBoundedAndRelevantControlIsKept() {
        var elements = (0..<800).map { index in
            element(id: "e_\(index)", label: "Generic control \(index)")
        }
        elements.append(element(id: "e_export", label: "Export as PDF"))
        let request = InstructorRequest(
            question: "How do I export as PDF?",
            scene: scene(elements: elements),
            mode: .guide
        )
        let context = ModelContextBuilder(maximumElements: 48, maximumCharacters: 6_000).build(for: request)

        XCTAssertLessThanOrEqual(context.includedElementCount, 48)
        XCTAssertLessThan(context.text.count, 6_500)
        XCTAssertTrue(context.includedElementIDs.contains("e_export"))
        XCTAssertGreaterThan(context.omittedElementCount, 700)
    }

    func testFocusedControlRanksAheadOfGenericControls() {
        let focused = UIElementDescriptor(
            id: "e_focus", role: "AXTextField", subrole: nil, label: "Search", title: nil,
            value: nil, enabled: true, focused: true,
            bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        )
        let context = ModelContextBuilder(maximumElements: 1, maximumCharacters: 500).build(for: InstructorRequest(
            question: "What is selected?",
            scene: scene(elements: [element(id: "e_other", label: "Other"), focused]),
            mode: .guide
        ))
        XCTAssertEqual(context.includedElementIDs, ["e_focus"])
    }

    func testSensitiveLabelsAreRedactedFromModelContext() {
        let context = ModelContextBuilder().build(for: InstructorRequest(
            question: "What is this field?",
            scene: scene(elements: [element(id: "e_email", label: "person@example.com")]),
            mode: .ask
        ))
        XCTAssertFalse(context.text.contains("person@example.com"))
        XCTAssertTrue(context.text.contains("[redacted sensitive text]"))
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
            activeApplication: .init(name: "Fixture", bundleIdentifier: "test.fixture", processIdentifier: 7),
            activeWindow: .init(title: "Document", bounds: .init(x: 0, y: 0, width: 1, height: 1)),
            screenshot: nil,
            elements: elements,
            displays: []
        )
    }
}
