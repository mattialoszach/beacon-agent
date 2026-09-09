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

    func testRelevantVisualSurvivesSaturatedAccessibilityBudget() throws {
        var subject = scene(elements: (0..<20).map {
            element(id: "e_\($0)", label: "Generic control \($0)")
        })
        let genericVisuals: [VisualElementDescriptor] = (0..<8).map { index in
            let x = 0.45 + Double(index % 4) * 0.08
            let y = 0.2 + Double(index / 4) * 0.08
            return VisualElementDescriptor(
                id: "v_generic_\(index)", text: "Unrelated \(index)",
                bounds: .init(x: x, y: y, width: 0.06, height: 0.03),
                confidence: 0.99,
                kind: .text
            )
        }
        subject.visualElements = genericVisuals + [
            VisualElementDescriptor(
                id: "v_appearance", text: "Appearance",
                bounds: .init(x: 0.72, y: 0.72, width: 0.12, height: 0.04),
                confidence: 0.55,
                kind: .text
            )
        ]
        var request = InstructorRequest(
            question: "Where do I change to dark mode?",
            scene: subject,
            mode: .guide
        )
        request.setOfMarks = SetOfMarksBuilder().build(
            scene: subject,
            query: request.question
        )
        let appearanceMark = try XCTUnwrap(
            request.setOfMarks.first { $0.visualElementID == "v_appearance" }
        )

        let context = ModelContextBuilder(
            maximumElements: 4,
            maximumCharacters: 1_200
        ).build(for: request)

        XCTAssertTrue(context.includedVisualElementIDs.contains("v_appearance"))
        XCTAssertTrue(context.includedMarkIDs.contains(appearanceMark.id))
        XCTAssertLessThanOrEqual(
            context.includedElementIDs.count + context.includedVisualElementIDs.count,
            4
        )
        XCTAssertLessThanOrEqual(context.userPrompt.count, 1_200)
    }

    func testSpatiallyRelevantVisualWinsReservedSlot() {
        var subject = scene(elements: (0..<12).map {
            element(id: "e_\($0)", label: "Generic control \($0)")
        })
        subject.visualElements = [
            VisualElementDescriptor(
                id: "a_left", text: "Circle",
                bounds: .init(x: 0.1, y: 0.4, width: 0.08, height: 0.08),
                confidence: 0.8,
                kind: .circle
            ),
            VisualElementDescriptor(
                id: "z_right", text: "Circle",
                bounds: .init(x: 0.8, y: 0.4, width: 0.08, height: 0.08),
                confidence: 0.8,
                kind: .circle
            )
        ]

        let context = ModelContextBuilder(maximumElements: 4, maximumCharacters: 1_000)
            .build(for: InstructorRequest(
                question: "Select the circle on the right",
                scene: subject,
                mode: .guide
            ))

        XCTAssertTrue(context.includedVisualElementIDs.contains("z_right"))
        XCTAssertFalse(context.includedVisualElementIDs.contains("a_left"))
    }

    func testReservedVisualSurvivesCharacterSaturation() {
        var subject = scene(elements: (0..<20).map {
            element(
                id: "e_\($0)",
                label: "Control \($0) " + String(repeating: "description ", count: 20)
            )
        })
        subject.visualElements = [
            VisualElementDescriptor(
                id: "v_appearance", text: "Appearance",
                bounds: .init(x: 0.7, y: 0.7, width: 0.12, height: 0.04),
                confidence: 0.7,
                kind: .text
            )
        ]

        let context = ModelContextBuilder(maximumElements: 8, maximumCharacters: 430)
            .build(for: InstructorRequest(
                question: "Open Appearance",
                scene: subject,
                mode: .guide
            ))

        XCTAssertTrue(context.includedVisualElementIDs.contains("v_appearance"))
        XCTAssertLessThanOrEqual(context.userPrompt.count, 430)
    }

    func testAXRowReceivesActionableRanking() {
        let toolbar = UIElementDescriptor(
            id: "a_toolbar", role: "AXToolbar", subrole: nil, label: "Navigation",
            title: nil, value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        )
        let row = UIElementDescriptor(
            id: "z_row", role: "AXRow", subrole: nil, label: "Navigation",
            title: nil, value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.05)
        )

        let context = ModelContextBuilder(maximumElements: 1, maximumCharacters: 500)
            .build(for: InstructorRequest(
                question: "Continue",
                scene: scene(elements: [toolbar, row]),
                mode: .guide
            ))

        XCTAssertEqual(context.includedElementIDs, ["z_row"])
    }

    func testFusedOCRLabelStaysAttachedToAccessibilityMarkInPrompt() throws {
        var subject = scene(elements: (0..<20).map {
            element(id: "e_\($0)", label: "Generic control \($0)")
        } + [
            UIElementDescriptor(
                id: "row", role: "AXRow", subrole: nil, label: nil, title: nil,
                value: "0", enabled: true, focused: false,
                bounds: .init(x: 0.6, y: 0.4, width: 0.24, height: 0.08)
            )
        ])
        subject.visualElements = [
            VisualElementDescriptor(
                id: "v_appearance", text: "Appearance",
                bounds: .init(x: 0.64, y: 0.42, width: 0.12, height: 0.03),
                confidence: 0.9,
                kind: .text
            )
        ]
        var request = InstructorRequest(
            question: "Where do I change to dark mode?",
            scene: subject,
            mode: .guide
        )
        request.setOfMarks = SetOfMarksBuilder().build(
            scene: subject,
            query: request.question
        )
        let rowMark = try XCTUnwrap(request.setOfMarks.first { $0.elementID == "row" })

        let context = ModelContextBuilder(maximumElements: 4, maximumCharacters: 1_000)
            .build(for: request)

        XCTAssertTrue(context.includedElementIDs.contains("row"))
        XCTAssertTrue(context.includedMarkIDs.contains(rowMark.id))
        XCTAssertTrue(
            context.text.contains("[row mark=\(rowMark.id)] AXRow \"Appearance\"")
        )
        XCTAssertFalse(context.includedVisualElementIDs.contains("v_appearance"))
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

    func testVSCodeThemeRequestStartsAtTheCodeMenu() async throws {
        let response = try await provider.reason(request: request(
            question: "How can I change my VSCode theme?",
            labels: ["File", "Code", "Edit"]
        ))

        XCTAssertEqual(response.action?.targetElementId, "e_1")
        XCTAssertEqual(response.message, "Select Code.")
    }

    func testVSCodeThemeRequestContinuesToSettingsAfterCode() async throws {
        var request = request(
            question: "How can I change my VSCode theme?",
            labels: ["Code", "Settings", "Services"]
        )
        request.guideContext = GuideContext(
            stepNumber: 2,
            maximumSteps: 8,
            completedSteps: [
                CompletedGuideStep(
                    number: 1,
                    instruction: "Open the Code menu.",
                    targetElementID: "e_0",
                    targetLabel: "Code"
                )
            ]
        )

        let response = try await provider.reason(request: request)

        XCTAssertEqual(response.action?.targetElementId, "e_1")
        XCTAssertEqual(response.message, "Select Settings.")
    }

    func testProfileRequestContinuesThroughAVisibleAccountMenu() async throws {
        var request = request(
            question: "Where can I change my profile picture?",
            labels: ["Manage your Google Account", "Sign out"]
        )
        request.guideContext = GuideContext(
            stepNumber: 2,
            maximumSteps: 8,
            completedSteps: [
                CompletedGuideStep(
                    number: 1,
                    instruction: "Open your account menu.",
                    targetElementID: "old-profile-button",
                    targetLabel: "Profile picture"
                )
            ]
        )

        let response = try await provider.reason(request: request)

        XCTAssertEqual(response.action?.targetElementId, "e_0")
        XCTAssertEqual(response.message, "Select Manage your Google Account.")
    }

    func testRepeatedProfileLabelOnANewStableElementRemainsEligible() async throws {
        var request = request(
            question: "Where can I change my profile picture?",
            labels: ["Profile picture"]
        )
        request.guideContext = GuideContext(
            stepNumber: 3,
            maximumSteps: 8,
            completedSteps: [
                CompletedGuideStep(
                    number: 1,
                    instruction: "Open Profile picture.",
                    targetElementID: "profile-from-previous-page",
                    targetLabel: "Profile picture"
                )
            ]
        )

        let response = try await provider.reason(request: request)

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
