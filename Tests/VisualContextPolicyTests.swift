import XCTest
@testable import Beacon

final class VisualContextPolicyTests: XCTestCase {
    func testAccessibleMatchSkipsExpensiveVisualFallback() {
        let scene = makeScene(elements: [
            UIElementDescriptor(
                id: "export",
                role: "AXButton",
                subrole: nil,
                label: "Export",
                title: nil,
                value: nil,
                enabled: true,
                focused: false,
                bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.05)
            )
        ])

        XCTAssertFalse(LocalVisualContextPolicy.requiresVisualFallback(
            scene: scene,
            question: "How do I export this document?"
        ))
    }

    func testMissingAccessibleMatchUsesVisualFallback() {
        XCTAssertTrue(LocalVisualContextPolicy.requiresVisualFallback(
            scene: makeScene(elements: []),
            question: "Where is the unlabeled control?"
        ))
    }

    func testExplicitShapeRequestUsesVisualFallbackDespiteTextMatch() {
        let scene = makeScene(elements: [
            UIElementDescriptor(
                id: "shape",
                role: "AXButton",
                subrole: nil,
                label: "Shape",
                title: nil,
                value: nil,
                enabled: true,
                focused: false,
                bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.05)
            )
        ])

        XCTAssertTrue(LocalVisualContextPolicy.requiresVisualFallback(
            scene: scene,
            question: "Find the circle shape on screen"
        ))
    }

    private func makeScene(elements: [UIElementDescriptor]) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: ApplicationDescriptor(
                name: "Fixture",
                bundleIdentifier: "test.fixture",
                processIdentifier: 1
            ),
            activeWindow: nil,
            screenshot: nil,
            elements: elements,
            displays: []
        )
    }
}
