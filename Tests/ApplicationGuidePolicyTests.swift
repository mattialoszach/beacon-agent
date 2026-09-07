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

    func testRecipeCompletesWhenUserStartedWithTheMenuAlreadyOpen() throws {
        var request = makeRequest(elements: [])
        request.guideContext = GuideContext(stepNumber: 3, maximumSteps: 8, completedSteps: [
            CompletedGuideStep(number: 1, instruction: "Choose the PDF export command.",
                               targetElementID: "e_export", targetLabel: "Export as PDF…"),
            CompletedGuideStep(number: 2, instruction: "Choose Save to finish exporting the PDF.",
                               targetElementID: "e_save", targetLabel: "Save")
        ])
        XCTAssertEqual(planner.response(for: request)?.taskComplete, true)
    }

    func testUnrelatedCompletedStepsDoNotCompleteARecipe() {
        var request = makeRequest(elements: [element(id: "e_file", label: "File", role: "AXMenuBarItem")])
        request.guideContext = GuideContext(stepNumber: 4, maximumSteps: 8, completedSteps: (1...3).map {
            CompletedGuideStep(number: $0, instruction: "Some unrelated action", targetElementID: nil, targetLabel: nil)
        })
        XCTAssertEqual(planner.response(for: request)?.action?.targetElementId, "e_file")
        XCTAssertEqual(planner.response(for: request)?.taskComplete, false)
    }

    func testLocalMatcherDoesNotRepeatACompletedMarkOrAssumeCompletion() async throws {
        var request = makeRequest(elements: [element(id: "e_export", label: "Export", role: "AXButton")])
        request = InstructorRequest(question: "Export", scene: request.scene, mode: .guide)
        request.setOfMarks = SetOfMarksBuilder().build(scene: request.scene)
        request.guideContext = GuideContext(stepNumber: 2, maximumSteps: 8, completedSteps: [
            CompletedGuideStep(number: 1, instruction: "Select Export.", targetElementID: "e_export", targetLabel: "Export")
        ])
        let response = try await AccessibilityHeuristicProvider().reason(request: request)
        XCTAssertNil(response.action)
        XCTAssertEqual(response.taskComplete, false)
    }

    func testPreviewSelectsPDFBeforeSaveWhenInitialFormatIsJPEG() throws {
        var request = previewRequest(format: "JPEG", completed: ["Open the File menu.", "Choose the PDF export command."])
        XCTAssertEqual(planner.response(for: request)?.action?.targetElementId, "format")
        request.guideContext = .init(stepNumber: 4, maximumSteps: 8, completedSteps: [
            .init(number: 3, instruction: "Open the Format menu in the export sheet.", targetElementID: "format", targetLabel: "Format")
        ])
        request = InstructorRequest(question: request.question,
            scene: ScreenScene(timestamp: request.scene.timestamp, activeApplication: request.scene.activeApplication,
                activeWindow: nil, screenshot: nil, elements: request.scene.elements + [element(id: "pdf", label: "PDF", role: "AXMenuItem")], displays: []),
            mode: .guide, guideContext: request.guideContext)
        let response = try XCTUnwrap(planner.response(for: request))
        XCTAssertEqual(response.action?.targetElementId, "pdf")
        XCTAssertEqual(response.expectedOutcome?.element?.value, "PDF")
    }

    func testPreviewOnlyOffersSaveWhenPDFValueIsConfirmed() {
        let completed = ["Choose PDF as the export format."]
        for value in ["JPEG", "PNG"] {
            let response = planner.response(for: previewRequest(format: value, completed: completed))
            XCTAssertNotNil(response)
            XCTAssertNil(response?.action)
            XCTAssertEqual(response?.taskComplete, false)
        }
        let response = planner.response(for: previewRequest(format: "PDF", completed: completed))
        XCTAssertEqual(response?.action?.targetElementId, "save")
        XCTAssertEqual(response?.expectedOutcome?.canVerifyAutomatically, false)
    }

    func testPreviewSkipsFormatSelectionWhenAlreadyPDF() {
        let response = planner.response(for: previewRequest(format: "PDF", completed: ["Choose the PDF export command."]))
        XCTAssertEqual(response?.action?.targetElementId, "save")
    }

    func testRecipesRejectPartialLabelsWrongRolesAndDuplicateMatches() {
        for elements in [
            [element(id: "wrong", label: "File sharing", role: "AXMenuBarItem")],
            [element(id: "wrong", label: "File", role: "AXButton")],
            [element(id: "one", label: "File", role: "AXMenuBarItem"), element(id: "two", label: "File", role: "AXMenuBarItem")]
        ] {
            XCTAssertNil(planner.response(for: makeRequest(elements: elements))?.action)
        }
    }

    private func previewRequest(format: String, completed: [String]) -> InstructorRequest {
        let app = ApplicationDescriptor(name: "Preview", bundleIdentifier: "com.apple.Preview", processIdentifier: 1)
        let control = UIElementDescriptor(id: "format", role: "AXPopUpButton", subrole: nil, label: "Format", title: nil,
            value: format, enabled: true, focused: false, bounds: .init(x: 0.2, y: 0.2, width: 0.1, height: 0.1))
        return InstructorRequest(question: "Export PDF", scene: ScreenScene(timestamp: Date(), activeApplication: app,
            activeWindow: nil, screenshot: nil, elements: [control, element(id: "save", label: "Save", role: "AXButton")], displays: []),
            mode: .guide, guideContext: .init(stepNumber: completed.count + 1, maximumSteps: 8,
                completedSteps: completed.enumerated().map { .init(number: $0.offset + 1, instruction: $0.element, targetElementID: nil, targetLabel: nil) }))
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

final class GuideRecipeDeferralTests: XCTestCase {
    private let planner = ApplicationGuidePlanner()

    /// A recipe whose first control is missing usually means a localized or restructured
    /// interface. Returning a dead-end response would skip the model entirely.
    func testUnmatchedFirstStepDefersToTheModel() {
        let request = request(
            bundleID: "com.apple.Safari",
            question: "How do I open Safari settings?",
            elements: [element(id: "e_page", label: "Reader", role: "AXButton")],
            completed: []
        )

        XCTAssertNil(planner.response(for: request), "The model must get the chance to answer")
    }

    /// Once a step has been completed the recipe is committed, so a missing control is a
    /// real dead end and must stop with an actionable message rather than silently replan.
    func testUnmatchedLaterStepStopsWithAnActionableMessage() throws {
        let request = request(
            bundleID: "com.apple.Safari",
            question: "How do I open Safari settings?",
            elements: [element(id: "e_page", label: "Reader", role: "AXButton")],
            completed: ["Open the Safari menu."]
        )

        let response = try XCTUnwrap(planner.response(for: request))
        XCTAssertNil(response.action)
        XCTAssertEqual(response.taskComplete, false)
        XCTAssertTrue(response.message.contains("can’t safely locate"))
    }

    /// A value change can never be observed on a switch that is already on, so the guide
    /// must recognise the finished state instead of waiting for an impossible transition.
    func testAlreadyEnabledPermissionCompletesInsteadOfStalling() throws {
        let request = request(
            bundleID: "com.apple.systempreferences",
            question: "How do I enable screen recording for Beacon?",
            elements: [
                element(id: "e_beacon", label: "Beacon", role: "AXCheckBox", value: "1"),
                element(id: "e_pane", label: "Screen & System Audio Recording", role: "AXButton")
            ],
            completed: ["Open Privacy & Security.", "Open Screen & System Audio Recording."]
        )

        let response = try XCTUnwrap(planner.response(for: request))
        XCTAssertNil(response.action)
        XCTAssertEqual(response.taskComplete, true)
    }

    func testDisabledPermissionStillPointsAtTheSwitch() throws {
        let request = request(
            bundleID: "com.apple.systempreferences",
            question: "How do I enable screen recording for Beacon?",
            elements: [
                element(id: "e_beacon", label: "Beacon", role: "AXCheckBox", value: "0"),
                element(id: "e_pane", label: "Screen & System Audio Recording", role: "AXButton")
            ],
            completed: ["Open Privacy & Security.", "Open Screen & System Audio Recording."]
        )

        let response = try XCTUnwrap(planner.response(for: request))
        XCTAssertEqual(response.action?.targetElementId, "e_beacon")
    }

    /// A plain Save sheet also has exactly one Save button, so that alone must not be
    /// accepted as proof that the export sheet appeared.
    func testTextEditExportStepRequiresConfirmationRatherThanASaveButton() throws {
        let request = request(
            bundleID: "com.apple.TextEdit",
            question: "How do I export this as PDF?",
            elements: [element(id: "e_export", label: "Export as PDF…", role: "AXMenuItem")],
            completed: ["Open the File menu."]
        )

        let response = try XCTUnwrap(planner.response(for: request))
        let outcome = try XCTUnwrap(response.expectedOutcome)
        XCTAssertEqual(outcome.type, .windowAppears)
        XCTAssertFalse(
            outcome.canVerifyAutomatically,
            "A generic Save button must not auto-verify the TextEdit export step"
        )
    }

    func testPreviewExportStepVerifiesOnTheFormatPopupThatOnlyItHas() throws {
        let request = request(
            bundleID: "com.apple.Preview",
            question: "How do I export this as PDF?",
            elements: [element(id: "e_export", label: "Export…", role: "AXMenuItem")],
            completed: ["Open the File menu."]
        )

        let response = try XCTUnwrap(planner.response(for: request))
        let outcome = try XCTUnwrap(response.expectedOutcome)
        XCTAssertTrue(outcome.canVerifyAutomatically)
        XCTAssertEqual(outcome.element?.labels, ["Format"])
        XCTAssertEqual(outcome.element?.role, "AXPopUpButton")
    }

    private func request(
        bundleID: String,
        question: String,
        elements: [UIElementDescriptor],
        completed: [String]
    ) -> InstructorRequest {
        InstructorRequest(
            question: question,
            scene: ScreenScene(
                timestamp: Date(),
                activeApplication: .init(name: bundleID, bundleIdentifier: bundleID, processIdentifier: 3),
                activeWindow: nil,
                screenshot: nil,
                elements: elements,
                displays: []
            ),
            mode: .guide,
            guideContext: .init(
                stepNumber: completed.count + 1,
                maximumSteps: 8,
                completedSteps: completed.enumerated().map {
                    .init(number: $0.offset + 1, instruction: $0.element, targetElementID: nil, targetLabel: nil)
                }
            )
        )
    }

    private func element(
        id: String,
        label: String,
        role: String,
        value: String? = nil
    ) -> UIElementDescriptor {
        UIElementDescriptor(
            id: id, role: role, subrole: nil, label: label, title: nil, value: value,
            enabled: true, focused: false, bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
        )
    }
}
