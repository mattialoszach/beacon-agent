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

    func testWeakGenericAccessibleMatchDoesNotSuppressVisualFallback() {
        let scene = makeScene(elements: [
            UIElementDescriptor(
                id: "settings",
                role: "AXButton",
                subrole: nil,
                label: "Settings",
                title: nil,
                value: nil,
                enabled: true,
                focused: false,
                bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.05)
            )
        ])

        XCTAssertTrue(LocalVisualContextPolicy.requiresVisualFallback(
            scene: scene,
            question: "Change the account profile picture in settings"
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

    func testBrowserProfileGuideKeepsLocalVisualContextDespiteAccessibleAvatar() {
        let scene = makeScene(
            bundleIdentifier: "com.google.Chrome",
            elements: [
                UIElementDescriptor(
                    id: "profile",
                    role: "AXButton",
                    subrole: nil,
                    label: "Profile picture",
                    title: nil,
                    value: nil,
                    enabled: true,
                    focused: false,
                    bounds: NormalizedRect(x: 0.85, y: 0.05, width: 0.05, height: 0.05)
                )
            ]
        )

        XCTAssertTrue(LocalVisualContextPolicy.requiresVisualFallback(
            scene: scene,
            question: "Where can I change my profile picture?"
        ))
    }

    func testVSCodeThemeGuideKeepsLocalVisualContextForStaticElectronMenus() {
        let scene = makeScene(
            bundleIdentifier: "com.microsoft.VSCode",
            elements: [
                UIElementDescriptor(
                    id: "code-menu",
                    role: "AXMenuBarItem",
                    subrole: nil,
                    label: "Code",
                    title: nil,
                    value: nil,
                    enabled: true,
                    focused: false,
                    bounds: NormalizedRect(x: 0.01, y: 0, width: 0.04, height: 0.03)
                )
            ]
        )

        XCTAssertTrue(LocalVisualContextPolicy.requiresVisualFallback(
            scene: scene,
            question: "How can I change my VSCode theme?"
        ))
    }

    private func makeScene(
        bundleIdentifier: String = "test.fixture",
        elements: [UIElementDescriptor]
    ) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: ApplicationDescriptor(
                name: "Fixture",
                bundleIdentifier: bundleIdentifier,
                processIdentifier: 1
            ),
            activeWindow: nil,
            screenshot: nil,
            elements: elements,
            displays: []
        )
    }
}
