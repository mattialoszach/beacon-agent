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
    private let sceneFreshnessValidator = SceneFreshnessValidator()
    private let grounder: any GroundingStrategy = HybridGrounder()
    private let shortcut = GlobalShortcutMonitor()
    private let requestModeClassifier = RequestModeClassifier()
    private let cursorPositionMonitor: CursorPositionMonitor
    private let prompt: FloatingPromptController
    private let overlay: OverlayController
    private var machine = InstructorStateMachine()
    private var preparedScene: ScreenScene?
    private var currentSetOfMarks: [SetOfMark] = []
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private var observationTask: Task<Void, Never>?
    private var observationID: UUID?
    private var debugObservationTask: Task<Void, Never>?
    private var activeGuide: ActiveGuide?
    private var currentMode: InteractionMode = .ask
    private var settingsCancellables = Set<AnyCancellable>()
    private var lastExternalApplication: NSRunningApplication?
    private var started = false

    var isObserving: Bool {
        [
            .capturingScene, .understanding, .grounding, .awaitingContextRestore,
            .waitingForChange, .verifying
        ].contains(state)
    }

    init() {
        let cursorPositionMonitor = CursorPositionMonitor()
        self.cursorPositionMonitor = cursorPositionMonitor
        prompt = FloatingPromptController(cursorPositionMonitor: cursorPositionMonitor)
        overlay = OverlayController(cursorPositionMonitor: cursorPositionMonitor)
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
                let identifier = UUID()
                self.requestTask?.cancel()
                self.requestID = identifier
                self.requestTask = Task { [weak self] in
                    guard let self else { return }
                    await self.run(question: question, mode: classification.mode)
                    if self.requestID == identifier {
                        self.requestTask = nil
                        self.requestID = nil
                    }
                }
            },
            onCancel: { [weak self] in self?.cancel() }
        )
    }

    func run(question: String, mode: InteractionMode) async {
        cancel(resetMessage: false, dismissesPrompt: false, cancelsRequest: false)
        currentQuestion = question
        currentMode = mode
        errorMessage = nil
        outboundImagePreview = nil
        activeGuide = mode == .guide ? ActiveGuide(question: question) : nil
        do {
            try transition(.questionReceived)
            statusMessage = "Reading the current interface…"
            prompt.updateThinking(message: statusMessage)
            var scene = try preparedScene ?? captureTargetScene()
            preparedScene = nil

            if privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier) {
                statusMessage = "\(scene.activeApplication.name) is excluded; no screenshot was captured"
            } else {
                scene = await scenePreparedForReasoning(
                    from: scene,
                    question: question,
                    mode: mode
                )
            }
            currentScene = scene
            try transition(.sceneCaptured)
            try await generateAndPresent(question: question, mode: mode, scene: scene)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
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

    func cancel(
        resetMessage: Bool = true,
        dismissesPrompt: Bool = true,
        cancelsRequest: Bool = true
    ) {
        if cancelsRequest {
            requestID = nil
            requestTask?.cancel()
            requestTask = nil
        }
        observationTask?.cancel()
        observationTask = nil
        observationID = nil
        accessibilityChangeObserver.stop()
        debugObservationTask?.cancel()
        debugObservationTask = nil
        overlay.dismiss()
        if dismissesPrompt { prompt.close() }
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
                model: modelSettings.openAIModel.rawValue,
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
        let step = activeGuide.map { " step \($0.completedSteps.count + 1)" } ?? ""
        let modelResponse: InstructorResponse
        if mode == .guide,
           let planned = ApplicationGuidePlanner(registry: guidePolicyRegistry).response(for: request) {
            outboundImagePreview = nil
            let modelContext = ModelContextBuilder().build(for: request)
            modelContextPreview = "Question: \(question)\n\(modelContext.text)"
            statusMessage = "Preparing your next step…"
            prompt.updateThinking(message: statusMessage)
            modelResponse = planned
        } else {
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
            statusMessage = "Reasoning with \(model.id) for\(step)…"
            prompt.updateThinking(message: statusMessage)
            modelResponse = try await model.reason(request: request)
        }
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

        var presentationScene = scene
        if let action = response.action, action.type == .pointToElement {
            statusMessage = "Locating the right control…"
            prompt.updateThinking(message: statusMessage)
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
            groundingStrategy = result.strategy
            groundingConfidence = result.confidence
            try transition(.targetGrounded)

            statusMessage = "Checking that the interface is still ready…"
            prompt.updateThinking(message: statusMessage)
            let latestScene = try captureTargetScene()
            switch await validatePresentation(
                source: scene,
                latest: latestScene,
                target: result.target
            ) {
            case let .valid(validatedScene, refreshedTarget):
                selectedTarget = refreshedTarget
                presentationScene = validatedScene
            case let .stale(issue, observedScene):
                if try await reconcileAlreadyCompletedStep(
                    response: response,
                    source: scene,
                    latest: observedScene,
                    target: result.target,
                    question: question,
                    mode: mode
                ) {
                    return
                }
                try beginContextRecovery(
                    issue: issue,
                    source: scene,
                    latest: observedScene,
                    target: result.target,
                    question: question,
                    mode: mode
                )
                return
            }
            overlay.showInstruction(VisualInstruction(
                text: response.message,
                explanation: nil,
                target: selectedTarget,
                overlay: action.overlay
            ))
        }

        let expectsChange = response.expectedOutcome != nil && response.action != nil
        try transition(.instructionPresented(expectsChange: expectsChange))
        prompt.close()
        appendHistory(
            question: question,
            response: response,
            scene: presentationScene,
            succeeded: state == .completed ? true : nil
        )
        if state == .waitingForChange {
            statusMessage = "Waiting for the interface to change…"
            beginObservation(from: presentationScene)
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

    private func scenePreparedForReasoning(
        from scene: ScreenScene,
        question: String,
        mode: InteractionMode
    ) async -> ScreenScene {
        guard shouldAddVisualContext(to: scene, question: question, mode: mode) else { return scene }
        do {
            let point = scene.activeWindow?.bounds
                .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
            let visualScene = try await addingVisualContext(to: scene, point: point)
            let latest = try captureTargetScene()
            guard sceneFreshnessValidator.contextIssue(source: scene, latest: latest) == nil else {
                statusMessage = "The interface changed while I was reading it. Using the latest view…"
                prompt.updateThinking(message: statusMessage)
                return latest
            }
            return latest
                .replacingScreenshot(with: visualScene.screenshot)
                .replacingVisualElements(with: visualScene.visualElements)
        } catch {
            statusMessage = "Continuing with Accessibility: \(error.localizedDescription)"
            prompt.updateThinking(message: statusMessage)
            return scene
        }
    }

    private func shouldAddVisualContext(
        to scene: ScreenScene,
        question: String,
        mode: InteractionMode
    ) -> Bool {
        guard CGPreflightScreenCaptureAccess(),
              !privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier) else {
            return false
        }
        var request = InstructorRequest(question: question, scene: scene, mode: mode)
        request.guideContext = activeGuide?.context
        request.setOfMarks = setOfMarksBuilder.build(scene: scene, query: question)
        if mode == .guide,
           ApplicationGuidePlanner(registry: guidePolicyRegistry).response(for: request) != nil {
            return false
        }
        guard let model = try? selectedModel(for: request) else { return false }
        return model.capabilities.contains(.local)
            || (model.capabilities.contains(.vision) && privacySettings.cloudVisionEnabled)
    }

    private func validatePresentation(
        source: ScreenScene,
        latest: ScreenScene,
        target: GroundedTarget
    ) async -> PresentationValidation {
        let refreshedTarget: GroundedTarget
        switch sceneFreshnessValidator.validate(source: source, latest: latest, target: target) {
        case let .valid(target):
            refreshedTarget = target
        case let .stale(issue):
            return .stale(issue: issue, latest: latest)
        }

        switch refreshedTarget {
        case .accessibilityElement:
            return .valid(
                scene: latest
                    .replacingScreenshot(with: source.screenshot)
                    .replacingVisualElements(with: source.visualElements),
                target: refreshedTarget
            )
        case .visualRegion, .point:
            guard let sourceSnapshot = source.screenshot,
                  CGPreflightScreenCaptureAccess(),
                  !privacySettings.isExcluded(bundleIdentifier: latest.activeApplication.bundleIdentifier) else {
                return .stale(
                    issue: .visualContextUnavailable(application: source.activeApplication.name),
                    latest: latest
                )
            }
            do {
                let point = latest.activeWindow?.bounds
                    .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
                let visualScene = try await addingVisualContext(to: latest, point: point)
                let finalScene = try captureTargetScene()
                if case let .stale(issue) = sceneFreshnessValidator.validate(
                    source: source,
                    latest: finalScene,
                    target: refreshedTarget
                ) {
                    return .stale(issue: issue, latest: finalScene)
                }
                guard let currentSnapshot = visualScene.screenshot,
                      !FrameDifferenceDetector().isMeaningfulChange(
                        between: sourceSnapshot,
                        and: currentSnapshot
                      ) else {
                    return .stale(
                        issue: .visualContextUnavailable(application: source.activeApplication.name),
                        latest: finalScene
                    )
                }
                return .valid(
                    scene: finalScene
                        .replacingScreenshot(with: visualScene.screenshot)
                        .replacingVisualElements(with: visualScene.visualElements),
                    target: refreshedTarget
                )
            } catch {
                return .stale(
                    issue: .visualContextUnavailable(application: source.activeApplication.name),
                    latest: latest
                )
            }
        }
    }

    private func reconcileAlreadyCompletedStep(
        response: InstructorResponse,
        source: ScreenScene,
        latest: ScreenScene,
        target: GroundedTarget,
        question: String,
        mode: InteractionMode
    ) async throws -> Bool {
        guard mode == .guide,
              activeGuide != nil,
              response.expectedOutcome != nil,
              StepVerifier().verify(
                expected: response.expectedOutcome,
                before: source,
                after: latest
              ).succeeded else {
            return false
        }

        selectedTarget = target
        try transition(.instructionPresented(expectsChange: true))
        try transition(.meaningfulChangeDetected)
        currentScene = latest
        recordCompletedStep(from: source)
        let hasNextStep = activeGuide.map {
            $0.completedSteps.count < $0.maximumSteps && response.taskComplete != true
        } ?? false
        try transition(.verificationFinished(success: true, hasNextStep: hasNextStep))
        appendHistory(question: question, response: response, scene: latest, succeeded: true)
        statusMessage = "You already completed that step — updating the guide…"
        prompt.updateThinking(message: statusMessage)
        if hasNextStep {
            await continueGuide(from: latest)
        } else {
            prompt.close()
            activeGuide = nil
            statusMessage = "Task completed"
        }
        return true
    }

    private func beginContextRecovery(
        issue: SceneFreshnessIssue,
        source: ScreenScene,
        latest: ScreenScene,
        target: GroundedTarget,
        question: String,
        mode: InteractionMode
    ) throws {
        try transition(.contextLost)
        overlay.dismiss()
        selectedTarget = nil
        currentScene = latest
        statusMessage = issue.recoveryMessage
        prompt.showWaiting(message: statusMessage) { [weak self] in self?.cancel() }

        observationTask?.cancel()
        accessibilityChangeObserver.stop()
        let identifier = UUID()
        observationID = identifier
        let events = accessibilityChangeObserver.events(
            for: source.activeApplication.processIdentifier,
            fallbackInterval: 1
        )
        observationTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(60)
            for await event in events {
                guard !Task.isCancelled, let self, self.observationID == identifier else { return }
                if Date() >= deadline { break }
                if case .notification = event {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                guard let restoredScene = try? self.captureTargetScene() else { continue }
                switch self.sceneFreshnessValidator.validate(
                    source: source,
                    latest: restoredScene,
                    target: target
                ) {
                case .valid:
                    self.accessibilityChangeObserver.stop()
                    self.observationID = nil
                    self.observationTask = nil
                    try? self.transition(.contextRestored)
                    self.statusMessage = "Thanks — checking the restored view…"
                    self.prompt.showThinking(message: self.statusMessage) { [weak self] in self?.cancel() }
                    let prepared = await self.scenePreparedForReasoning(
                        from: restoredScene,
                        question: question,
                        mode: mode
                    )
                    self.currentScene = prepared
                    do {
                        try self.transition(.sceneCaptured)
                        try await self.generateAndPresent(question: question, mode: mode, scene: prepared)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.fail(with: error)
                    }
                    return
                case let .stale(currentIssue):
                    if self.statusMessage != currentIssue.recoveryMessage {
                        self.statusMessage = currentIssue.recoveryMessage
                        self.prompt.showWaiting(message: self.statusMessage) { [weak self] in self?.cancel() }
                    }
                }
            }
            guard !Task.isCancelled, let self, self.observationID == identifier else { return }
            self.accessibilityChangeObserver.stop()
            self.observationID = nil
            self.observationTask = nil
            try? self.transition(.fail)
            self.activeGuide = nil
            self.statusMessage = "I stopped the guide because the previous view was not restored. Start again when it is ready."
            self.prompt.showWaiting(message: self.statusMessage) { [weak self] in self?.cancel() }
        }
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
                        let accessibilityScene = newScene
                        let visualScene = try await self.addingVisualContext(to: accessibilityScene, point: point)
                        let stableScene = try self.captureTargetScene()
                        guard self.sceneFreshnessValidator.contextIssue(
                            source: accessibilityScene,
                            latest: stableScene
                        ) == nil,
                        let currentSnapshot = visualScene.screenshot else { continue }
                        newScene = stableScene
                            .replacingScreenshot(with: visualScene.screenshot)
                            .replacingVisualElements(with: visualScene.visualElements)
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
                    self.overlay.dismiss()
                    self.prompt.showThinking(message: self.statusMessage) { [weak self] in
                        self?.cancel()
                    }
                    let verification = StepVerifier().verify(
                        expected: self.currentResponse?.expectedOutcome,
                        before: baseline,
                        after: newScene,
                        visualDifference: visualDifference
                    )
                    if !verification.succeeded {
                        if let target = self.selectedTarget,
                           case let .stale(issue) = self.sceneFreshnessValidator.validate(
                            source: baseline,
                            latest: newScene,
                            target: target
                        ) {
                            try self.transition(.verificationFinished(success: false, hasNextStep: false))
                            try self.beginContextRecovery(
                                issue: issue,
                                source: baseline,
                                latest: newScene,
                                target: target,
                                question: self.currentQuestion ?? self.activeGuide?.question ?? "Continue the guide",
                                mode: self.currentMode
                            )
                            return
                        }
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
                        self.prompt.close()
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
                        self.prompt.close()
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
        guard scene.screenshot == nil else { return scene }
        return await scenePreparedForReasoning(
            from: scene,
            question: currentQuestion ?? activeGuide?.question ?? "Continue the guide",
            mode: currentMode
        )
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
        prompt.close()
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
            prompt.showThinking(message: statusMessage) { [weak self] in
                self?.cancel()
            }
            let scene = await scenePreparedForReasoning(
                from: changedScene,
                question: activeGuide.question,
                mode: .guide
            )
            currentScene = scene
            try transition(.sceneCaptured)
            try await generateAndPresent(question: activeGuide.question, mode: .guide, scene: scene)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            fail(with: error)
        }
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
        prompt.close()
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

private enum PresentationValidation {
    case valid(scene: ScreenScene, target: GroundedTarget)
    case stale(issue: SceneFreshnessIssue, latest: ScreenScene)
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
