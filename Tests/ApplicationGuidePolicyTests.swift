import XCTest
@testable import Beacon

final class ApplicationGuidePolicyTests: XCTestCase {
    private let planner = ApplicationGuidePlanner()

    func testTextEditExportRecipeStartsWithFileMenu() throws {
        let request = makeRequest(
            elements: [element(id: "e_file", label: "File", role: "AXMenuBarItem")]
        )

        let response = try XCTUnwrap(planner.response(for: request))

        XCTAssertEqual(response.message, "Open the File menu.")
        XCTAssertEqual(response.action?.targetElementId, "e_file")
        XCTAssertEqual(response.expectedOutcome?.type, .elementAppears)
    }

    func testTextEditExportRecipeAdvancesUsingCompletedContext() throws {
        var request = makeRequest(
            elements: [element(id: "e_export", label: "Export as PDF…", role: "AXMenuItem")]
        )
        request.guideContext = GuideContext(
            stepNumber: 2,
            maximumSteps: 8,
            completedSteps: [
                CompletedGuideStep(
                    number: 1,
                    instruction: "Open the File menu.",
                    targetElementID: "e_file",
                    targetLabel: "File"
                )
            ]
        )

        let response = try XCTUnwrap(planner.response(for: request))

        XCTAssertEqual(response.message, "Choose the PDF export command.")
        XCTAssertEqual(response.action?.targetElementId, "e_export")
        XCTAssertEqual(response.expectedOutcome?.type, .windowAppears)
    }

    func testApplicationRecoveryStopsAfterConfiguredRetries() {
        let registry = ApplicationGuidePolicyRegistry()

        let retry = registry.recoveryDecision(
            for: "com.apple.TextEdit",
            attempt: 2,
            noChange: false,
            expectedDescription: "The menu opens"
        )
        let stop = registry.recoveryDecision(
            for: "com.apple.TextEdit",
            attempt: 3,
            noChange: false,
            expectedDescription: "The menu opens"
        )

        XCTAssertEqual(retry.action, .retry)
        XCTAssertTrue(retry.message.contains("TextEdit"))
        XCTAssertEqual(stop.action, .stop)
    }

    private func makeRequest(elements: [UIElementDescriptor]) -> InstructorRequest {
        InstructorRequest(
            question: "How do I export this as PDF?",
            scene: ScreenScene(
                timestamp: Date(),
                activeApplication: .init(
                    name: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 1
                ),
                activeWindow: nil,
                screenshot: nil,
                elements: elements,
                displays: []
            ),
            mode: .guide
        )
    }

    private func element(id: String, label: String, role: String) -> UIElementDescriptor {
        UIElementDescriptor(
            id: id,
            role: role,
            subrole: nil,
            label: label,
            title: nil,
            value: nil,
            enabled: true,
            focused: false,
            bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
        )
    }
}
