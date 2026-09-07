import Foundation
import XCTest
@testable import Beacon

final class ModelContextBuilderTests: XCTestCase {
    func testOutcomeValuesStayBoundedAndSensitiveValuesAreFiltered() {
        let controls = [("format", "AXPopUpButton", "PDF"),
                        ("private", "AXPopUpButton", "person@example.com"),
                        ("field", "AXTextField", "unshared text-field content")].map { id, role, value in
            UIElementDescriptor(id: id, role: role, subrole: nil, label: id, title: nil,
                value: value, enabled: true, focused: false,
                bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.1))
        }
        let context = ModelContextBuilder(maximumCharacters: 600).build(for: .init(
            question: "Export PDF", scene: scene(elements: controls), mode: .guide))
        XCTAssertTrue(context.text.contains("value=\"PDF\""))
        XCTAssertTrue(context.text.contains("[redacted sensitive text]"))
        XCTAssertFalse(context.text.contains("person@example.com"))
        XCTAssertFalse(context.text.contains("unshared text-field content"))
        XCTAssertLessThanOrEqual(context.userPrompt.count, 600)
    }

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
        XCTAssertLessThanOrEqual(context.userPrompt.count, 6_000)
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

    func testContextMapsValidatedMarksToTheirCandidates() {
        let export = element(id: "e_export", label: "Export")
        var request = InstructorRequest(
            question: "Export this",
            scene: scene(elements: [export]),
            mode: .guide
        )
        request.setOfMarks = [
            SetOfMark(
                id: 4,
                elementID: export.id,
                visualElementID: nil,
                bounds: export.bounds!,
                label: export.bestLabel,
                source: .accessibility,
                visualKind: nil
            )
        ]

        let context = ModelContextBuilder().build(for: request)

        XCTAssertTrue(context.includedMarkIDs.contains(4))
        XCTAssertTrue(context.text.contains("mark=4"))
    }

    func testQuestionAndCompletedStepsShareTheBudgetAndHistoryIsRedacted() {
        var request = InstructorRequest(
            question: String(repeating: "Export the document. ", count: 1_000),
            scene: scene(elements: (0..<100).map { element(id: "e_\($0)", label: "Export \($0)") }),
            mode: .guide
        )
        request.guideContext = GuideContext(stepNumber: 9, maximumSteps: 8, completedSteps: (1...8).map {
            CompletedGuideStep(
                number: $0,
                instruction: String(repeating: "Open person@example.com ", count: 500),
                targetElementID: nil,
                targetLabel: "person@example.com"
            )
        })
        for limit in [2_800, 6_000, 12_000] {
            let context = ModelContextBuilder(maximumCharacters: limit).build(for: request)
            XCTAssertLessThanOrEqual(context.userPrompt.count, limit)
            XCTAssertFalse(context.userPrompt.contains("person@example.com"))
            XCTAssertTrue(context.includedElementIDs.contains("e_0"))
            for step in 1...8 { XCTAssertTrue(context.text.contains("Step \(step):")) }
        }
    }

    func testEmptyAndNegativeBudgetsDoNotOverflowOrCrash() {
        let request = InstructorRequest(question: "Export", scene: scene(elements: []), mode: .guide)
        for limit in [-1, 0, 1, 8, 20] {
            let context = ModelContextBuilder(maximumElements: -1, maximumCharacters: limit).build(for: request)
            XCTAssertLessThanOrEqual(context.userPrompt.count, max(0, limit))
            XCTAssertTrue(context.includedElementIDs.isEmpty)
        }
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

final class LocalNavigationFallbackTests: XCTestCase {
    private let provider = AccessibilityHeuristicProvider()

    /// The File-menu branch matched the substring "open" and shadowed every other intent,
    /// walking the user into the Open dialog when they asked for preferences.
    func testPreferencesRequestDoesNotPointAtTheFileMenu() async throws {
        let response = try await provider.reason(request: request(
            question: "How do I open preferences?",
            labels: ["File", "Edit", "Format"]
        ))

        XCTAssertNil(response.action, "No settings control is visible, so there is no honest target")
    }

    func testPreferencesRequestFindsAVisibleSettingsControl() async throws {
        let response = try await provider.reason(request: request(
            question: "How do I open preferences?",
            labels: ["File", "Settings…"]
        ))

        XCTAssertEqual(response.action?.targetElementId, "e_1")
    }

    func testWordsInsideOtherWordsDoNotTriggerTheFileBranch() async throws {
        let response = try await provider.reason(request: request(
            question: "How do I read this blueprint?",
            labels: ["File", "Edit"]
        ))

        XCTAssertNil(response.action, "\"blueprint\" must not be read as \"print\"")
    }

    func testAGenuineExportRequestStillFindsTheFileMenu() async throws {
        let response = try await provider.reason(request: request(
            question: "How do I export the document?",
            labels: ["File", "Edit"]
        ))

        XCTAssertEqual(response.action?.targetElementId, "e_0")
    }

    private func request(question: String, labels: [String]) -> InstructorRequest {
        InstructorRequest(
            question: question,
            scene: ScreenScene(
                timestamp: Date(),
                activeApplication: .init(name: "App", bundleIdentifier: "com.example.app", processIdentifier: 9),
                activeWindow: nil,
                screenshot: nil,
                elements: labels.enumerated().map { index, label in
                    UIElementDescriptor(
                        id: "e_\(index)", role: "AXMenuBarItem", subrole: nil, label: label,
                        title: nil, value: nil, enabled: true, focused: false,
                        bounds: .init(x: 0.1, y: 0.01, width: 0.05, height: 0.02)
                    )
                },
                displays: []
            ),
            mode: .guide
        )
    }
}
