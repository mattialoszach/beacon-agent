import CoreGraphics
import ApplicationServices
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Beacon

@MainActor
final class BeaconControllerLifecycleTests: XCTestCase {
    private let memoryTarget = GroundedTarget.accessibilityElement(
        elementId: "memory", bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1))

    func testCancelDiscardsAnUncooperativeModelResult() async throws {
        let gate = ResponseGate()
        let controller = makeController(model: DelayedModel(gate: gate))
        let task = Task { await controller.run(question: "Export", mode: .ask, initialScene: fixture()) }
        await gate.waitUntilStarted()
        XCTAssertEqual(controller.state, .understanding)

        controller.cancel()
        await gate.finish()
        await task.value

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.currentResponse)
        XCTAssertTrue(controller.history.isEmpty)
        XCTAssertNil(controller.errorMessage)
    }

    func testCancelledResultCannotOverwriteANewerRequest() async {
        let gate = ResponseGate()
        let controller = makeController(model: DelayedModel(gate: gate))
        let old = Task { await controller.run(question: "Export", mode: .ask, initialScene: fixture()) }
        await gate.waitUntilStarted()
        await controller.run(question: "New question", mode: .ask, initialScene: fixture())
        await gate.finish()
        await old.value

        XCTAssertEqual(controller.currentResponse?.message, "New answer")
        XCTAssertEqual(controller.currentQuestion, "New question")
        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(controller.history.count, 1)
        controller.cancel()
    }

    func testPauseDiscardsAnInspectorCaptureAndBlocksFurtherCaptures() async {
        let gate = ResponseGate()
        var captureCount = 0
        let scene = fixture()
        let controller = makeController(captureScene: {
            captureCount += 1
            _ = await gate.response()
            return scene
        })
        let refresh = Task { await controller.refreshInspector() }
        await gate.waitUntilStarted()
        controller.screenAccessPaused = true
        await gate.finish()
        await refresh.value
        await controller.refreshInspector()
        await controller.run(question: "Export", mode: .ask)

        XCTAssertEqual(captureCount, 1)
        XCTAssertNil(controller.currentScene)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.state, .idle)
    }

    func testPrivacyRevocationInvalidatesAnInFlightRequest() async {
        let gate = ResponseGate()
        let controller = makeController(model: DelayedModel(gate: gate))
        controller.privacySettings.cloudProcessingEnabled = true
        let task = Task { await controller.run(question: "Export", mode: .ask, initialScene: fixture()) }
        await gate.waitUntilStarted()
        controller.privacySettings.cloudProcessingEnabled = false
        await gate.finish()
        await task.value

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.currentResponse)
        XCTAssertNil(controller.currentScene)
        XCTAssertNil(controller.outboundImagePreview)
        XCTAssertTrue(controller.modelContextPreview.isEmpty)
    }

    func testProviderFailureFallsBackLocally() async {
        let scene = largeInspectorScene()
        let question = "What is this interface?"
        let contexts = inspectorContexts(question: question, mode: .ask, scene: scene)
        XCTAssertNotEqual(contexts.provider, contexts.local)
        XCTAssertTrue(contexts.provider.contains("[element-069"))
        XCTAssertFalse(contexts.local.contains("[element-069"))
        let controller = makeController(model: FailingModel())

        await controller.run(question: question, mode: .ask, initialScene: scene)

        XCTAssertEqual(controller.state, .completed)
        XCTAssertNotNil(controller.currentResponse)
        XCTAssertEqual(controller.modelContextPreview, contexts.provider)
        XCTAssertTrue(controller.errorMessage?.contains("Using local") == true)
        controller.cancel()
    }

    func testTargetlessIncompleteGuideFallsBackToLocalPointingStep() async {
        let scene = largeInspectorScene(targetLabel: "Export")
        let question = "Where is Export?"
        let contexts = inspectorContexts(question: question, mode: .guide, scene: scene)
        XCTAssertNotEqual(contexts.provider, contexts.local)
        let response = InstructorResponse(
            message: "Export is somewhere in this window.",
            action: nil,
            expectedOutcome: nil,
            taskComplete: false
        )
        let controller = makeController(
            model: FixedModel(id: "OpenAI", response: response),
            captureScene: { scene }
        )

        await controller.run(question: question, mode: .guide, initialScene: scene)

        XCTAssertEqual(controller.currentResponse?.action?.targetElementId, "element-069")
        XCTAssertEqual(controller.state, .waitingForChange)
        XCTAssertNil(controller.confirmationMessage)
        XCTAssertEqual(controller.modelContextPreview, contexts.provider)
        XCTAssertTrue(controller.errorMessage?.contains("Using local Accessibility matching") == true)
        controller.cancel()
    }

    func testTargetlessIncompleteGuideFailsInsteadOfBecomingAnAnswer() async {
        let response = InstructorResponse(
            message: "Reveal the next control.",
            action: nil,
            expectedOutcome: nil,
            taskComplete: false
        )
        let controller = makeController(model: FixedModel(response: response))

        await controller.run(question: "Finish this task", mode: .guide, initialScene: fixture())

        XCTAssertEqual(controller.state, .failed)
        XCTAssertNil(controller.currentResponse)
        XCTAssertTrue(controller.history.isEmpty)
        XCTAssertTrue(controller.errorMessage?.contains("safe on-screen target") == true)
        XCTAssertNotEqual(controller.statusMessage, "Answered")
        controller.cancel()
    }

    func testContradictoryGuideCompletionFieldsCannotStopEarly() async {
        let responses = [
            InstructorResponse(
                message: "Click this even though the task is already done.",
                action: SuggestedAction(
                    type: .pointToElement,
                    targetElementId: "missing",
                    targetBounds: nil,
                    overlay: .spotlight
                ),
                expectedOutcome: nil,
                taskComplete: true
            ),
            InstructorResponse(
                message: "This missing action will finish the task.",
                action: nil,
                expectedOutcome: nil,
                taskComplete: false,
                completesTaskAfterSuccess: true
            ),
            InstructorResponse(
                message: "Complete, but not complete.",
                action: SuggestedAction(
                    type: .complete,
                    targetElementId: nil,
                    targetBounds: nil,
                    overlay: .spotlight
                ),
                expectedOutcome: nil,
                taskComplete: false
            )
        ]

        for response in responses {
            let controller = makeController(model: FixedModel(response: response))

            await controller.run(
                question: "Finish this task",
                mode: .guide,
                initialScene: fixture()
            )

            XCTAssertEqual(controller.state, .failed)
            XCTAssertFalse(controller.history.contains { $0.succeeded == true })
            controller.cancel()
        }
    }

    func testTargetlessAskResponseRemainsAnInformationalAnswer() async {
        let response = InstructorResponse(
            message: "This window contains export options.",
            action: nil,
            expectedOutcome: nil,
            taskComplete: false
        )
        let controller = makeController(model: FixedModel(response: response))

        await controller.run(question: "What is this window?", mode: .ask, initialScene: fixture())

        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(controller.statusMessage, "Answered")
        XCTAssertEqual(controller.currentResponse?.message, response.message)
        controller.cancel()
    }

    func testConfirmedFinalActionCompletesWithoutAnotherModelCall() async {
        let target = UIElementDescriptor(
            id: "target", role: "AXButton", subrole: nil, label: "Finish", title: nil,
            value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
        )
        let scene = ScreenScene(
            timestamp: Date(), activeApplication: fixture().activeApplication,
            activeWindow: nil, screenshot: nil, elements: [target], displays: []
        )
        let model = FinalGuideModel()
        let controller = makeController(model: model, captureScene: { scene })

        await controller.run(question: "Finish this task", mode: .guide, initialScene: scene)
        XCTAssertEqual(controller.state, .awaitingConfirmation)
        XCTAssertEqual(controller.currentResponse?.completesTaskAfterSuccess, true)

        await controller.confirmResult(succeeded: true)

        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(controller.history.first?.succeeded, true)
        controller.cancel()
    }

    func testAutomaticallyVerifiedFinalActionCompletesWithoutAnotherModelCall() async throws {
        func scene(value: String) -> ScreenScene {
            ScreenScene(
                timestamp: Date(), activeApplication: fixture().activeApplication,
                activeWindow: nil, screenshot: nil,
                elements: [
                    UIElementDescriptor(
                        id: "target", role: "AXCheckBox", subrole: nil,
                        label: "Finish", title: nil, value: value,
                        enabled: true, focused: false,
                        bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
                    )
                ],
                displays: []
            )
        }
        let before = scene(value: "0")
        let after = scene(value: "1")
        var current = before
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        let model = FinalGuideModel(expectedOutcome: ExpectedOutcome(
            type: .visualChange,
            description: "Finish is enabled.",
            element: ExpectedElement(labels: ["Finish"], role: "AXCheckBox", value: "1")
        ))
        let controller = makeController(
            model: model,
            captureScene: { current },
            observationEvents: { _, _ in events.stream }
        )

        await controller.run(question: "Finish this task", mode: .guide, initialScene: before)
        XCTAssertEqual(controller.state, .waitingForChange)
        current = after
        events.continuation.yield(.fallbackTimer)
        try await waitUntil { controller.state == .completed }

        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(controller.history.first?.succeeded, true)
        controller.cancel()
    }

    func testProfileGuideFollowsOpenedAccountMenuAndPointsToNextControl() async throws {
        let profile = UIElementDescriptor(
            id: "profile", role: "AXButton", subrole: nil, label: "Google Account profile picture",
            title: nil, value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.88, y: 0.04, width: 0.05, height: 0.05)
        )
        let manageAccount = UIElementDescriptor(
            id: "manage-account", role: "AXButton", subrole: nil,
            label: "Manage your Google Account", title: nil, value: nil,
            enabled: true, focused: false,
            bounds: .init(x: 0.7, y: 0.12, width: 0.22, height: 0.06)
        )
        func scene(elements: [UIElementDescriptor]) -> ScreenScene {
            ScreenScene(
                timestamp: Date(),
                activeApplication: .init(
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    processIdentifier: 42
                ),
                activeWindow: .init(title: "Google", bounds: nil, id: "browser"),
                screenshot: nil,
                elements: elements,
                displays: []
            )
        }
        let before = scene(elements: [profile])
        let after = scene(elements: [profile, manageAccount])
        var current = before
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        let model = ProfileNavigationModel()
        let controller = makeController(
            model: model,
            captureScene: { current },
            observationEvents: { _, _ in events.stream }
        )

        await controller.run(
            question: "Where can I change my profile picture?",
            mode: .guide,
            initialScene: before
        )
        XCTAssertEqual(controller.state, .waitingForChange)
        XCTAssertEqual(controller.currentResponse?.action?.targetElementId, profile.id)
        XCTAssertNil(controller.confirmationMessage)

        current = after
        events.continuation.yield(.fallbackTimer)
        try await waitUntil {
            controller.currentResponse?.action?.targetElementId == manageAccount.id
                && controller.state == .waitingForChange
        }

        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(model.requests.last?.guideContext?.completedSteps.count, 1)
        XCTAssertNil(controller.confirmationMessage)
        controller.cancel()
    }

    func testProfileGuideDoesNotAdvanceForFocusOnlyNoise() async throws {
        func scene(focused: Bool) -> ScreenScene {
            ScreenScene(
                timestamp: Date(),
                activeApplication: .init(
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    processIdentifier: 42
                ),
                activeWindow: .init(title: "Google", bounds: nil, id: "browser"),
                screenshot: nil,
                elements: [
                    UIElementDescriptor(
                        id: "profile", role: "AXButton", subrole: nil,
                        label: "Google Account profile picture", title: nil, value: nil,
                        enabled: true, focused: focused,
                        bounds: .init(x: 0.88, y: 0.04, width: 0.05, height: 0.05)
                    )
                ],
                displays: []
            )
        }
        let before = scene(focused: false)
        var current = before
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        let model = ProfileNavigationModel()
        let controller = makeController(
            model: model,
            captureScene: { current },
            observationEvents: { _, _ in events.stream }
        )

        await controller.run(
            question: "Where can I change my profile picture?",
            mode: .guide,
            initialScene: before
        )
        current = scene(focused: true)
        events.continuation.yield(.fallbackTimer)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(controller.state, .waitingForChange)
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(controller.currentResponse?.action?.targetElementId, "profile")
        controller.cancel()
    }

    func testVSCodeCodeMenuOpeningAdvancesWhenAccessibilityTreeIsStatic() async throws {
        let codeMenu = UIElementDescriptor(
            id: "code-menu", role: "AXMenuBarItem", subrole: nil, label: "Code",
            title: nil, value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.01, y: 0, width: 0.04, height: 0.03)
        )
        // Electron can expose this descendant before its menu is visibly open. That
        // makes elementAppears verification inconclusive even though the user clicked
        // the highlighted Code menu.
        let settings = UIElementDescriptor(
            id: "settings-menu", role: "AXMenuItem", subrole: nil, label: "Settings",
            title: nil, value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.01, y: 0.04, width: 0.16, height: 0.04)
        )
        let unchangedScene = ScreenScene(
            timestamp: Date(),
            activeApplication: .init(
                name: "Visual Studio Code",
                bundleIdentifier: "com.microsoft.VSCode",
                processIdentifier: 86
            ),
            activeWindow: .init(title: "Beacon — Visual Studio Code", bounds: nil, id: "editor"),
            screenshot: nil,
            elements: [codeMenu, settings],
            displays: []
        )
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        let model = VSCodeThemeNavigationModel()
        let controller = makeController(
            model: model,
            captureScene: { unchangedScene },
            observationEvents: { _, _ in events.stream }
        )

        await controller.run(
            question: "How can I change my VSCode theme?",
            mode: .guide,
            initialScene: unchangedScene
        )
        XCTAssertEqual(controller.state, .waitingForChange)
        XCTAssertEqual(controller.currentResponse?.action?.targetElementId, codeMenu.id)

        events.continuation.yield(.notification(
            name: kAXMenuOpenedNotification,
            role: "AXMenu",
            label: "File"
        ))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.requests.count, 1, "Opening another menu must not confirm Code")

        events.continuation.yield(.notification(
            name: kAXMenuOpenedNotification,
            role: "AXMenu",
            label: "Code"
        ))
        try await waitUntil {
            controller.currentResponse?.action?.targetElementId == settings.id
                && controller.state == .waitingForChange
        }

        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(model.requests.last?.guideContext?.completedSteps.count, 1)
        XCTAssertNil(controller.confirmationMessage)
        controller.cancel()
    }

    func testRepeatedObservationCaptureFailuresStopInsteadOfWaitingIndefinitely() async throws {
        let target = UIElementDescriptor(
            id: "target", role: "AXButton", subrole: nil, label: "Profile", title: nil,
            value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.8, y: 0.05, width: 0.08, height: 0.05)
        )
        let scene = ScreenScene(
            timestamp: Date(),
            activeApplication: fixture().activeApplication,
            activeWindow: nil,
            screenshot: nil,
            elements: [target],
            displays: []
        )
        var shouldFail = false
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        let controller = makeController(
            model: FinalGuideModel(),
            captureScene: {
                if shouldFail { throw URLError(.cannotParseResponse) }
                return scene
            },
            observationEvents: { _, _ in events.stream }
        )

        await controller.run(
            question: "Where is my profile?",
            mode: .guide,
            initialScene: scene
        )
        XCTAssertEqual(controller.state, .waitingForChange)
        shouldFail = true
        for _ in 0..<3 { events.continuation.yield(.fallbackTimer) }
        try await waitUntil { controller.state == .failed }

        XCTAssertTrue(controller.statusMessage.contains("three attempts"))
        XCTAssertFalse(controller.isObserving)
        controller.cancel()
    }

    func testAccessibilityChangeUsesLocalOCRToVerifyAnUnlabelledAppearingControl() async throws {
        let app = ApplicationDescriptor(
            name: "System Settings",
            bundleIdentifier: "com.apple.systempreferences",
            processIdentifier: 123
        )
        let window = WindowDescriptor(title: "Appearance", bounds: nil, id: "settings")
        let appearance = UIElementDescriptor(
            id: "appearance", role: "AXRow", subrole: nil, label: "Appearance",
            title: nil, value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.08), windowID: "settings"
        )
        let darkBounds = NormalizedRect(x: 0.55, y: 0.2, width: 0.18, height: 0.08)
        let dark = UIElementDescriptor(
            id: "dark", role: "AXRadioButton", subrole: nil, label: nil,
            title: nil, value: "0", enabled: true, focused: false,
            bounds: darkBounds, windowID: "settings"
        )
        let before = ScreenScene(
            timestamp: Date(), activeApplication: app, activeWindow: window,
            screenshot: nil, elements: [appearance], displays: []
        )
        let after = ScreenScene(
            timestamp: Date(), activeApplication: app, activeWindow: window,
            screenshot: nil, elements: [appearance, dark], displays: []
        )
        var current = before
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        let captures = CaptureRecorder()
        let response = InstructorResponse(
            message: "Open Appearance.",
            action: SuggestedAction(
                type: .pointToElement,
                targetElementId: appearance.id,
                targetBounds: nil,
                overlay: .spotlight
            ),
            expectedOutcome: ExpectedOutcome(
                type: .elementAppears,
                description: "The Dark appearance choice should appear.",
                element: ExpectedElement(labels: ["Dark"], role: "AXRadioButton")
            ),
            taskComplete: false,
            completesTaskAfterSuccess: true
        )
        let controller = makeController(
            model: FixedModel(response: response),
            captureScene: { current },
            observationEvents: { _, _ in events.stream },
            captureSnapshot: { _ in captures.snapshot() },
            analyzeVisualContext: { _ in
                [
                    VisualElementDescriptor(
                        id: "ocr_dark", text: "Dark",
                        bounds: .init(x: 0.58, y: 0.22, width: 0.08, height: 0.03),
                        confidence: 0.95, kind: .text
                    )
                ]
            },
            hasScreenCapturePermission: { true }
        )

        await controller.run(
            question: "Open Appearance",
            mode: .guide,
            initialScene: before
        )
        XCTAssertEqual(controller.state, .waitingForChange)
        XCTAssertEqual(captures.callCount, 0)

        current = after
        events.continuation.yield(.fallbackTimer)
        try await waitUntil { controller.state == .completed }

        XCTAssertEqual(captures.callCount, 1)
        XCTAssertEqual(controller.history.first?.succeeded, true)
        XCTAssertTrue(controller.currentScene?.visualElements.contains { $0.text == "Dark" } == true)
        XCTAssertNil(controller.outboundImagePreview)
        controller.cancel()
    }

    func testSystemSettingsReacquiresOCRForValueOnlyDarkAfterAppearanceCompletes() async throws {
        let app = ApplicationDescriptor(
            name: "System Settings",
            bundleIdentifier: "com.apple.systempreferences",
            processIdentifier: 123
        )
        let window = WindowDescriptor(title: "System Settings", bounds: nil, id: "settings")
        let appearance = UIElementDescriptor(
            id: "appearance", role: "AXRow", subrole: nil, label: "Appearance",
            title: nil, value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.08), windowID: "settings"
        )
        let dark = UIElementDescriptor(
            id: "dark", role: "AXRadioButton", subrole: nil, label: nil,
            title: nil, value: "0", enabled: true, focused: false,
            bounds: .init(x: 0.55, y: 0.2, width: 0.18, height: 0.08), windowID: "settings"
        )
        let before = ScreenScene(
            timestamp: Date(), activeApplication: app, activeWindow: window,
            screenshot: nil, elements: [appearance], displays: []
        )
        let afterAppearance = ScreenScene(
            timestamp: Date(), activeApplication: app, activeWindow: window,
            screenshot: nil, elements: [appearance, dark], displays: []
        )
        var current = before
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        let captures = CaptureRecorder()
        let controller = makeController(
            captureScene: { current },
            observationEvents: { _, _ in events.stream },
            captureSnapshot: { _ in captures.snapshot() },
            analyzeVisualContext: { _ in
                [
                    VisualElementDescriptor(
                        id: "ocr_dark", text: "Dark",
                        bounds: .init(x: 0.58, y: 0.22, width: 0.08, height: 0.03),
                        confidence: 0.95, kind: .text
                    )
                ]
            },
            hasScreenCapturePermission: { true }
        )

        await controller.run(question: "Dark mode", mode: .guide, initialScene: before)
        XCTAssertEqual(controller.currentResponse?.message, "Open Appearance.")
        XCTAssertEqual(controller.state, .waitingForChange)
        XCTAssertEqual(captures.callCount, 0)

        current = afterAppearance
        events.continuation.yield(.fallbackTimer)
        try await waitUntil {
            controller.currentResponse?.message == "Choose Dark."
                && controller.state == .waitingForChange
        }

        XCTAssertEqual(controller.currentResponse?.action?.targetElementId, dark.id)
        XCTAssertEqual(captures.callCount, 2)
        XCTAssertEqual(controller.history.last?.succeeded, true)
        XCTAssertTrue(controller.currentScene?.visualElements.contains { $0.text == "Dark" } == true)
        XCTAssertNil(controller.outboundImagePreview)
        controller.cancel()
    }

    func testModelCompletionNeedsUserConfirmation() async {
        let response = InstructorResponse(message: "All done", action: nil, expectedOutcome: nil, taskComplete: true)
        let controller = makeController(model: FixedModel(response: response))
        await controller.run(question: "Finish", mode: .guide, initialScene: fixture())
        XCTAssertEqual(controller.state, .awaitingConfirmation)
        XCTAssertNil(controller.history.first?.succeeded)
        XCTAssertNotNil(controller.confirmationMessage)
        await controller.confirmResult(succeeded: true)
        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(controller.history.first?.succeeded, true)
        XCTAssertNil(controller.confirmationMessage)
        controller.cancel()
    }

    func testDecliningOrCancellingConfirmationNeverCompletesTheTask() async {
        for cancel in [false, true] {
            let controller = makeController(model: FixedModel(response: .init(
                message: "All done", action: nil, expectedOutcome: nil, taskComplete: true)))
            await controller.run(question: "Finish", mode: .guide, initialScene: fixture())
            if cancel { controller.cancel() } else { await controller.confirmResult(succeeded: false) }
            await controller.confirmResult(succeeded: true)
            XCTAssertEqual(controller.state, cancel ? .idle : .failed)
            XCTAssertNotEqual(controller.history.first?.succeeded, true)
            XCTAssertNil(controller.confirmationMessage)
        }
    }

    func testACompletedRequestDoesNotResolveAnOlderCancelledHistoryRow() async {
        let response = InstructorResponse(
            message: "All done",
            action: nil,
            expectedOutcome: nil,
            taskComplete: true
        )
        let controller = makeController(model: FixedModel(response: response))

        await controller.run(question: "First task", mode: .guide, initialScene: fixture())
        let cancelledRowID = controller.history[0].id
        controller.cancel()

        await controller.run(question: "Second task", mode: .guide, initialScene: fixture())
        let completedRowID = controller.history[0].id
        await controller.confirmResult(succeeded: true)

        XCTAssertEqual(controller.history.count, 2)
        XCTAssertEqual(controller.history[0].id, completedRowID)
        XCTAssertEqual(controller.history[0].question, "Second task")
        XCTAssertEqual(controller.history[0].succeeded, true)
        XCTAssertEqual(controller.history[1].id, cancelledRowID)
        XCTAssertEqual(controller.history[1].question, "First task")
        XCTAssertNil(controller.history[1].succeeded)
        controller.cancel()
    }

    func testDisplayChangeDiscardsInFlightModelResult() async {
        let gate = ResponseGate()
        let controller = makeController(model: DelayedModel(gate: gate))
        let task = Task { await controller.run(question: "Export", mode: .ask, initialScene: fixture()) }
        await gate.waitUntilStarted()
        controller.displayConfigurationChanged()
        await gate.finish()
        await task.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.currentScene)
        XCTAssertNil(controller.currentResponse)
        XCTAssertNil(controller.selectedTarget)
        XCTAssertTrue(controller.statusMessage.contains("display layout changed"))
    }

    func testPresentationUsesAStableTargetFromATruncatedFreshnessCapture() async {
        let target = UIElementDescriptor(
            id: "target",
            role: "AXButton",
            subrole: nil,
            label: "Continue",
            title: nil,
            value: nil,
            enabled: true,
            focused: false,
            bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
            windowID: "window"
        )
        let source = ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Fixture", bundleIdentifier: "test.fixture", processIdentifier: 123),
            activeWindow: .init(title: "Main", bounds: nil, id: "window"),
            screenshot: nil,
            elements: [target],
            displays: []
        )
        var captures = 0
        let controller = makeController(
            model: FixedModel(response: InstructorResponse(
                message: "Choose Continue",
                action: SuggestedAction(
                    type: .pointToElement,
                    targetElementId: "target",
                    targetBounds: nil,
                    overlay: .spotlight
                ),
                expectedOutcome: ExpectedOutcome(
                    type: .elementAppears,
                    description: "The result appears",
                    element: ExpectedElement(labels: ["Result"], role: "AXButton")
                ),
                taskComplete: false
            )),
            captureScene: {
                captures += 1
                var captured = source
                captured.isTruncated = true
                return captured
            }
        )

        await controller.run(question: "Continue", mode: .guide, initialScene: source)

        XCTAssertEqual(captures, 1)
        XCTAssertEqual(controller.state, .waitingForChange)
        XCTAssertNil(controller.errorMessage)
        controller.cancel()
    }

    func testManualStepsRespectEightStepLimit() async {
        let scene = ScreenScene(timestamp: Date(), activeApplication: fixture().activeApplication,
            activeWindow: nil, screenshot: nil, elements: [
                UIElementDescriptor(id: "target", role: "AXButton", subrole: nil, label: "Next", title: nil,
                    value: nil, enabled: true, focused: false, bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
            ], displays: [])
        let model = CountingGuideModel()
        let controller = makeController(model: model, captureScene: { scene })
        await controller.run(question: "Continue", mode: .guide, initialScene: scene)
        for _ in 1...8 {
            XCTAssertEqual(controller.state, .awaitingConfirmation)
            await controller.confirmResult(succeeded: true)
        }
        XCTAssertEqual(controller.state, .completed)
        XCTAssertEqual(model.requests.count, 8)
        XCTAssertEqual(model.requests.last?.guideContext?.completedSteps.count, 7)
        XCTAssertTrue(controller.statusMessage.contains("8-step safety limit"))
        XCTAssertTrue(controller.history.allSatisfy { $0.succeeded == true })
        controller.cancel()
    }

    func testManualConfirmationContinuesInTheCurrentApplication() async {
        let element = UIElementDescriptor(id: "target", role: "AXButton", subrole: nil, label: "Next", title: nil,
            value: nil, enabled: true, focused: false, bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let baseline = ScreenScene(timestamp: Date(), activeApplication: fixture().activeApplication,
            activeWindow: nil, screenshot: nil, elements: [element], displays: [])
        let other = ScreenScene(timestamp: Date(), activeApplication: .init(name: "Other", bundleIdentifier: nil, processIdentifier: 999),
            activeWindow: nil, screenshot: nil, elements: [element], displays: [])
        var switched = false
        let model = CountingGuideModel()
        let controller = makeController(model: model, captureScene: { switched ? other : baseline })
        await controller.run(question: "Continue", mode: .guide, initialScene: baseline)
        XCTAssertEqual(controller.state, .awaitingConfirmation)
        switched = true
        await controller.confirmResult(succeeded: true)
        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(model.requests.last?.scene.activeApplication, other.activeApplication)
        XCTAssertEqual(model.requests.last?.guideContext?.completedSteps.count, 1)
        XCTAssertEqual(controller.state, .awaitingConfirmation)
        controller.cancel()
    }

    func testAppChangeDuringReasoningReplansTheOriginalQuestionWithoutCompletingAStep() async {
        let safari = navigationScene()
        let about = navigationScene(bundleID: "test.about", windowID: "about", targetID: "memory")
        for mode in [InteractionMode.guide, .ask] {
            let model = NavigationModel()
            let controller = makeController(model: model, captureScene: { about })
            await controller.run(question: "Find how much RAM this laptop has", mode: mode, initialScene: safari)

            XCTAssertEqual(controller.state, .waitingForChange)
            XCTAssertEqual(model.requests.count, 2)
            XCTAssertEqual(model.requests.last?.question, "Find how much RAM this laptop has")
            XCTAssertEqual(model.requests.last?.scene.activeApplication, about.activeApplication)
            XCTAssertTrue(model.requests.last?.guideContext?.completedSteps.isEmpty ?? (mode == .ask))
            XCTAssertEqual(controller.selectedTarget, memoryTarget)
            XCTAssertFalse(controller.history.contains { $0.succeeded == true })
            controller.cancel()
        }
    }

    func testVisibleGuideFollowsAnotherAppOrWindowWithoutVerifyingTheOldStep() async throws {
        let safari = navigationScene()
        for destination in [
            navigationScene(bundleID: "test.about", windowID: "about", targetID: "memory"),
            navigationScene(windowID: "settings", targetID: "memory")
        ] {
            let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
            defer { events.continuation.finish() }
            var current = safari
            let model = NavigationModel()
            let controller = makeController(model: model, captureScene: { current },
                                            observationEvents: { _, _ in events.stream })
            defer { controller.cancel() }
            await controller.run(question: "Find RAM", mode: .guide, initialScene: safari)
            XCTAssertEqual(controller.state, .waitingForChange)
            current = destination
            events.continuation.yield(.fallbackTimer)
            try await waitUntil { controller.selectedTarget == self.memoryTarget && controller.state == .waitingForChange }

            XCTAssertEqual(model.requests.count, 2)
            XCTAssertEqual(model.requests.last?.guideContext?.completedSteps, [])
            XCTAssertFalse(controller.history.contains { $0.succeeded == true })
            XCTAssertNil(controller.errorMessage)
        }
    }

    func testContextRecoveryCanFollowANewApplication() async throws {
        let safari = navigationScene()
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        var current = ScreenScene(timestamp: Date(), activeApplication: safari.activeApplication,
            activeWindow: safari.activeWindow, screenshot: nil, elements: [], displays: [])
        let model = NavigationModel()
        let controller = makeController(model: model, captureScene: { current },
                                        observationEvents: { _, _ in events.stream })
        defer { controller.cancel() }
        await controller.run(question: "Find RAM", mode: .guide, initialScene: safari)
        XCTAssertEqual(controller.state, .awaitingContextRestore)
        current = navigationScene(bundleID: "test.about", windowID: "about", targetID: "memory")
        events.continuation.yield(.fallbackTimer)
        try await waitUntil { controller.state == .waitingForChange }
        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(controller.selectedTarget, memoryTarget)
    }

    func testUnchangedObservationDoesNotCallTheModelAgain() async throws {
        let scene = navigationScene()
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        var captures = 0
        let model = NavigationModel()
        let controller = makeController(model: model, captureScene: { captures += 1; return scene },
                                        observationEvents: { _, _ in events.stream })
        defer { controller.cancel() }
        await controller.run(question: "Find RAM", mode: .guide, initialScene: scene)
        let previous = captures
        events.continuation.yield(.fallbackTimer)
        try await waitUntil { captures > previous }
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(controller.state, .waitingForChange)
    }

    func testCaptureFailureDuringObservedAppChangeDoesNotLeaveTheGuideThinking() async throws {
        let safari = navigationScene()
        let about = navigationScene(bundleID: "test.about", windowID: "about", targetID: "memory")
        let events = AsyncStream<AccessibilityChangeEvent>.makeStream()
        defer { events.continuation.finish() }
        var captures = 0
        let model = NavigationModel()
        let controller = makeController(model: model, captureScene: {
            captures += 1
            if captures == 1 { return safari }
            if captures == 2 { return about }
            throw AccessibilityCaptureError.noFrontmostApplication
        }, observationEvents: { _, _ in events.stream })
        defer { controller.cancel() }
        await controller.run(question: "Find RAM", mode: .guide, initialScene: safari)
        events.continuation.yield(.fallbackTimer)
        try await waitUntil { controller.state == .failed }
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.selectedTarget)
        XCTAssertEqual(model.requests.count, 1)
    }

    func testFollowingAnExcludedApplicationUsesTheLocalProvider() async {
        let excluded = navigationScene(bundleID: "test.excluded", windowID: "private", targetID: "memory")
        let model = NavigationModel()
        let controller = makeController(model: model, captureScene: { excluded })
        controller.privacySettings.setExcluded(true, bundleIdentifier: "test.excluded")
        await controller.run(question: "Find RAM", mode: .guide, initialScene: navigationScene())
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(controller.currentScene?.activeApplication, excluded.activeApplication)
        XCTAssertNil(controller.currentScene?.screenshot)
        XCTAssertNil(controller.outboundImagePreview)
        XCTAssertNotEqual(controller.state, .awaitingContextRestore)
        controller.cancel()
    }

    func testCancellationStopsAContextReplanBeforeFurtherReasoning() async throws {
        let about = navigationScene(bundleID: "test.about", windowID: "about", targetID: "memory")
        let model = NavigationModel()
        let controller = makeController(model: model, captureScene: { about })
        let task = Task { await controller.run(question: "Find RAM", mode: .guide, initialScene: navigationScene()) }
        try await waitUntil { controller.state == .capturingScene && model.requests.count == 1 }
        controller.cancel()
        await task.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertNil(controller.selectedTarget)
    }

    func testRepeatedContextChangesHaveABoundedReasoningBudget() async {
        let safari = navigationScene()
        let about = navigationScene(bundleID: "test.about", windowID: "about", targetID: "memory")
        var captures = 0
        let model = NavigationModel()
        let controller = makeController(model: model, captureScene: {
            captures += 1
            return captures.isMultiple(of: 2) ? safari : about
        })
        await controller.run(question: "Find RAM", mode: .guide, initialScene: safari)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(model.requests.count, 9)
        XCTAssertTrue(controller.statusMessage.contains("kept changing"))
        XCTAssertNil(controller.selectedTarget)
        controller.cancel()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the controller")
    }

    private func navigationScene(bundleID: String = "com.apple.Safari", windowID: String = "browser",
                                 targetID: String = "about-command") -> ScreenScene {
        ScreenScene(timestamp: Date(), activeApplication: .init(name: bundleID, bundleIdentifier: bundleID, processIdentifier: 123),
            activeWindow: .init(title: windowID, bounds: nil, id: windowID), screenshot: nil,
            elements: [.init(id: targetID, role: "AXMenuItem", subrole: nil, label: "About This Mac", title: nil,
                value: nil, enabled: true, focused: false, bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
                windowID: windowID)], displays: [])
    }

    private func makeController(
        model: (any InstructorModel)? = nil,
        captureScene: (@MainActor () async throws -> ScreenScene)? = nil,
        observationEvents: ((Int32, TimeInterval) -> AsyncStream<AccessibilityChangeEvent>)? = nil,
        captureSnapshot: (@MainActor (CGPoint?) async throws -> ScreenSnapshot)? = nil,
        analyzeVisualContext: @escaping @Sendable (ScreenSnapshot) async throws -> [VisualElementDescriptor] = {
            try await VisionSceneAnalyzer().analyze(snapshot: $0)
        },
        hasScreenCapturePermission: @escaping () -> Bool = { false }
    ) -> BeaconController {
        let suite = "BeaconControllerLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let controller = BeaconController(
            privacySettings: PrivacySettingsStore(defaults: defaults),
            modelSettings: ModelConfigurationStore(
                defaults: defaults,
                apiKeyStorage: UnusedAPIKeyStorage()
            ),
            captureScene: captureScene,
            model: model,
            observationEvents: observationEvents ?? { _, _ in AsyncStream { _ in } },
            captureSnapshot: captureSnapshot,
            analyzeVisualContext: analyzeVisualContext,
            hasScreenCapturePermission: hasScreenCapturePermission,
            presentsUserInterface: false
        )
        addTeardownBlock { @MainActor in controller.cancel() }
        return controller
    }

    private func fixture() -> ScreenScene {
        ScreenScene(timestamp: Date(), activeApplication: .init(
            name: "Fixture", bundleIdentifier: "test.fixture", processIdentifier: 123
        ), activeWindow: nil, screenshot: nil, elements: [], displays: [])
    }

    private func largeInspectorScene(targetLabel: String? = nil) -> ScreenScene {
        let elements = (0..<70).map { index in
            UIElementDescriptor(
                id: String(format: "element-%03d", index),
                role: "AXButton",
                subrole: nil,
                label: index == 69 ? targetLabel ?? "Control 069" : String(format: "Control %03d", index),
                title: nil,
                value: nil,
                enabled: true,
                focused: false,
                bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
            )
        }
        return ScreenScene(
            timestamp: Date(),
            activeApplication: fixture().activeApplication,
            activeWindow: nil,
            screenshot: nil,
            elements: elements,
            displays: []
        )
    }

    private func inspectorContexts(
        question: String,
        mode: InteractionMode,
        scene: ScreenScene
    ) -> (provider: String, local: String) {
        var request = InstructorRequest(question: question, scene: scene, mode: mode)
        if mode == .guide {
            request.guideContext = GuideContext(
                stepNumber: 1,
                maximumSteps: 8,
                completedSteps: []
            )
        }
        request.setOfMarks = SetOfMarksBuilder().build(scene: scene, query: question)
        return (
            ModelContextBuilder(maximumElements: 100, maximumCharacters: 12_000)
                .build(for: request).userPrompt,
            ModelContextBuilder().build(for: request).userPrompt
        )
    }
}

private final class NavigationModel: InstructorModel {
    let id = "Fixture navigation"
    let capabilities: ModelCapabilities = [.local, .text]
    var requests: [InstructorRequest] = []

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        requests.append(request)
        return InstructorResponse(message: "Open the highlighted control",
            action: .init(type: .pointToElement, targetElementId: request.scene.elements.first?.id,
                          targetBounds: nil, overlay: .spotlight),
            expectedOutcome: .init(type: .elementAppears, description: "The expected result appears",
                                   element: .init(labels: ["Expected result"], role: "AXButton")),
            taskComplete: false)
    }
}

private struct FailingModel: InstructorModel {
    let id = "OpenAI"
    let capabilities: ModelCapabilities = [.text]

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private struct DelayedModel: InstructorModel {
    let id = "Fixture"
    let capabilities: ModelCapabilities = [.local, .text]
    let gate: ResponseGate

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        if request.question == "New question" {
            return InstructorResponse(message: "New answer", action: nil, expectedOutcome: nil)
        }
        return await gate.response()
    }
}

/// Intentionally ignores cancellation to reproduce platform/model work finishing late.
private actor ResponseGate {
    private var continuation: CheckedContinuation<InstructorResponse, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func response() async -> InstructorResponse {
        await withCheckedContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }

    func finish() {
        continuation?.resume(returning: InstructorResponse(message: "Late answer", action: nil, expectedOutcome: nil))
        continuation = nil
    }
}

private struct FixedModel: InstructorModel {
    let id: String
    let capabilities: ModelCapabilities = [.local, .text]
    let response: InstructorResponse

    init(id: String = "Fixture", response: InstructorResponse) {
        self.id = id
        self.response = response
    }

    func reason(request: InstructorRequest) async throws -> InstructorResponse { response }
}

private final class CountingGuideModel: InstructorModel {
    let id = "Fixture"
    let capabilities: ModelCapabilities = [.local, .text]
    var requests: [InstructorRequest] = []
    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        requests.append(request)
        return InstructorResponse(message: "Step \(requests.count)",
            action: .init(type: .pointToElement, targetElementId: "target", targetBounds: nil, overlay: .spotlight),
            expectedOutcome: .init(type: .visualChange, description: "Check the requested result"), taskComplete: false)
    }
}

private final class FinalGuideModel: InstructorModel {
    let id = "Fixture final guide"
    let capabilities: ModelCapabilities = [.local, .text]
    var requests: [InstructorRequest] = []
    let expectedOutcome: ExpectedOutcome?

    init(expectedOutcome: ExpectedOutcome? = nil) {
        self.expectedOutcome = expectedOutcome
    }

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        requests.append(request)
        return InstructorResponse(
            message: "Choose Finish.",
            action: .init(
                type: .pointToElement,
                targetElementId: "target",
                targetBounds: nil,
                overlay: .spotlight
            ),
            expectedOutcome: expectedOutcome,
            taskComplete: false,
            completesTaskAfterSuccess: true
        )
    }
}

private final class ProfileNavigationModel: InstructorModel {
    let id = "Fixture profile navigation"
    let capabilities: ModelCapabilities = [.local, .text]
    var requests: [InstructorRequest] = []

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        requests.append(request)
        let firstStep = request.guideContext?.completedSteps.isEmpty != false
        let targetID = firstStep ? "profile" : "manage-account"
        return InstructorResponse(
            message: firstStep
                ? "Open your account menu."
                : "Choose Manage your Google Account.",
            action: .init(
                type: .pointToElement,
                targetElementId: targetID,
                targetBounds: nil,
                overlay: .spotlight
            ),
            expectedOutcome: .init(
                type: .visualChange,
                description: "The next account screen should appear."
            ),
            taskComplete: false,
            // Deliberately wrong on the first navigation click: the controller must use
            // observed interface evidence and continue instead of stopping early.
            completesTaskAfterSuccess: firstStep
        )
    }
}

private final class VSCodeThemeNavigationModel: InstructorModel {
    let id = "Fixture VSCode theme navigation"
    let capabilities: ModelCapabilities = [.local, .text]
    var requests: [InstructorRequest] = []

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        requests.append(request)
        let firstStep = request.guideContext?.completedSteps.isEmpty != false
        return InstructorResponse(
            message: firstStep ? "Open the Code menu." : "Open Settings.",
            action: .init(
                type: .pointToElement,
                targetElementId: firstStep ? "code-menu" : "settings-menu",
                targetBounds: nil,
                overlay: .spotlight
            ),
            expectedOutcome: .init(
                type: .elementAppears,
                description: firstStep
                    ? "The Settings menu item should appear."
                    : "Theme choices should appear.",
                element: .init(
                    labels: [firstStep ? "Settings" : "Theme"],
                    role: "AXMenuItem"
                )
            ),
            taskComplete: false
        )
    }
}

/// AppKit posts screen-parameter changes for any visibleFrame change, including the Dock
/// auto-hiding. Only a real geometry change may cancel the user's request.
@MainActor
final class DisplayParameterChangeTests: XCTestCase {
    private func displays(_ descriptors: [DisplayDescriptor]) -> [DisplayDescriptor] { descriptors }

    private let primary = DisplayDescriptor(
        id: 1, bounds: .init(x: 0, y: 0, width: 1, height: 1), scaleFactor: 2,
        logicalSize: CGSize(width: 1440, height: 900)
    )
    private let secondary = DisplayDescriptor(
        id: 2, bounds: .init(x: 0, y: 0, width: 0.5, height: 1), scaleFactor: 1,
        logicalSize: CGSize(width: 1920, height: 1080)
    )

    func testUnchangedDisplaysLeaveAnActiveRequestRunning() async throws {
        let reported = Reported(displays: [primary])
        let controller = makeController(currentDisplays: { reported.value })
        await controller.run(question: "Where is Print?", mode: .ask, initialScene: fixture())
        let statusBefore = controller.statusMessage

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(controller.statusMessage, statusBefore)
        XCTAssertNotEqual(
            controller.statusMessage,
            SceneFreshnessIssue.displaysChanged.recoveryMessage,
            "A Dock or menu bar change must not read as a display layout change"
        )
        XCTAssertNotNil(controller.currentResponse)
    }

    func testAnAddedDisplayCancelsTheRequest() async throws {
        let reported = Reported(displays: [primary])
        let controller = makeController(currentDisplays: { reported.value })
        await controller.run(question: "Where is Print?", mode: .ask, initialScene: fixture())

        reported.value = [primary, secondary]
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(controller.statusMessage, SceneFreshnessIssue.displaysChanged.recoveryMessage)
        XCTAssertEqual(controller.state, .idle)
    }

    func testAScaleOnlyChangeIsStillDetected() async throws {
        let rescaled = DisplayDescriptor(
            id: 1, bounds: primary.bounds, scaleFactor: 1, logicalSize: primary.logicalSize
        )
        let reported = Reported(displays: [primary])
        let controller = makeController(currentDisplays: { reported.value })
        await controller.run(question: "Where is Print?", mode: .ask, initialScene: fixture())

        reported.value = [rescaled]
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(controller.statusMessage, SceneFreshnessIssue.displaysChanged.recoveryMessage)
    }

    private final class Reported: @unchecked Sendable {
        var value: [DisplayDescriptor]
        init(displays: [DisplayDescriptor]) { value = displays }
    }

    private func makeController(
        currentDisplays: @escaping () -> [DisplayDescriptor]
    ) -> BeaconController {
        let suite = "DisplayParameterChangeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let controller = BeaconController(
            privacySettings: PrivacySettingsStore(defaults: defaults),
            modelSettings: ModelConfigurationStore(
                defaults: defaults,
                apiKeyStorage: UnusedAPIKeyStorage()
            ),
            captureScene: { self.fixture() },
            model: AnswerModel(),
            observationEvents: { _, _ in AsyncStream { _ in } },
            hasScreenCapturePermission: { false },
            currentDisplays: currentDisplays,
            presentsUserInterface: false
        )
        addTeardownBlock { @MainActor in controller.cancel() }
        return controller
    }

    private func fixture() -> ScreenScene {
        ScreenScene(timestamp: Date(), activeApplication: .init(
            name: "Fixture", bundleIdentifier: "test.fixture", processIdentifier: 321
        ), activeWindow: nil, screenshot: nil, elements: [], displays: [])
    }
}

private struct AnswerModel: InstructorModel {
    let id = "Fixture answer"
    let capabilities: ModelCapabilities = [.local, .text]

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        InstructorResponse(message: "Print lives in the File menu", action: nil, expectedOutcome: nil)
    }
}

/// Controller tests must never touch the real login Keychain: a prompt there would hang
/// the suite and a stored key would leak between runs.
private struct UnusedAPIKeyStorage: APIKeyStorage {
    func read() -> String? { nil }
    func write(_ value: String) throws {}
    func delete() throws {}
}

/// The exclusion invariant is release-blocking: an excluded application must never
/// produce a screenshot. These tests grant capture permission and inject a snapshot
/// source, so the assertions depend on the exclusion check rather than on a stub that
/// makes every screenshot path unreachable.
@MainActor
final class ExcludedApplicationCaptureTests: XCTestCase {
    func testExcludedApplicationNeverInvokesScreenCapture() async {
        let recorder = CaptureRecorder()
        let controller = makeController(recorder: recorder, excluding: ["com.example.private"])

        await controller.run(
            question: "Where is the send button?",
            mode: .ask,
            initialScene: scene(bundleID: "com.example.private")
        )

        XCTAssertEqual(recorder.callCount, 0, "An excluded application must not be captured")
        XCTAssertNil(controller.currentScene?.screenshot)
        XCTAssertNil(controller.outboundImagePreview)
        XCTAssertNotNil(controller.currentResponse, "The local provider still answers")
    }

    func testNonExcludedApplicationIsCapturedLocally() async {
        let recorder = CaptureRecorder()
        let controller = makeController(recorder: recorder, excluding: [])

        await controller.run(
            question: "What is on screen?",
            mode: .ask,
            initialScene: scene(bundleID: "com.example.public")
        )

        XCTAssertGreaterThan(recorder.callCount, 0)
        XCTAssertNotNil(controller.currentScene?.screenshot)
        XCTAssertNil(
            controller.outboundImagePreview,
            "Without cloud vision consent no image is eligible to leave the Mac"
        )
    }

    private func makeController(
        recorder: CaptureRecorder,
        excluding excluded: Set<String>
    ) -> BeaconController {
        let suite = "ExcludedApplicationCaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let privacy = PrivacySettingsStore(defaults: defaults)
        for bundleID in excluded { privacy.setExcluded(true, bundleIdentifier: bundleID) }
        let controller = BeaconController(
            privacySettings: privacy,
            modelSettings: ModelConfigurationStore(
                defaults: defaults,
                apiKeyStorage: UnusedAPIKeyStorage()
            ),
            captureScene: { self.scene(bundleID: "com.example.public") },
            model: ExplainingModel(),
            observationEvents: { _, _ in AsyncStream { _ in } },
            captureSnapshot: { _ in recorder.snapshot() },
            hasScreenCapturePermission: { true },
            currentDisplays: { [] },
            presentsUserInterface: false
        )
        addTeardownBlock { @MainActor in controller.cancel() }
        return controller
    }

    private func scene(bundleID: String) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: bundleID, bundleIdentifier: bundleID, processIdentifier: 44),
            activeWindow: .init(title: "Main", bounds: nil, id: "w1"),
            screenshot: nil,
            elements: [],
            displays: []
        )
    }
}

private final class CaptureRecorder: @unchecked Sendable {
    private(set) var callCount = 0

    func snapshot() -> ScreenSnapshot {
        callCount += 1
        let context = CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return ScreenSnapshot(
            capturedAt: Date(), displayID: 1, pixelWidth: 20, pixelHeight: 20,
            displayBounds: .init(x: 0, y: 0, width: 1, height: 1),
            pngData: data as Data, redactionCount: 0
        )
    }
}

private struct ExplainingModel: InstructorModel {
    let id = "Fixture explain"
    let capabilities: ModelCapabilities = [.local, .text]

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        InstructorResponse(message: "This is the compose window", action: nil, expectedOutcome: nil)
    }
}

/// The user can perform the expected step while Beacon is waiting for a lost view to come
/// back. That is a verified outcome: the guide must advance, keep observing the new step,
/// and record exactly one history row for the step that finished.
@MainActor
final class StepCompletedDuringRecoveryTests: XCTestCase {
    func testCompletingTheStepDuringRecoveryAdvancesAndKeepsObserving() async throws {
        let scenes = SceneSequence()
        let events = EventFeed()
        let controller = makeController(scenes: scenes, events: events)

        await controller.run(question: "Add a folder", mode: .guide, initialScene: scenes.presented())
        XCTAssertEqual(controller.state, .waitingForChange)
        XCTAssertEqual(controller.history.count, 1)

        // The target vanishes: Beacon stops pointing and waits for the view to return.
        scenes.stage = .targetGone
        events.send(.fallbackTimer)
        try await waitUntil { controller.state == .awaitingContextRestore }

        // The user performs the step anyway.
        scenes.stage = .outcomeVisible
        events.send(.fallbackTimer)
        try await waitUntil { controller.state == .waitingForChange && controller.history.count == 2 }

        XCTAssertEqual(
            controller.history.filter { $0.succeeded == nil }.count, 1,
            "Only the newly presented step may still be unresolved"
        )
        XCTAssertEqual(
            controller.history.filter { $0.succeeded == true }.count, 1,
            "The completed step is recorded exactly once"
        )

        // The decisive check: the step that was just presented must have a live
        // observation of its own, so completing it is verified too.
        scenes.stage = .secondOutcomeVisible
        events.send(.fallbackTimer)
        try await waitUntil {
            controller.history.filter { $0.succeeded == true }.count == 2
        }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Condition not reached within \(timeout)s")
    }

    private func makeController(scenes: SceneSequence, events: EventFeed) -> BeaconController {
        let suite = "StepCompletedDuringRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let controller = BeaconController(
            privacySettings: PrivacySettingsStore(defaults: defaults),
            modelSettings: ModelConfigurationStore(
                defaults: defaults,
                apiKeyStorage: UnusedAPIKeyStorage()
            ),
            captureScene: { scenes.current() },
            model: RecoveryGuideModel(),
            observationEvents: { _, _ in events.stream() },
            hasScreenCapturePermission: { false },
            currentDisplays: { [] },
            presentsUserInterface: false
        )
        addTeardownBlock { @MainActor in controller.cancel() }
        return controller
    }
}

/// Three stages of the same window: the step is presented, its target disappears, then the
/// expected result becomes visible.
@MainActor
private final class SceneSequence {
    enum Stage { case presented, targetGone, outcomeVisible, secondOutcomeVisible }
    var stage: Stage = .presented

    func presented() -> ScreenScene { scene(elements: [target()]) }

    func current() -> ScreenScene {
        switch stage {
        case .presented: scene(elements: [target()])
        case .targetGone: scene(elements: [filler()])
        case .outcomeVisible: scene(elements: [outcome(), nextTarget()])
        case .secondOutcomeVisible: scene(elements: [outcome(), nextTarget(), secondOutcome()])
        }
    }

    private func scene(elements: [UIElementDescriptor]) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 77),
            activeWindow: .init(title: "Documents", bounds: nil, id: "w1"),
            screenshot: nil,
            elements: elements,
            displays: []
        )
    }

    private func target() -> UIElementDescriptor { element(id: "e_new", label: "New Folder") }
    private func filler() -> UIElementDescriptor { element(id: "e_other", label: "Unrelated") }
    private func outcome() -> UIElementDescriptor { element(id: "e_done", label: "Expected result") }
    private func nextTarget() -> UIElementDescriptor { element(id: "e_next", label: "Rename") }
    private func secondOutcome() -> UIElementDescriptor { element(id: "e_done2", label: "Second result") }

    private func element(id: String, label: String) -> UIElementDescriptor {
        UIElementDescriptor(
            id: id, role: "AXButton", subrole: nil, label: label, title: nil, value: nil,
            enabled: true, focused: false,
            bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.05), windowID: "w1"
        )
    }
}

private final class EventFeed: @unchecked Sendable {
    private var continuation: AsyncStream<AccessibilityChangeEvent>.Continuation?

    func stream() -> AsyncStream<AccessibilityChangeEvent> {
        AsyncStream { continuation in self.continuation = continuation }
    }

    func send(_ event: AccessibilityChangeEvent) {
        continuation?.yield(event)
    }
}

/// Always points at the first control it can see and expects the "Expected result" button.
private struct RecoveryGuideModel: InstructorModel {
    let id = "Fixture recovery guide"
    let capabilities: ModelCapabilities = [.local, .text]

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        // Each step expects a different control, so a later step cannot be satisfied by
        // evidence that was already on screen when it was presented.
        let expected = (request.guideContext?.completedSteps.count ?? 0) == 0
            ? "Expected result" : "Second result"
        return InstructorResponse(
            message: "Use the highlighted control",
            action: .init(
                type: .pointToElement,
                targetElementId: request.scene.elements.first?.id,
                targetBounds: nil,
                overlay: .spotlight
            ),
            expectedOutcome: .init(
                type: .elementAppears,
                description: "\(expected) appears",
                element: .init(labels: [expected], role: "AXButton")
            ),
            taskComplete: false
        )
    }
}
