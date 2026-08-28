import AppKit
import Combine
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct GuideHistoryItem: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let question: String
    let answer: String
    let applicationName: String
    let succeeded: Bool?
}

@MainActor
final class BeaconController: ObservableObject {
    @Published private(set) var state: InstructorState = .idle
    @Published private(set) var currentScene: ScreenScene?
    @Published private(set) var currentResponse: InstructorResponse?
    @Published private(set) var currentQuestion: String?
    @Published private(set) var selectedTarget: GroundedTarget?
    @Published private(set) var groundingStrategy = "—"
    @Published private(set) var groundingConfidence: Double?
    @Published private(set) var rawModelResponse = ""
    @Published private(set) var modelContextPreview = ""
    @Published private(set) var setOfMarksPreview: MarkedScreenScene?
    @Published private(set) var outboundImagePreview: ScreenSnapshot?
    @Published private(set) var requestModeClassification: RequestModeClassification?
    @Published private(set) var history: [GuideHistoryItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage = "Ready — press Option + Space"
    @Published var screenAccessPaused = false

    var privacySettings = PrivacySettingsStore()
    var modelSettings = ModelConfigurationStore()

    private let accessibility = AccessibilityService()
    private let screenCapture = ScreenCaptureService()
    private let redactor = RedactionService()
    private let visionAnalyzer = VisionSceneAnalyzer()
    private let sensitiveTextDetector = SensitiveTextDetector()
    private let setOfMarksBuilder = SetOfMarksBuilder()
    private let setOfMarksRenderer = SetOfMarksRenderer()
    private let accessibilityChangeObserver = AccessibilityChangeObserver()
    private let guidePolicyRegistry = ApplicationGuidePolicyRegistry()
    private let grounder: any GroundingStrategy = HybridGrounder()
    private let shortcut = GlobalShortcutMonitor()
    private let requestModeClassifier = RequestModeClassifier()
    private let prompt = FloatingPromptController()
    private let overlay = OverlayController()
    private var machine = InstructorStateMachine()
    private var preparedScene: ScreenScene?
    private var currentSetOfMarks: [SetOfMark] = []
    private var observationTask: Task<Void, Never>?
    private var observationID: UUID?
    private var debugObservationTask: Task<Void, Never>?
    private var activeGuide: ActiveGuide?
    private var settingsCancellables = Set<AnyCancellable>()
    private var lastExternalApplication: NSRunningApplication?
    private var started = false

    var isObserving: Bool { [.capturingScene, .understanding, .grounding, .waitingForChange, .verifying].contains(state) }

    init() {
        privacySettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &settingsCancellables)
        privacySettings.$cloudVisionEnabled
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in self?.outboundImagePreview = nil }
            .store(in: &settingsCancellables)
        modelSettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &settingsCancellables)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = frontmost
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sink { [weak self] application in self?.lastExternalApplication = application }
            .store(in: &settingsCancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        let registered = shortcut.registerOptionSpace { [weak self] in self?.showPrompt() }
        if !registered { statusMessage = "Option + Space is already used by another app" }
        overlay.onDismiss = { [weak self] in self?.cancel() }
    }

    func showPrompt() {
        guard !screenAccessPaused else {
            statusMessage = "Screen access is paused"
            return
        }
        errorMessage = nil
        do {
            preparedScene = try captureTargetScene()
        } catch {
            preparedScene = nil
            errorMessage = error.localizedDescription
        }
        prompt.show(
            onSubmit: { [weak self] question in
                guard let self else { return }
                let classification = self.requestModeClassifier.classification(
                    for: question,
                    scene: self.preparedScene
                )
                self.requestModeClassification = classification
                Task { await self.run(question: question, mode: classification.mode) }
            },
            onCancel: { [weak self] in self?.cancel() }
        )
    }

    func run(question: String, mode: InteractionMode) async {
        cancel(resetMessage: false)
        currentQuestion = question
        errorMessage = nil
        outboundImagePreview = nil
        activeGuide = mode == .guide ? ActiveGuide(question: question) : nil
        do {
            try transition(.questionReceived)
            statusMessage = "Reading the current interface…"
            var scene = try preparedScene ?? captureTargetScene()
            preparedScene = nil

            if privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier) {
                statusMessage = "\(scene.activeApplication.name) is excluded; no screenshot was captured"
            } else if CGPreflightScreenCaptureAccess() {
                do {
                    let point = scene.activeWindow?.bounds
                        .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
                    scene = try await addingVisualContext(to: scene, point: point)
                } catch {
                    statusMessage = "Continuing without a screenshot: \(error.localizedDescription)"
                }
            }
            currentScene = scene
            try transition(.sceneCaptured)
            try await generateAndPresent(question: question, mode: mode, scene: scene)
        } catch {
            fail(with: error)
        }
    }

    func refreshInspector() async {
        do {
            var scene = try captureTargetScene()
            if !privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier),
               CGPreflightScreenCaptureAccess() {
                scene = try await addingVisualContext(to: scene, point: nil)
            }
            currentScene = scene
            currentSetOfMarks = setOfMarksBuilder.build(scene: scene, query: currentQuestion)
            setOfMarksPreview = try? setOfMarksRenderer.render(scene: scene, marks: currentSetOfMarks)
            statusMessage = "Inspector refreshed: \(scene.elements.count) AX + \(scene.visualElements.count) visual elements"
        } catch { errorMessage = error.localizedDescription }
    }

    func rebuildSetOfMarksPreview() {
        guard let scene = currentScene else { return }
        do {
            currentSetOfMarks = setOfMarksBuilder.build(scene: scene, query: currentQuestion)
            setOfMarksPreview = try setOfMarksRenderer.render(scene: scene, marks: currentSetOfMarks)
            statusMessage = "Set of Marks ready: \(setOfMarksPreview?.marks.count ?? 0) candidates"
        } catch { errorMessage = error.localizedDescription }
    }

    func showAllElementsOverlay() {
        guard let elements = currentScene?.elements, !elements.isEmpty else { return }
        overlay.showDebugElements(elements)
        debugObservationTask?.cancel()
        debugObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                guard let scene = try? self.captureTargetScene() else { continue }
                self.currentScene = scene
                self.overlay.updateDebugElements(scene.elements)
            }
        }
    }

    func dismissOverlay() {
        debugObservationTask?.cancel()
        debugObservationTask = nil
        overlay.dismiss()
    }

    func cancel(resetMessage: Bool = true) {
        observationTask?.cancel()
        observationTask = nil
        observationID = nil
        accessibilityChangeObserver.stop()
        debugObservationTask?.cancel()
        debugObservationTask = nil
        overlay.dismiss()
        prompt.close()
        try? transition(.cancel)
        selectedTarget = nil
        activeGuide = nil
        if resetMessage { statusMessage = "Ready — press Option + Space" }
    }

    func requestPermission(_ permission: PermissionKind) {
        PermissionCenter().request(permission)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func selectedModel(for request: InstructorRequest) throws -> any InstructorModel {
        if privacySettings.isExcluded(bundleIdentifier: request.scene.activeApplication.bundleIdentifier) {
            return AccessibilityHeuristicProvider()
        }
        switch modelSettings.provider {
        case .accessibility:
            return AccessibilityHeuristicProvider()
        case .openAI:
            guard privacySettings.cloudProcessingEnabled else {
                return AccessibilityHeuristicProvider()
            }
            return OpenAIProvider(
                model: modelSettings.openAIModel,
                apiKey: modelSettings.apiKey,
                allowsVision: privacySettings.cloudVisionEnabled
            )
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available {
                return AppleFoundationModelProvider()
            }
            #endif
            return AccessibilityHeuristicProvider()
        }
    }

    private func captureTargetScene() throws -> ScreenScene {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = frontmost
            return try accessibility.captureScene(for: frontmost)
        }
        return try accessibility.captureScene(for: lastExternalApplication)
    }

    private func generateAndPresent(
        question: String,
        mode: InteractionMode,
        scene: ScreenScene
    ) async throws {
        var request = InstructorRequest(question: question, scene: scene, mode: mode)
        request.guideContext = activeGuide?.context
        request.setOfMarks = setOfMarksBuilder.build(scene: scene, query: question)
        currentSetOfMarks = request.setOfMarks
        let model = try selectedModel(for: request)
        if model.capabilities.contains(.vision),
           privacySettings.cloudVisionEnabled,
           scene.screenshot != nil {
            let markedScene = try setOfMarksRenderer.render(scene: scene, marks: request.setOfMarks)
            request.visualContextImage = markedScene.snapshot
            setOfMarksPreview = markedScene
            outboundImagePreview = markedScene.snapshot
        } else {
            outboundImagePreview = nil
        }
        let contextBuilder = model.id == "OpenAI"
            ? ModelContextBuilder(maximumElements: 100, maximumCharacters: 12_000)
            : ModelContextBuilder()
        let modelContext = contextBuilder.build(for: request)
        modelContextPreview = "Question: \(question)\n\(modelContext.text)"
        let step = activeGuide.map { " step \($0.completedSteps.count + 1)" } ?? ""
        statusMessage = "Reasoning with \(model.id) for\(step)…"
        let modelResponse = try await model.reason(request: request)
        let response: InstructorResponse
        if mode == .guide, modelResponse.action?.type == .pointToElement,
           modelResponse.expectedOutcome == nil {
            response = InstructorResponse(
                message: modelResponse.message,
                action: modelResponse.action,
                expectedOutcome: ExpectedOutcome(
                    type: .visualChange,
                    description: "The interface should change after this step."
                ),
                taskComplete: modelResponse.taskComplete
            )
        } else {
            response = modelResponse
        }
        _ = try response.action?.validated(in: scene, marks: request.setOfMarks)
        currentResponse = response
        rawModelResponse = encodeForInspection(response)
        try transition(.responseGenerated(needsTarget: response.action?.type == .pointToElement))

        if let action = response.action, action.type == .pointToElement {
            let resolver: any GroundingStrategy = action.targetMark == nil
                ? grounder
                : SetOfMarksGrounder(marks: request.setOfMarks)
            let result = try await resolver.resolve(
                intention: UIIntention(
                    question: question,
                    preferredElementID: action.targetElementId,
                    preferredBounds: action.targetBounds,
                    preferredMark: action.targetMark
                ),
                scene: scene
            )
            selectedTarget = result.target
            groundingStrategy = result.strategy
            groundingConfidence = result.confidence
            try transition(.targetGrounded)
            overlay.showInstruction(VisualInstruction(
                text: response.message,
                explanation: nil,
                target: result.target,
                overlay: action.overlay
            ))
        }

        let expectsChange = response.expectedOutcome != nil && response.action != nil
        try transition(.instructionPresented(expectsChange: expectsChange))
        appendHistory(
            question: question,
            response: response,
            scene: scene,
            succeeded: state == .completed ? true : nil
        )
        if state == .waitingForChange {
            statusMessage = "Waiting for the interface to change…"
            beginObservation(from: scene)
        } else {
            statusMessage = response.taskComplete == true ? "Task completed" : "Answered"
            activeGuide = nil
        }
    }

    private func addingVisualContext(to scene: ScreenScene, point: CGPoint?) async throws -> ScreenScene {
        let snapshot = try await screenCapture.captureDisplay(
            containing: point,
            excludingBundleIdentifiers: privacySettings.excludedBundleIdentifiers
        )
        let visualElements = try await visionAnalyzer.analyze(snapshot: snapshot)
        let sensitiveRegions = sensitiveTextDetector.redactionRegions(in: visualElements)
        let regions = redactor.automaticRegions(in: scene) + sensitiveRegions
        let safeSnapshot = try redactor.redact(snapshot: snapshot, regions: regions)
        return scene
            .replacingScreenshot(with: safeSnapshot)
            .replacingVisualElements(with: sensitiveTextDetector.removingSensitiveElements(from: visualElements))
    }

    private func beginObservation(from baseline: ScreenScene) {
        observationTask?.cancel()
        accessibilityChangeObserver.stop()
        let identifier = UUID()
        observationID = identifier
        let baselineFingerprint = SceneFingerprint(scene: baseline)
        let targetID = selectedTarget?.elementID
        let events = accessibilityChangeObserver.events(
            for: baseline.activeApplication.processIdentifier,
            fallbackInterval: 3
        )
        observationTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(30)
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self, self.observationID == identifier else { return }
                if event == .observerUnavailable { continue }
                if Date() >= deadline { break }
                if case .notification = event {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                do {
                    var newScene = try self.captureTargetScene()
                    if let targetID,
                       let element = newScene.elements.first(where: { $0.id == targetID }),
                       let bounds = element.bounds {
                        let target = GroundedTarget.accessibilityElement(elementId: targetID, bounds: bounds)
                        self.selectedTarget = target
                        self.overlay.updateTarget(target)
                    }
                    let accessibilityChanged = SceneFingerprint(scene: newScene) != baselineFingerprint
                    var visualDifference: Double?
                    if !accessibilityChanged {
                        guard let baselineSnapshot = baseline.screenshot,
                              !self.privacySettings.isExcluded(
                                bundleIdentifier: newScene.activeApplication.bundleIdentifier
                              ), CGPreflightScreenCaptureAccess() else { continue }
                        let point = baseline.activeWindow?.bounds
                            .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
                        newScene = try await self.addingVisualContext(to: newScene, point: point)
                        guard let currentSnapshot = newScene.screenshot else { continue }
                        let difference = FrameDifferenceDetector().difference(
                            between: baselineSnapshot,
                            and: currentSnapshot
                        )
                        guard difference >= FrameDifferenceDetector().meaningfulThreshold else { continue }
                        visualDifference = difference
                    }
                    self.accessibilityChangeObserver.stop()
                    try self.transition(.meaningfulChangeDetected)
                    self.currentScene = newScene
                    self.statusMessage = "Verifying the result…"
                    let verification = StepVerifier().verify(
                        expected: self.currentResponse?.expectedOutcome,
                        before: baseline,
                        after: newScene,
                        visualDifference: visualDifference
                    )
                    if !verification.succeeded {
                        let attempt = self.incrementRecoveryAttempt(noChange: false)
                        let decision = self.guidePolicyRegistry.recoveryDecision(
                            for: newScene.activeApplication.bundleIdentifier,
                            attempt: attempt,
                            noChange: false,
                            expectedDescription: self.currentResponse?.expectedOutcome?.description
                        )
                        try self.transition(.verificationFinished(success: false, hasNextStep: false))
                        if decision.action == .stop {
                            self.stopGuideAfterRecovery(message: decision.message)
                            return
                        }
                        self.statusMessage = decision.message
                        if let response = self.currentResponse, let target = self.selectedTarget {
                            self.overlay.showInstruction(VisualInstruction(
                                text: "\(response.message) Try once more.",
                                explanation: decision.message,
                                target: target,
                                overlay: response.action?.overlay ?? .spotlight
                            ))
                        }
                        try self.transition(.instructionPresented(expectsChange: true))
                        let retryScene = await self.scenePreparedForObservation(from: newScene)
                        self.beginObservation(from: retryScene)
                        return
                    }

                    self.resetRecoveryAttempts()
                    self.recordCompletedStep(from: baseline)
                    let hasNextStep = self.activeGuide.map {
                        $0.completedSteps.count < $0.maximumSteps && self.currentResponse?.taskComplete != true
                    } ?? false
                    try self.transition(.verificationFinished(success: true, hasNextStep: hasNextStep))
                    self.overlay.dismiss()
                    if let index = self.history.firstIndex(where: { $0.succeeded == nil }) {
                        self.history[index] = self.history[index].withSucceeded(true)
                    }
                    if hasNextStep {
                        await self.continueGuide(from: newScene)
                    } else {
                        self.statusMessage = self.activeGuide?.completedSteps.count == self.activeGuide?.maximumSteps
                            ? "Task paused at the 8-step safety limit"
                            : "Task completed"
                        self.activeGuide = nil
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                }
            }
            guard !Task.isCancelled, let self, self.observationID == identifier else { return }
            self.accessibilityChangeObserver.stop()
            let attempt = self.incrementRecoveryAttempt(noChange: true)
            let decision = self.guidePolicyRegistry.recoveryDecision(
                for: baseline.activeApplication.bundleIdentifier,
                attempt: attempt,
                noChange: true,
                expectedDescription: self.currentResponse?.expectedOutcome?.description
            )
            if decision.action == .retry {
                self.statusMessage = decision.message
                if let response = self.currentResponse, let target = self.selectedTarget {
                    self.overlay.showInstruction(VisualInstruction(
                        text: response.message,
                        explanation: decision.message,
                        target: target,
                        overlay: response.action?.overlay ?? .spotlight
                    ))
                }
                self.beginObservation(from: await self.scenePreparedForObservation(from: baseline))
            } else {
                self.stopGuideAfterRecovery(message: decision.message)
            }
        }
    }

    private func scenePreparedForObservation(from scene: ScreenScene) async -> ScreenScene {
        guard scene.screenshot == nil,
              !privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier),
              CGPreflightScreenCaptureAccess() else { return scene }
        let point = scene.activeWindow?.bounds
            .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
        return (try? await addingVisualContext(to: scene, point: point)) ?? scene
    }

    private func incrementRecoveryAttempt(noChange: Bool) -> Int {
        guard var guide = activeGuide else { return 1 }
        if noChange {
            guide.noChangeRetries += 1
        } else {
            guide.unexpectedChangeRetries += 1
        }
        activeGuide = guide
        return noChange ? guide.noChangeRetries : guide.unexpectedChangeRetries
    }

    private func resetRecoveryAttempts() {
        guard var guide = activeGuide else { return }
        guide.noChangeRetries = 0
        guide.unexpectedChangeRetries = 0
        activeGuide = guide
    }

    private func stopGuideAfterRecovery(message: String) {
        accessibilityChangeObserver.stop()
        observationTask?.cancel()
        observationTask = nil
        observationID = nil
        overlay.dismiss()
        try? transition(.fail)
        statusMessage = message
        activeGuide = nil
        if let index = history.firstIndex(where: { $0.succeeded == nil }) {
            history[index] = history[index].withSucceeded(false)
        }
    }

    private func continueGuide(from changedScene: ScreenScene) async {
        guard let activeGuide else { return }
        do {
            statusMessage = "Preparing the next step…"
            var scene = changedScene
            if !privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier),
               CGPreflightScreenCaptureAccess() {
                let point = scene.activeWindow?.bounds
                    .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
                scene = try await addingVisualContext(to: scene, point: point)
            }
            currentScene = scene
            try transition(.sceneCaptured)
            try await generateAndPresent(question: activeGuide.question, mode: .guide, scene: scene)
        } catch { fail(with: error) }
    }

    private func recordCompletedStep(from scene: ScreenScene) {
        guard var guide = activeGuide, let response = currentResponse else { return }
        let targetID = selectedTarget?.elementID
        let targetLabel = targetID.flatMap { id in scene.elements.first(where: { $0.id == id })?.bestLabel }
            ?? response.action?.targetBounds.flatMap { bounds in
                scene.visualElements.first(where: { $0.bounds == bounds })?.bestLabel
            }
            ?? response.action?.targetMark.flatMap { markID in
                currentSetOfMarks.first(where: { $0.id == markID })?.label
            }
        guide.completedSteps.append(CompletedGuideStep(
            number: guide.completedSteps.count + 1,
            instruction: response.message,
            targetElementID: targetID,
            targetLabel: targetLabel
        ))
        activeGuide = guide
    }

    private func transition(_ event: InstructorEvent) throws {
        state = try machine.handle(event)
    }

    private func fail(with error: Error) {
        try? transition(.fail)
        errorMessage = error.localizedDescription
        statusMessage = "Beacon couldn't complete that request"
        overlay.dismiss()
    }

    private func appendHistory(
        question: String,
        response: InstructorResponse,
        scene: ScreenScene,
        succeeded: Bool?
    ) {
        history.insert(GuideHistoryItem(
            date: Date(),
            question: question,
            answer: response.message,
            applicationName: scene.activeApplication.name,
            succeeded: succeeded
        ), at: 0)
    }

    private func encodeForInspection(_ response: InstructorResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

private struct SceneFingerprint: Equatable {
    let app: String?
    let window: String?
    let elements: [String]
    let focused: String?

    init(scene: ScreenScene) {
        app = scene.activeApplication.bundleIdentifier
        window = scene.activeWindow?.title
        elements = scene.elements.map { "\($0.id):\($0.bestLabel)" }.sorted()
        focused = scene.elements.first(where: \.focused)?.id
    }
}

private struct ActiveGuide {
    let question: String
    let maximumSteps = 8
    var completedSteps: [CompletedGuideStep] = []
    var unexpectedChangeRetries = 0
    var noChangeRetries = 0

    var context: GuideContext {
        GuideContext(
            stepNumber: completedSteps.count + 1,
            maximumSteps: maximumSteps,
            completedSteps: completedSteps
        )
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension GroundedTarget {
    var elementID: String? {
        if case let .accessibilityElement(id, _) = self { return id }
        return nil
    }
}

private extension GuideHistoryItem {
    func withSucceeded(_ succeeded: Bool) -> GuideHistoryItem {
        GuideHistoryItem(
            date: date,
            question: question,
            answer: answer,
            applicationName: applicationName,
            succeeded: succeeded
        )
    }
}
