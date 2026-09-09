import AppKit
import Combine
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct GuideHistoryItem: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let question: String
    let answer: String
    let applicationName: String
    let succeeded: Bool?

    init(
        id: UUID = UUID(),
        date: Date,
        question: String,
        answer: String,
        applicationName: String,
        succeeded: Bool?
    ) {
        self.id = id
        self.date = date
        self.question = question
        self.answer = answer
        self.applicationName = applicationName
        self.succeeded = succeeded
    }
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
    @Published private(set) var confirmationMessage: String?
    @Published private(set) var statusMessage = "Ready — press Option + Space"
    @Published var screenAccessPaused = false {
        didSet {
            guard screenAccessPaused != oldValue else { return }
            if screenAccessPaused {
                cancel()
                clearVisualContext()
                statusMessage = "Screen access is paused"
            } else {
                statusMessage = "Ready — press Option + Space"
            }
        }
    }

    var privacySettings: PrivacySettingsStore
    var modelSettings: ModelConfigurationStore

    private let accessibility = AccessibilityService()
    private let screenCapture = ScreenCaptureService()
    private let analyzeVisualContext: @Sendable (ScreenSnapshot) async throws -> [VisualElementDescriptor]
    private let setOfMarksBuilder = SetOfMarksBuilder()
    private let accessibilityChangeObserver = AccessibilityChangeObserver()
    private let guidePolicyRegistry = ApplicationGuidePolicyRegistry()
    private let sceneFreshnessValidator = SceneFreshnessValidator()
    private let grounder: any GroundingStrategy = HybridGrounder()
    private let shortcut = GlobalShortcutMonitor()
    private let cursorPositionMonitor: CursorPositionMonitor
    private let prompt: FloatingPromptController
    private let overlay: OverlayController
    private var machine = InstructorStateMachine()
    private var preparedSceneTask: Task<ScreenScene, Error>?
    private var currentSetOfMarks: [SetOfMark] = []
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private var observationTask: Task<Void, Never>?
    private var observationID: UUID?
    private var debugObservationTask: Task<Void, Never>?
    private var activeGuide: ActiveGuide?
    private var confirmationBaseline: ScreenScene?
    private var pendingHistoryItemID: UUID?
    private var frameComparisonSamples = FrameComparisonSampleStore()
    private var currentMode: InteractionMode = .ask
    private var automaticallyFollowsCurrentStep = false
    private var settingsCancellables = Set<AnyCancellable>()
    private var lastExternalApplication: NSRunningApplication?
    private var processingActivity: NSObjectProtocol?
    private var started = false
    private var operationID = UUID()
    private var noChangeRetries = 0
    private var unexpectedChangeRetries = 0
    private var contextReplans = 0
    private let maximumContextReplans = 8
    private let captureSceneOverride: (@MainActor () async throws -> ScreenScene)?
    private let observationEventsOverride: ((Int32, TimeInterval) -> AsyncStream<AccessibilityChangeEvent>)?
    private let modelOverride: (any InstructorModel)?
    private let captureSnapshotOverride: (@MainActor (CGPoint?) async throws -> ScreenSnapshot)?
    private let hasScreenCapturePermission: () -> Bool
    private let currentDisplays: () -> [DisplayDescriptor]
    private var knownDisplays: [DisplayDescriptor] = []
    /// Minimum interval between observation captures. Applications that emit layout
    /// notifications many times per second would otherwise keep Beacon capturing
    /// back-to-back for the whole observation window.
    private static let minimumObservationInterval: TimeInterval = 0.45
    private static let observationFallbackInterval: TimeInterval = 1
    private static let observationTimeout: TimeInterval = 10

    var isObserving: Bool {
        [
            .capturingScene, .understanding, .grounding, .awaitingContextRestore,
            .waitingForChange, .verifying
        ].contains(state) || (state == .awaitingConfirmation && observationID != nil)
    }

    init(
        privacySettings: PrivacySettingsStore? = nil,
        modelSettings: ModelConfigurationStore? = nil,
        captureScene: (@MainActor () async throws -> ScreenScene)? = nil,
        model: (any InstructorModel)? = nil,
        observationEvents: ((Int32, TimeInterval) -> AsyncStream<AccessibilityChangeEvent>)? = nil,
        captureSnapshot: (@MainActor (CGPoint?) async throws -> ScreenSnapshot)? = nil,
        analyzeVisualContext: @escaping @Sendable (ScreenSnapshot) async throws -> [VisualElementDescriptor] = {
            try await VisionSceneAnalyzer().analyze(snapshot: $0)
        },
        hasScreenCapturePermission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        currentDisplays: @escaping () -> [DisplayDescriptor] = { BeaconController.activeDisplays() },
        presentsUserInterface: Bool = true
    ) {
        let privacySettings = privacySettings ?? PrivacySettingsStore()
        let modelSettings = modelSettings ?? ModelConfigurationStore()
        self.privacySettings = privacySettings
        self.modelSettings = modelSettings
        captureSceneOverride = captureScene
        observationEventsOverride = observationEvents
        modelOverride = model
        captureSnapshotOverride = captureSnapshot
        self.analyzeVisualContext = analyzeVisualContext
        self.hasScreenCapturePermission = hasScreenCapturePermission
        self.currentDisplays = currentDisplays
        knownDisplays = currentDisplays()
        let cursorPositionMonitor = CursorPositionMonitor()
        self.cursorPositionMonitor = cursorPositionMonitor
        prompt = FloatingPromptController(
            cursorPositionMonitor: cursorPositionMonitor,
            isEnabled: presentsUserInterface
        )
        overlay = OverlayController(
            cursorPositionMonitor: cursorPositionMonitor,
            isEnabled: presentsUserInterface
        )
        privacySettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &settingsCancellables)
        privacySettings.$cloudVisionEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.privacyPolicyChanged() }
            .store(in: &settingsCancellables)
        privacySettings.$cloudProcessingEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.privacyPolicyChanged() }
            .store(in: &settingsCancellables)
        privacySettings.$excludedBundleIdentifiers
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.privacyPolicyChanged() }
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
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.screenParametersChanged() }
            .store(in: &settingsCancellables)
    }

    nonisolated static func activeDisplays() -> [DisplayDescriptor] {
        let geometry = DisplayGeometryProvider()
        return geometry.descriptors(using: geometry.currentMapper()).sorted { $0.id < $1.id }
    }

    /// AppKit posts screen-parameter changes for any `visibleFrame` change, including the
    /// Dock auto-hiding and the menu bar hiding for a full-screen window. Only a real
    /// change of display geometry may cancel the user's request.
    private func screenParametersChanged() {
        let displays = currentDisplays()
        guard displays != knownDisplays else { return }
        knownDisplays = displays
        displayConfigurationChanged()
    }

    func start() {
        guard !started else { return }
        started = true
        let registered = shortcut.registerOptionSpace { [weak self] in self?.showPrompt() }
        if !registered { statusMessage = "Option + Space is already used by another app" }
        overlay.onDismiss = { [weak self] in self?.cancel() }
        Task { await modelSettings.loadAPIKeyIfNeeded() }
    }

    func showPrompt() {
        guard !screenAccessPaused else {
            statusMessage = "Screen access is paused"
            return
        }
        cancel(resetMessage: false)
        errorMessage = nil
        preparedSceneTask?.cancel()
        do {
            let target = try captureTargetApplication()
            preparedSceneTask = Task { [accessibility] in
                try await accessibility.captureScene(for: target)
            }
        } catch {
            preparedSceneTask = nil
            errorMessage = error.localizedDescription
        }
        prompt.show(
            onSubmit: { [weak self] question in
                guard let self else { return }
                let preparedSceneTask = self.preparedSceneTask
                self.preparedSceneTask = nil
                let identifier = UUID()
                self.requestTask?.cancel()
                self.requestID = identifier
                self.beginProcessingActivity()
                self.requestTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let scene: ScreenScene
                        if let preparedSceneTask {
                            scene = try await preparedSceneTask.value
                        } else {
                            scene = try await self.captureTargetScene()
                        }
                        try Task.checkCancellation()
                        let classification = await Task.detached(priority: .userInitiated) {
                            RequestModeClassifier().classification(for: question, scene: scene)
                        }.value
                        guard !Task.isCancelled else { return }
                        self.requestModeClassification = classification
                        await self.run(
                            question: question,
                            mode: classification.mode,
                            initialScene: scene
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.fail(with: error)
                    }
                    if self.requestID == identifier {
                        self.requestTask = nil
                        self.requestID = nil
                    }
                }
            },
            onCancel: { [weak self] in self?.cancel() }
        )
    }

    func run(question: String, mode: InteractionMode, initialScene: ScreenScene? = nil) async {
        guard !screenAccessPaused, !Task.isCancelled else { return }
        cancel(
            resetMessage: false,
            dismissesPrompt: false,
            cancelsRequest: false,
            endsProcessingActivity: false
        )
        await InstructorOperation.$id.withValue(operationID) {
            await runActive(question: question, mode: mode, initialScene: initialScene)
        }
    }

    private func runActive(question: String, mode: InteractionMode, initialScene: ScreenScene?) async {
        currentQuestion = question
        currentMode = mode
        errorMessage = nil
        outboundImagePreview = nil
        activeGuide = mode == .guide ? ActiveGuide(question: question) : nil
        do {
            try transition(.questionReceived)
            statusMessage = "Reading the current interface…"
            prompt.updateThinking(message: statusMessage)
            var scene: ScreenScene
            if let initialScene {
                scene = initialScene
            } else {
                scene = try await captureTargetScene()
            }

            if privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier) {
                statusMessage = "\(scene.activeApplication.name) is excluded; no screenshot was captured"
            } else {
                scene = await scenePreparedForReasoning(
                    from: scene,
                    question: question,
                    mode: mode
                )
            }
            try checkActiveOperation()
            currentScene = scene
            try transition(.sceneCaptured)
            try await generateAndPresent(question: question, mode: mode, scene: scene)
        } catch is CancellationError {
            return
        } catch {
            guard (try? checkActiveOperation()) != nil else { return }
            fail(with: error)
        }
    }

    func refreshInspector() async {
        await InstructorOperation.$id.withValue(operationID) {
            await refreshActiveInspector()
        }
    }

    private func refreshActiveInspector() async {
        do {
            var scene = try await captureTargetScene()
            if !privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier),
               hasScreenCapturePermission() {
                // Inspect the display the active window is on, like every other path.
                let point = scene.activeWindow?.bounds
                    .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
                scene = try await addingVisualContext(to: scene, point: point)
            }
            let marks = setOfMarksBuilder.build(scene: scene, query: currentQuestion)
            let preview = try? await renderSetOfMarks(scene: scene, marks: marks)
            try checkActiveOperation()
            currentScene = scene
            setOfMarksPreview = preview
            statusMessage = "Inspector refreshed: \(scene.elements.count) AX + \(scene.visualElements.count) visual elements"
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }

    func rebuildSetOfMarksPreview() async {
        let identifier = operationID
        guard !screenAccessPaused else { return }
        guard let scene = currentScene else { return }
        do {
            let marks = setOfMarksBuilder.build(scene: scene, query: currentQuestion)
            let preview = try await renderSetOfMarks(scene: scene, marks: marks)
            guard identifier == operationID, !screenAccessPaused, !Task.isCancelled else { return }
            setOfMarksPreview = preview
            statusMessage = "Set of Marks ready: \(setOfMarksPreview?.marks.count ?? 0) candidates"
        } catch { errorMessage = error.localizedDescription }
    }

    func showAllElementsOverlay() {
        guard !screenAccessPaused, !isObserving else { return }
        guard let elements = currentScene?.elements, !elements.isEmpty else { return }
        overlay.showDebugElements(elements)
        debugObservationTask?.cancel()
        let identifier = operationID
        debugObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                guard let scene = try? await self.captureTargetScene() else { continue }
                guard !Task.isCancelled, self.operationID == identifier, !self.screenAccessPaused else { return }
                self.currentScene = scene
                self.overlay.updateDebugElements(scene.elements)
            }
        }
    }

    func dismissOverlay() {
        cancel()
    }

    func cancel(
        resetMessage: Bool = true,
        dismissesPrompt: Bool = true,
        cancelsRequest: Bool = true,
        endsProcessingActivity: Bool = true
    ) {
        operationID = UUID()
        confirmationMessage = nil
        confirmationBaseline = nil
        noChangeRetries = 0
        unexpectedChangeRetries = 0
        contextReplans = 0
        automaticallyFollowsCurrentStep = false
        pendingHistoryItemID = nil
        frameComparisonSamples.removeAll()
        if cancelsRequest {
            requestID = nil
            requestTask?.cancel()
            requestTask = nil
        }
        preparedSceneTask?.cancel()
        preparedSceneTask = nil
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
        if endsProcessingActivity { endProcessingActivity() }
        if resetMessage { statusMessage = "Ready — press Option + Space" }
    }

    func requestPermission(_ permission: PermissionKind) {
        PermissionCenter().request(permission)
    }

    func dismissError() {
        errorMessage = nil
    }

    func displayConfigurationChanged() {
        // Re-baseline so the follow-up notification for this same change is a no-op.
        knownDisplays = currentDisplays()
        let hadRequest = state != .idle
        cancel()
        clearVisualContext()
        if hadRequest { statusMessage = SceneFreshnessIssue.displaysChanged.recoveryMessage }
    }

    func confirmResult(succeeded: Bool) async {
        guard state == .awaitingConfirmation, let baseline = confirmationBaseline else { return }
        confirmationBaseline = nil
        confirmationMessage = nil
        accessibilityChangeObserver.stop()
        observationTask?.cancel()
        observationTask = nil
        observationID = nil
        if !succeeded {
            stopGuideAfterRecovery(message: "The result was not confirmed. Restore the intended view and start a new request.")
            return
        }
        let identifier = operationID
        let requestIdentifier = UUID()
        requestTask?.cancel()
        requestID = requestIdentifier
        // Follow-on reasoning runs through the cancellable request handle, so Escape stops
        // an in-flight provider call instead of only discarding its result.
        let task = Task { [weak self] in
            await InstructorOperation.$id.withValue(identifier) {
                guard let self else { return }
                await self.continueAfterConfirmation(baseline: baseline)
            }
        }
        requestTask = task
        await task.value
        if requestID == requestIdentifier {
            requestTask = nil
            requestID = nil
        }
    }

    private func continueAfterConfirmation(baseline: ScreenScene) async {
        do {
            try transition(.resultConfirmed)
            recordCompletedStep(from: baseline)
            resolvePendingHistory(succeeded: true)
            overlay.dismiss()
            selectedTarget = nil
            let hasNext = activeGuide.map {
                $0.completedSteps.count < $0.maximumSteps && currentResponse?.taskComplete != true
                    && currentResponse?.completesTaskAfterSuccess != true
                    && currentResponse?.action?.type != .complete
            } ?? false
            if hasNext {
                beginProcessingActivity()
                let latest = try await captureTargetScene()
                try checkActiveOperation()
                guard SceneIdentity.sameDisplays(baseline, latest) else {
                    displayConfigurationChanged()
                    return
                }
                // The user confirmed the result. Continue the same request in the
                // current app, applying its capture exclusions and provider policy again.
                try transition(.verificationFinished(success: true, hasNextStep: true))
                await continueGuide(from: latest)
            } else {
                try transition(.verificationFinished(success: true, hasNextStep: false))
                statusMessage = completionStatusMessage(confirmedByUser: true)
                activeGuide = nil
                prompt.close()
                endProcessingActivity()
            }
        } catch is CancellationError {
            return
        } catch {
            fail(with: error)
        }
    }

    private func checkActiveOperation() throws {
        try Task.checkCancellation()
        guard !screenAccessPaused,
              InstructorOperation.id.map({ $0 == operationID }) ?? true else {
            throw CancellationError()
        }
    }

    private func clearVisualContext() {
        currentScene = nil
        setOfMarksPreview = nil
        outboundImagePreview = nil
        currentSetOfMarks = []
        modelContextPreview = ""
        frameComparisonSamples.removeAll()
    }

    private func privacyPolicyChanged() {
        cancel()
        clearVisualContext()
    }

    private func selectedModel(for request: InstructorRequest) async throws -> any InstructorModel {
        try checkActiveOperation()
        if privacySettings.isExcluded(bundleIdentifier: request.scene.activeApplication.bundleIdentifier) {
            return AccessibilityHeuristicProvider()
        }
        if let modelOverride { return modelOverride }
        switch modelSettings.provider {
        case .accessibility:
            return AccessibilityHeuristicProvider()
        case .openAI:
            guard privacySettings.cloudProcessingEnabled else {
                return AccessibilityHeuristicProvider()
            }
            await modelSettings.loadAPIKeyIfNeeded()
            try checkActiveOperation()
            return OpenAIProvider(
                model: modelSettings.openAIModel.rawValue,
                apiKey: modelSettings.storedAPIKey,
                allowsVision: privacySettings.cloudVisionEnabled
            )
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available {
                return AppleFoundationModelProvider(onContextPrepared: { [weak self] context in
                    await self?.recordPreparedContext(context)
                })
            }
            #endif
            return AccessibilityHeuristicProvider()
        }
    }

    private func recordPreparedContext(_ context: String) {
        guard (try? checkActiveOperation()) != nil else { return }
        modelContextPreview = context
    }

    private func captureTargetApplication() throws -> AccessibilityApplicationTarget {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = frontmost
            return AccessibilityApplicationTarget(application: frontmost)
        }
        guard let lastExternalApplication, !lastExternalApplication.isTerminated else {
            throw AccessibilityCaptureError.noFrontmostApplication
        }
        return AccessibilityApplicationTarget(application: lastExternalApplication)
    }

    private func captureTargetScene() async throws -> ScreenScene {
        try checkActiveOperation()
        let scene: ScreenScene
        if let captureSceneOverride {
            scene = try await captureSceneOverride()
        } else {
            scene = try await accessibility.captureScene(for: captureTargetApplication())
        }
        try checkActiveOperation()
        return scene
    }

    private func generateAndPresent(
        question: String,
        mode: InteractionMode,
        scene: ScreenScene
    ) async throws {
        try checkActiveOperation()
        // Each newly presented step gets its own recovery allowance; attempts spent on a
        // previous step must not stop this one after a single observation window.
        resetRecoveryAttempts()
        var request = InstructorRequest(question: question, scene: scene, mode: mode)
        request.guideContext = activeGuide?.context
        request.setOfMarks = setOfMarksBuilder.build(scene: scene, query: question)
        currentSetOfMarks = request.setOfMarks
        let step = activeGuide.map { " step \($0.completedSteps.count + 1)" } ?? ""
        var modelResponse: InstructorResponse
        let usedRecipe: Bool
        var reasoningModel: (any InstructorModel)?
        var usedLocalFallback = false
        if mode == .guide,
           let planned = ApplicationGuidePlanner(registry: guidePolicyRegistry).response(for: request) {
            outboundImagePreview = nil
            let modelContext = ModelContextBuilder().build(for: request)
            modelContextPreview = modelContext.userPrompt
            statusMessage = "Preparing your next step…"
            prompt.updateThinking(message: statusMessage)
            modelResponse = planned
            usedRecipe = true
        } else {
            usedRecipe = false
            let model = try await selectedModel(for: request)
            reasoningModel = model
            try checkActiveOperation()
            if model.capabilities.contains(.vision),
               privacySettings.cloudVisionEnabled,
               scene.screenshot != nil {
                let markedScene = try await renderSetOfMarks(scene: scene, marks: request.setOfMarks)
                try checkActiveOperation()
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
            modelContextPreview = modelContext.userPrompt
            statusMessage = "Reasoning with \(model.id) for\(step)…"
            prompt.updateThinking(message: statusMessage)
            do {
                modelResponse = try await model.reason(request: request)
            } catch {
                try checkActiveOperation()
                guard !(model is AccessibilityHeuristicProvider) else { throw error }
                errorMessage = "\(model.id) is unavailable: \(error.localizedDescription). Using local Accessibility matching."
                var localRequest = request
                localRequest.visualContextImage = nil
                // Keep the exact provider prompt and outbound image available for review
                // if the original request was already attempted. The local fallback does
                // not cross a privacy boundary and must not replace either inspection view.
                modelResponse = try await AccessibilityHeuristicProvider().reason(request: localRequest)
                usedLocalFallback = true
            }
        }
        try checkActiveOperation()
        if mode == .guide, !modelResponse.isActionableGuideResponse {
            if !usedRecipe,
               !usedLocalFallback,
               let reasoningModel,
               !(reasoningModel is AccessibilityHeuristicProvider) {
                errorMessage = "\(reasoningModel.id) did not provide an actionable guide step. Using local Accessibility matching."
                var localRequest = request
                localRequest.visualContextImage = nil
                // Preserve the exact prompt prepared for the configured provider. A
                // second, local-only interpretation must not obscure what was sent.
                modelResponse = try await AccessibilityHeuristicProvider().reason(request: localRequest)
                usedLocalFallback = true
                try checkActiveOperation()
            }
            guard modelResponse.isActionableGuideResponse else {
                throw InstructorResponseValidationError.incompleteGuideStep(modelResponse.message)
            }
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
                taskComplete: modelResponse.taskComplete,
                completesTaskAfterSuccess: modelResponse.completesTaskAfterSuccess
            )
        } else {
            response = modelResponse
        }
        _ = try response.action?.validated(in: scene, marks: request.setOfMarks)
        currentResponse = response
        automaticallyFollowsCurrentStep = mode == .guide
            && !usedRecipe
            && response.action?.type == .pointToElement
            && GuideProgressPolicy.prefersContinuousGuidance(question)
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
            try checkActiveOperation()
            groundingStrategy = result.strategy
            groundingConfidence = result.confidence
            try transition(.targetGrounded)

            statusMessage = "Checking that the interface is still ready…"
            prompt.updateThinking(message: statusMessage)
            var latestScene = try await captureTargetScene()
            var validation = await validatePresentation(
                source: scene,
                latest: latestScene,
                target: result.target
            )
            if case .inconclusive = validation {
                // A budget-limited AX walk is often transient while an application is
                // updating. Retry once before surfacing an actionable error, but never
                // approve the model response from the incomplete capture itself.
                latestScene = try await captureTargetScene()
                validation = await validatePresentation(
                    source: scene,
                    latest: latestScene,
                    target: result.target
                )
            }
            try checkActiveOperation()
            switch validation {
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
                if try await followContextChange(issue: issue, latest: observedScene,
                                                 question: question, mode: mode) {
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
            case .inconclusive:
                throw SceneFreshnessValidationError.incompleteCapture
            }
            overlay.showInstruction(VisualInstruction(
                text: response.message,
                explanation: response.expectedOutcome?.canVerifyAutomatically == false
                    ? (automaticallyFollowsCurrentStep
                        ? "Click once — Beacon will point to the next visible step."
                        : "Check the result, then choose Confirm Result in Beacon’s menu.")
                    : nil,
                target: selectedTarget,
                overlay: action.overlay
            ))
        }

        let expectsChange = response.expectedOutcome != nil && response.action?.type == .pointToElement
        // An informational answer has no task to confirm; only a guide's completion claim
        // needs the user to check the result.
        let claimsCompletion = response.taskComplete == true || response.action?.type == .complete
        let needsConfirmation = (expectsChange
            && response.expectedOutcome?.canVerifyAutomatically != true
            && !automaticallyFollowsCurrentStep)
            || (mode == .guide && !usedRecipe && claimsCompletion)
        if needsConfirmation {
            try transition(.confirmationRequested)
            confirmationBaseline = presentationScene.replacingScreenshot(with: nil).replacingVisualElements(with: [])
            confirmationMessage = response.expectedOutcome?.description
                ?? "Check that your requested task is complete."
            statusMessage = "Check the result, then confirm it in Beacon’s menu or main window."
            prompt.close()
            appendHistory(question: question, response: response, scene: presentationScene, succeeded: nil)
            if response.action?.type == .pointToElement {
                beginObservation(from: presentationScene)
            } else {
                prompt.showAnswer(message: "\(response.message)\n\n\(statusMessage)") { [weak self] in self?.cancel() }
            }
            endProcessingActivity()
            return
        }
        try transition(.instructionPresented(expectsChange: expectsChange))
        prompt.close()
        appendHistory(
            question: question,
            response: response,
            scene: presentationScene,
            succeeded: state == .completed ? (mode == .ask || usedRecipe && response.taskComplete == true) : nil
        )
        if state == .waitingForChange {
            statusMessage = automaticallyFollowsCurrentStep
                ? "Click the highlighted control — following the next screen automatically…"
                : "Watching for the expected change…"
            beginObservation(from: presentationScene)
        } else {
            statusMessage = response.taskComplete == true ? "Task completed" : "Answered"
            if response.action?.type != .pointToElement {
                prompt.showAnswer(message: response.message) { [weak self] in self?.cancel() }
            }
            activeGuide = nil
            endProcessingActivity()
        }
    }

    private func addingVisualContext(to scene: ScreenScene, point: CGPoint?) async throws -> ScreenScene {
        try checkActiveOperation()
        guard !privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier) else {
            throw CancellationError()
        }
        let snapshot = try await captureSnapshot(containing: point)
        try checkActiveOperation()
        let visualElements = try await analyzeVisualContext(snapshot)
        try checkActiveOperation()
        // Secure-field rectangles are taken next to the screenshot as well as from the
        // scene that requested it, so a field that moved while the user was typing the
        // question is still covered.
        let concurrentScene = try? await captureTargetScene()
        try checkActiveOperation()
        let maskSources = [scene, concurrentScene].compactMap { $0 }
        let safeContent = try await Task.detached(priority: .userInitiated) {
            let detector = SensitiveTextDetector()
            let redactor = RedactionService()
            let classified = detector.classify(visualElements)
            let regions = maskSources.flatMap { redactor.automaticRegions(in: $0) }
                + classified.regions
            return (
                try redactor.redact(snapshot: snapshot, regions: regions),
                classified.safeElements
            )
        }.value
        try checkActiveOperation()
        frameComparisonSamples.record(unredacted: snapshot, for: safeContent.0)
        return scene
            .replacingScreenshot(with: safeContent.0)
            .replacingVisualElements(with: safeContent.1)
    }

    /// Captures the display only to compare it with a baseline frame. The sample stays in
    /// memory, is never attached to a scene and never reaches a model, so it needs no
    /// Vision analysis or redaction pass. Nil means the frames are incomparable, which is
    /// not evidence that anything changed.
    private func frameDifference(
        from baseline: ScreenSnapshot,
        near point: CGPoint?
    ) async throws -> Double? {
        try checkActiveOperation()
        let comparisonBaseline = frameComparisonSamples.comparisonSample(for: baseline)
        let sample = try await captureSnapshot(containing: point)
        try checkActiveOperation()
        return await Task.detached(priority: .userInitiated) {
            let detector = FrameDifferenceDetector()
            if let comparisonBaseline {
                return detector.difference(between: comparisonBaseline, and: sample)
            }
            return detector.difference(between: baseline, and: sample)
        }.value
    }

    private func captureSnapshot(containing point: CGPoint?) async throws -> ScreenSnapshot {
        if let captureSnapshotOverride { return try await captureSnapshotOverride(point) }
        return try await screenCapture.captureDisplay(
            containing: point,
            excludingBundleIdentifiers: privacySettings.excludedBundleIdentifiers
        )
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
            let latest = try await captureTargetScene()
            guard sceneFreshnessValidator.contextStatus(source: scene, latest: latest) == .valid else {
                statusMessage = "The interface could not be confirmed while I was reading it. Using the latest view…"
                prompt.updateThinking(message: statusMessage)
                return latest
            }
            return latest
                .replacingScreenshot(with: visualScene.screenshot)
                .replacingVisualElements(with: visualScene.visualElements)
        } catch {
            guard (try? checkActiveOperation()) != nil else { return scene }
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
        guard (try? checkActiveOperation()) != nil, hasScreenCapturePermission(),
              !privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier) else {
            return false
        }
        var request = InstructorRequest(question: question, scene: scene, mode: mode)
        request.guideContext = activeGuide?.context
        request.setOfMarks = setOfMarksBuilder.build(scene: scene, query: question)
        if mode == .guide,
           ApplicationGuidePlanner(registry: guidePolicyRegistry)
            .response(for: request)?.isActionableGuideResponse == true {
            return false
        }
        if modelSettings.provider == .openAI,
           privacySettings.cloudProcessingEnabled,
           privacySettings.cloudVisionEnabled {
            return true
        }
        return LocalVisualContextPolicy.requiresVisualFallback(scene: scene, question: question)
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
        case .inconclusive:
            return .inconclusive
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
                  hasScreenCapturePermission(),
                  !privacySettings.isExcluded(bundleIdentifier: latest.activeApplication.bundleIdentifier) else {
                return .stale(
                    issue: .visualContextUnavailable(application: source.activeApplication.name),
                    latest: latest
                )
            }
            do {
                let point = latest.activeWindow?.bounds
                    .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
                // Staleness only needs a frame comparison, so this samples the display
                // instead of running a second full OCR and shape analysis. The source
                // scene's own visual context is still what gets presented.
                let difference = try await frameDifference(from: sourceSnapshot, near: point)
                let finalScene = try await captureTargetScene()
                switch sceneFreshnessValidator.validate(
                    source: source,
                    latest: finalScene,
                    target: refreshedTarget
                ) {
                case let .stale(issue):
                    return .stale(issue: issue, latest: finalScene)
                case .inconclusive:
                    return .inconclusive
                case .valid:
                    break
                }
                let changed = difference.map { $0 >= FrameDifferenceDetector().meaningfulThreshold }
                    ?? true
                guard !changed else {
                    return .stale(
                        issue: .visualContextUnavailable(application: source.activeApplication.name),
                        latest: finalScene
                    )
                }
                return .valid(
                    scene: finalScene
                        .replacingScreenshot(with: source.screenshot)
                        .replacingVisualElements(with: source.visualElements),
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
        guard expectedOutcomeAlreadySatisfied(
            response: response, source: source, latest: latest, mode: mode
        ) else { return false }

        selectedTarget = target
        if state == .awaitingContextRestore {
            // The step was completed while Beacon waited for the previous view to return.
            try transition(.meaningfulChangeDetected)
        } else {
            try transition(.instructionPresented(expectsChange: true))
            try transition(.meaningfulChangeDetected)
        }
        try await advanceAfterVerifiedStep(
            response: response,
            source: source,
            latest: latest,
            question: question,
            replanningMessage: "You already completed that step — updating the guide…"
        )
        return true
    }

    /// True when the response's expected outcome is already visible in `latest`, i.e. the
    /// user performed the step before Beacon observed it.
    private func expectedOutcomeAlreadySatisfied(
        response: InstructorResponse,
        source: ScreenScene,
        latest: ScreenScene,
        mode: InteractionMode
    ) -> Bool {
        guard mode == .guide,
              response.taskComplete != true,
              activeGuide != nil,
              response.expectedOutcome != nil else { return false }
        return StepVerifier().verify(
            expected: response.expectedOutcome,
            before: source,
            after: latest
        ).succeeded
    }

    /// Shared tail for a step that verified: record it, then either continue the guide or
    /// finish it with an accurate completion message.
    private func advanceAfterVerifiedStep(
        response: InstructorResponse,
        source: ScreenScene,
        latest: ScreenScene,
        question: String,
        replanningMessage: String,
        forceContinue: Bool = false
    ) async throws {
        currentScene = latest
        recordCompletedStep(from: source)
        let hasNextStep = activeGuide.map {
            $0.completedSteps.count < $0.maximumSteps
                && (forceContinue || (
                    response.taskComplete != true
                        && response.completesTaskAfterSuccess != true
                        && response.action?.type != .complete
                ))
        } ?? false
        try transition(.verificationFinished(success: true, hasNextStep: hasNextStep))
        // A step that was already presented has an unresolved history row; resolve it
        // rather than adding a second row and leaving the first unconfirmed forever.
        if !resolvePendingHistory(succeeded: true) {
            appendHistory(question: question, response: response, scene: latest, succeeded: true)
        }
        statusMessage = replanningMessage
        prompt.updateThinking(message: statusMessage)
        if hasNextStep {
            await continueGuide(from: latest)
        } else {
            prompt.close()
            statusMessage = completionStatusMessage(
                forcedBySafetyLimit: forceContinue
                    && activeGuide?.completedSteps.count == activeGuide?.maximumSteps
            )
            activeGuide = nil
            endProcessingActivity()
        }
    }

    /// A guide that finished its task on the eighth step is complete, not paused at the
    /// safety limit.
    private func completionStatusMessage(
        confirmedByUser: Bool = false,
        forcedBySafetyLimit: Bool = false
    ) -> String {
        let reachedLimit = activeGuide.map { $0.completedSteps.count == $0.maximumSteps } == true
            && (forcedBySafetyLimit || (
                currentResponse?.taskComplete != true
                    && currentResponse?.completesTaskAfterSuccess != true
                    && currentResponse?.action?.type != .complete
            ))
        if reachedLimit {
            return confirmedByUser
                ? "Step confirmed; paused at the 8-step safety limit"
                : "Task paused at the 8-step safety limit"
        }
        return confirmedByUser ? "Result confirmed by you" : "Task completed"
    }

    private func beginContextRecovery(
        issue: SceneFreshnessIssue,
        source: ScreenScene,
        latest: ScreenScene,
        target: GroundedTarget,
        question: String,
        mode: InteractionMode
    ) throws {
        if issue == .displaysChanged {
            displayConfigurationChanged()
            return
        }
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
        let events = changeEvents(
            for: source.activeApplication.processIdentifier,
            fallbackInterval: 1
        )
        observationTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(60)
            var lastCaptureAt: Date?
            for await event in events {
                guard !Task.isCancelled, let self, self.observationID == identifier else { return }
                if Date() >= deadline { break }
                if case .notification = event {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                await Self.waitForObservationInterval(since: lastCaptureAt)
                guard !Task.isCancelled, self.observationID == identifier else { return }
                lastCaptureAt = Date()
                guard let restoredScene = try? await self.captureTargetScene() else { continue }
                // The user may complete the expected step while Beacon is waiting for the
                // old view to come back. That outcome is success, not a lost context.
                if await self.completeStepIfAlreadyDone(
                    source: source,
                    latest: restoredScene,
                    target: target,
                    question: question,
                    mode: mode
                ) {
                    return
                }
                switch self.sceneFreshnessValidator.validate(
                    source: source,
                    latest: restoredScene,
                    target: target
                ) {
                case .valid:
                    self.accessibilityChangeObserver.stop()
                    self.observationID = nil
                    try? self.transition(.contextRestored)
                    self.statusMessage = "Thanks — checking the restored view…"
                    self.prompt.showThinking(message: self.statusMessage) { [weak self] in self?.cancel() }
                    let prepared = await self.scenePreparedForReasoning(
                        from: restoredScene,
                        question: question,
                        mode: mode
                    )
                    do {
                        try self.checkActiveOperation()
                        self.currentScene = prepared
                        try self.transition(.sceneCaptured)
                        try await self.generateAndPresent(question: question, mode: mode, scene: prepared)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard (try? self.checkActiveOperation()) != nil else { return }
                        self.fail(with: error)
                    }
                    return
                case .inconclusive:
                    // An incomplete AX traversal proves neither restoration nor change.
                    // Keep waiting for a conclusive capture without disturbing the guide.
                    continue
                case let .stale(currentIssue):
                    guard currentIssue != .displaysChanged else {
                        // Waiting for the previous view to return is pointless once the
                        // display layout itself changed; the geometry is gone.
                        self.displayConfigurationChanged()
                        return
                    }
                    do {
                        if try await self.followContextChange(issue: currentIssue, latest: restoredScene,
                                                              question: question, mode: mode) {
                            return
                        }
                    } catch {
                        guard (try? self.checkActiveOperation()) != nil else { return }
                        self.fail(with: error)
                        return
                    }
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
            self.prompt.showAnswer(message: self.statusMessage) { [weak self] in self?.cancel() }
            self.endProcessingActivity()
        }
    }

    /// Recognises the expected outcome while Beacon is waiting for a lost context to
    /// return, and advances the guide instead of timing out on a step the user finished.
    private func completeStepIfAlreadyDone(
        source: ScreenScene,
        latest: ScreenScene,
        target: GroundedTarget,
        question: String,
        mode: InteractionMode
    ) async -> Bool {
        guard state == .awaitingContextRestore,
              let response = currentResponse,
              expectedOutcomeAlreadySatisfied(
                response: response, source: source, latest: latest, mode: mode
              ) else { return false }

        // Advancing presents the next step, which starts its own observation. This one
        // must be torn down first, or that teardown would stop the new observer instead.
        accessibilityChangeObserver.stop()
        observationID = nil
        do {
            _ = try await reconcileAlreadyCompletedStep(
                response: response,
                source: source,
                latest: latest,
                target: target,
                question: question,
                mode: mode
            )
            return true
        } catch is CancellationError {
            return true
        } catch {
            guard (try? checkActiveOperation()) != nil else { return true }
            fail(with: error)
            return true
        }
    }

    private func beginObservation(from baseline: ScreenScene) {
        observationTask?.cancel()
        accessibilityChangeObserver.stop()
        let identifier = UUID()
        observationID = identifier
        let baselineFingerprint = SceneFingerprint(scene: baseline)
        let targetID = selectedTarget?.elementID
        let events = changeEvents(
            for: baseline.activeApplication.processIdentifier,
            fallbackInterval: Self.observationFallbackInterval
        )
        observationTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.observationTimeout)
            var latestUnconfirmedScene: ScreenScene?
            var lastCaptureAt: Date?
            var attemptedLocalVisualVerification = false
            var consecutiveObservationFailures = 0
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self, self.observationID == identifier else { return }
                if event == .observerUnavailable { continue }
                if Date() >= deadline { break }
                if case .notification = event {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                await Self.waitForObservationInterval(since: lastCaptureAt)
                guard !Task.isCancelled, self.observationID == identifier else { return }
                lastCaptureAt = Date()
                do {
                    var newScene = try await self.captureTargetScene()
                    consecutiveObservationFailures = 0
                    guard SceneIdentity.sameDisplays(baseline, newScene) else {
                        self.displayConfigurationChanged()
                        return
                    }
                    if self.state == .awaitingConfirmation {
                        if let target = self.selectedTarget {
                            switch self.sceneFreshnessValidator.validate(source: baseline, latest: newScene, target: target) {
                            case let .valid(refreshed): self.overlay.updateTarget(refreshed)
                            case .inconclusive: continue
                            case .stale:
                                if self.overlay.presentation != nil {
                                    self.overlay.dismiss()
                                    self.showConfirmationReminder()
                                }
                            }
                        }
                        continue
                    }
                    if SceneIdentity.sameApplication(baseline, newScene),
                       SceneIdentity.sameWindow(baseline.activeWindow, newScene.activeWindow),
                       let targetID,
                       let element = newScene.elements.first(where: { $0.id == targetID }),
                       element.enabled, let bounds = element.bounds, bounds.isValid {
                        let target = GroundedTarget.accessibilityElement(elementId: targetID, bounds: bounds)
                        self.selectedTarget = target
                        self.overlay.updateTarget(target)
                    }
                    let latestFingerprint = SceneFingerprint(scene: newScene)
                    let accessibilityChanged = latestFingerprint != baselineFingerprint
                    let interfaceChanged = baselineFingerprint.interfaceChanged(comparedTo: latestFingerprint)
                    let highlightedMenuOpened = GuideProgressPolicy.highlightedMenuOpened(
                        event: event,
                        target: targetID.flatMap { id in baseline.elements.first { $0.id == id } },
                        latest: newScene
                    )
                    var visualDifference: Double?
                    let shouldProbeVisualChange = !accessibilityChanged
                        || (self.automaticallyFollowsCurrentStep && !interfaceChanged)
                    if shouldProbeVisualChange {
                        if let baselineSnapshot = baseline.screenshot,
                           !self.privacySettings.isExcluded(
                            bundleIdentifier: newScene.activeApplication.bundleIdentifier
                           ), self.hasScreenCapturePermission() {
                            let point = baseline.activeWindow?.bounds
                                .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
                            // Compare a cheap in-memory sample first. OCR and shape analysis
                            // cost far more than the comparison and are only worth running
                            // once something on screen actually moved.
                            let difference = try await self.frameDifference(
                                from: baselineSnapshot,
                                near: point
                            )
                            try self.checkActiveOperation()
                            if let difference,
                               difference >= FrameDifferenceDetector().meaningfulThreshold {
                                let accessibilityScene = newScene
                                let visualScene = try await self.addingVisualContext(
                                    to: accessibilityScene,
                                    point: point
                                )
                                let stableScene = try await self.captureTargetScene()
                                guard self.sceneFreshnessValidator.contextStatus(
                                    source: accessibilityScene,
                                    latest: stableScene
                                ) == .valid, visualScene.screenshot != nil else { continue }
                                newScene = stableScene
                                    .replacingScreenshot(with: visualScene.screenshot)
                                    .replacingVisualElements(with: visualScene.visualElements)
                                visualDifference = difference
                            } else if !highlightedMenuOpened {
                                continue
                            }
                        } else if !highlightedMenuOpened {
                            continue
                        }
                    }
                    let verifier = StepVerifier()
                    var verification = verifier.verify(
                        expected: self.currentResponse?.expectedOutcome,
                        before: baseline,
                        after: newScene,
                        visualDifference: visualDifference
                    )
                    if !verification.succeeded,
                       !attemptedLocalVisualVerification,
                       self.currentMode == .guide,
                       self.hasScreenCapturePermission(),
                       !self.privacySettings.isExcluded(
                           bundleIdentifier: newScene.activeApplication.bundleIdentifier
                       ),
                       verifier.mayBenefitFromLocalVisualContext(
                           expected: self.currentResponse?.expectedOutcome,
                           before: baseline,
                           after: newScene
                       ) {
                        attemptedLocalVisualVerification = true
                        if let visualScene = try await self.localVisualVerificationScene(
                            from: newScene
                        ) {
                            newScene = visualScene
                            verification = verifier.verify(
                                expected: self.currentResponse?.expectedOutcome,
                                before: baseline,
                                after: newScene,
                                visualDifference: visualDifference
                            )
                        }
                    }
                    if !verification.succeeded,
                       self.automaticallyFollowsCurrentStep,
                       SceneIdentity.sameApplication(baseline, newScene),
                       SceneIdentity.sameWindow(baseline.activeWindow, newScene.activeWindow),
                       interfaceChanged || visualDifference != nil || highlightedMenuOpened,
                       let response = self.currentResponse {
                        self.accessibilityChangeObserver.stop()
                        try self.transition(.meaningfulChangeDetected)
                        self.confirmationBaseline = nil
                        self.confirmationMessage = nil
                        self.overlay.dismiss()
                        try await self.advanceAfterVerifiedStep(
                            response: response,
                            source: baseline,
                            latest: newScene,
                            question: self.currentQuestion
                                ?? self.activeGuide?.question
                                ?? "Continue the guide",
                            replanningMessage: "Next screen detected — finding the next control…",
                            forceContinue: true
                        )
                        return
                    }
                    if !verification.succeeded {
                        if let target = self.selectedTarget {
                            switch self.sceneFreshnessValidator.validate(
                                source: baseline,
                                latest: newScene,
                                target: target
                            ) {
                            case let .stale(issue):
                                if try await self.followContextChange(
                                    issue: issue, latest: newScene,
                                    question: self.currentQuestion ?? self.activeGuide?.question ?? "Continue the guide",
                                    mode: self.currentMode
                                ) {
                                    return
                                }
                                self.accessibilityChangeObserver.stop()
                                try self.transition(.meaningfulChangeDetected)
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
                            case .inconclusive:
                                continue
                            case .valid:
                                break
                            }
                        }
                        latestUnconfirmedScene = newScene
                        continue
                    }

                    self.accessibilityChangeObserver.stop()
                    try self.transition(.meaningfulChangeDetected)
                    self.currentScene = newScene
                    self.statusMessage = "Verifying the result…"
                    self.overlay.dismiss()
                    self.prompt.showThinking(message: self.statusMessage) { [weak self] in
                        self?.cancel()
                    }
                    self.resetRecoveryAttempts()
                    self.recordCompletedStep(from: baseline)
                    let hasNextStep = self.activeGuide.map {
                        $0.completedSteps.count < $0.maximumSteps
                            && self.currentResponse?.taskComplete != true
                            && self.currentResponse?.completesTaskAfterSuccess != true
                            && self.currentResponse?.action?.type != .complete
                    } ?? false
                    try self.transition(.verificationFinished(success: true, hasNextStep: hasNextStep))
                    self.overlay.dismiss()
                    self.resolvePendingHistory(succeeded: true)
                    if hasNextStep {
                        await self.continueGuide(from: newScene)
                    } else {
                        self.prompt.close()
                        self.statusMessage = self.completionStatusMessage()
                        self.activeGuide = nil
                        self.endProcessingActivity()
                    }
                    return
                } catch {
                    guard (try? self.checkActiveOperation()) != nil else { return }
                    consecutiveObservationFailures += 1
                    if consecutiveObservationFailures >= 3 {
                        self.stopGuideAfterRecovery(
                            message: "Beacon stopped waiting because it could not read the current interface after three attempts. Keep the target app in front, then try again."
                        )
                        return
                    }
                }
            }
            guard !Task.isCancelled, let self, self.observationID == identifier else { return }
            self.accessibilityChangeObserver.stop()
            if self.state == .awaitingConfirmation {
                self.overlay.dismiss()
                self.observationID = nil
                self.observationTask = nil
                self.showConfirmationReminder()
                return
            }
            if self.automaticallyFollowsCurrentStep,
               self.currentResponse?.completesTaskAfterSuccess == true {
                try? self.transition(.confirmationRequested)
                self.confirmationBaseline = baseline
                    .replacingScreenshot(with: nil)
                    .replacingVisualElements(with: [])
                self.confirmationMessage = self.currentResponse?.expectedOutcome?.description
                    ?? "Check whether the requested change completed."
                self.overlay.dismiss()
                self.observationID = nil
                self.observationTask = nil
                self.statusMessage = "No new screen was detected. Confirm only if the task actually completed."
                self.showConfirmationReminder()
                self.endProcessingActivity()
                return
            }
            let noChange = latestUnconfirmedScene == nil
            let retryBaseline = latestUnconfirmedScene ?? baseline
            let attempt = self.incrementRecoveryAttempt(noChange: noChange)
            let decision = self.guidePolicyRegistry.recoveryDecision(
                for: baseline.activeApplication.bundleIdentifier,
                attempt: attempt,
                noChange: noChange,
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
                let prepared = await self.scenePreparedForObservation(from: retryBaseline)
                guard (try? self.checkActiveOperation()) != nil else { return }
                self.beginObservation(from: prepared)
            } else {
                self.stopGuideAfterRecovery(message: decision.message)
            }
        }
    }

    /// Collapses a burst of Accessibility notifications into one capture. Applications
    /// that publish layout changes many times per second would otherwise keep the
    /// observation loop capturing continuously for its whole window.
    private static func waitForObservationInterval(since last: Date?) async {
        guard let last else { return }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed < minimumObservationInterval else { return }
        try? await Task.sleep(for: .milliseconds(Int((minimumObservationInterval - elapsed) * 1_000)))
    }

    private func scenePreparedForObservation(from scene: ScreenScene) async -> ScreenScene {
        guard scene.screenshot == nil else { return scene }
        return await scenePreparedForReasoning(
            from: scene,
            question: currentQuestion ?? activeGuide?.question ?? "Continue the guide",
            mode: currentMode
        )
    }

    /// A visible guide may expose a newly changed control whose AX node has role/value
    /// evidence but no label. Capture and OCR it once locally, validate that the scene
    /// stayed stable during analysis, and keep the result in memory for verification only.
    private func localVisualVerificationScene(from scene: ScreenScene) async throws -> ScreenScene? {
        guard hasScreenCapturePermission(),
              !privacySettings.isExcluded(
                  bundleIdentifier: scene.activeApplication.bundleIdentifier
              ) else { return nil }
        let point = scene.activeWindow?.bounds
            .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
        let visualScene = try await addingVisualContext(to: scene, point: point)
        let stableScene = try await captureTargetScene()
        guard sceneFreshnessValidator.contextStatus(source: scene, latest: stableScene) == .valid,
              visualScene.screenshot != nil else { return nil }
        return stableScene
            .replacingScreenshot(with: visualScene.screenshot)
            .replacingVisualElements(with: visualScene.visualElements)
    }

    private func showConfirmationReminder() {
        guard let confirmationMessage else { return }
        prompt.showAnswer(message: "\(confirmationMessage)\n\nChoose Confirm Result or That Didn’t Work in Beacon’s menu or main window.") {
            [weak self] in self?.cancel()
        }
    }

    private func incrementRecoveryAttempt(noChange: Bool) -> Int {
        if noChange {
            noChangeRetries += 1
        } else {
            unexpectedChangeRetries += 1
        }
        return noChange ? noChangeRetries : unexpectedChangeRetries
    }

    private func resetRecoveryAttempts() {
        noChangeRetries = 0
        unexpectedChangeRetries = 0
    }

    private func stopGuideAfterRecovery(message: String) {
        confirmationMessage = nil
        confirmationBaseline = nil
        accessibilityChangeObserver.stop()
        observationTask?.cancel()
        observationTask = nil
        observationID = nil
        overlay.dismiss()
        prompt.close()
        try? transition(.fail)
        statusMessage = message
        activeGuide = nil
        endProcessingActivity()
        resolvePendingHistory(succeeded: false)
    }

    private func continueGuide(from changedScene: ScreenScene) async {
        guard let activeGuide else { return }
        await continueRequest(from: changedScene, question: activeGuide.question, mode: .guide)
    }

    /// A different app or window invalidates the old target, but does not cancel
    /// the user's goal or prove that the previous action succeeded.
    private func followContextChange(
        issue: SceneFreshnessIssue,
        latest: ScreenScene,
        question: String,
        mode: InteractionMode
    ) async throws -> Bool {
        switch issue {
        case .applicationChanged, .windowChanged: break
        default: return false
        }
        try checkActiveOperation()
        guard contextReplans < maximumContextReplans else {
            stopGuideAfterRecovery(message: "The active app or window kept changing. Start a new request when the view is ready.")
            return true
        }
        contextReplans += 1
        accessibilityChangeObserver.stop()
        observationID = nil
        overlay.dismiss()
        selectedTarget = nil
        currentResponse = nil
        clearVisualContext()
        try transition(.contextChanged)
        statusMessage = "Continuing your request in \(latest.activeApplication.name)…"
        prompt.showThinking(message: statusMessage) { [weak self] in self?.cancel() }
        do {
            // Let a newly activated window settle before taking fresh local context.
            try await Task.sleep(for: .milliseconds(250))
            let freshScene = try await captureTargetScene()
            guard SceneIdentity.sameDisplays(latest, freshScene) else {
                displayConfigurationChanged()
                return true
            }
            await continueRequest(from: freshScene, question: question, mode: mode)
        } catch {
            try checkActiveOperation()
            fail(with: error)
        }
        return true
    }

    private func changeEvents(for processIdentifier: Int32, fallbackInterval: TimeInterval) -> AsyncStream<AccessibilityChangeEvent> {
        observationEventsOverride?(processIdentifier, fallbackInterval)
            ?? accessibilityChangeObserver.events(for: processIdentifier, fallbackInterval: fallbackInterval)
    }

    private func continueRequest(from changedScene: ScreenScene, question: String, mode: InteractionMode) async {
        do {
            statusMessage = "Preparing the next step…"
            prompt.showThinking(message: statusMessage) { [weak self] in
                self?.cancel()
            }
            let scene = await scenePreparedForReasoning(
                from: changedScene.replacingScreenshot(with: nil).replacingVisualElements(with: []),
                question: question,
                mode: mode
            )
            try checkActiveOperation()
            currentScene = scene
            try transition(.sceneCaptured)
            try await generateAndPresent(question: question, mode: mode, scene: scene)
        } catch is CancellationError {
            return
        } catch {
            guard (try? checkActiveOperation()) != nil else { return }
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
        if event != .cancel && event != .fail { try checkActiveOperation() }
        state = try machine.handle(event)
    }

    private func fail(with error: Error) {
        guard (try? checkActiveOperation()) != nil else { return }
        observationTask?.cancel()
        observationTask = nil
        observationID = nil
        accessibilityChangeObserver.stop()
        activeGuide = nil
        confirmationMessage = nil
        confirmationBaseline = nil
        pendingHistoryItemID = nil
        frameComparisonSamples.removeAll()
        try? transition(.fail)
        errorMessage = error.localizedDescription
        statusMessage = "Beacon couldn't complete that request"
        overlay.dismiss()
        // Show request failures beside the pointer. The main window deliberately avoids
        // presenting the same failure in a second modal alert.
        prompt.showAnswer(message: error.localizedDescription) { [weak self] in
            self?.cancel()
            self?.dismissError()
        }
        endProcessingActivity()
    }

    private func appendHistory(
        question: String,
        response: InstructorResponse,
        scene: ScreenScene,
        succeeded: Bool?
    ) {
        let item = GuideHistoryItem(
            date: Date(),
            question: question,
            answer: response.message,
            applicationName: scene.activeApplication.name,
            succeeded: succeeded
        )
        history.insert(item, at: 0)
        if succeeded == nil {
            pendingHistoryItemID = item.id
        }
    }

    @discardableResult
    private func resolvePendingHistory(succeeded: Bool) -> Bool {
        defer { pendingHistoryItemID = nil }
        guard let pendingHistoryItemID,
              let index = history.firstIndex(where: { $0.id == pendingHistoryItemID && $0.succeeded == nil }) else {
            return false
        }
        history[index] = history[index].withSucceeded(succeeded)
        return true
    }

    private func encodeForInspection(_ response: InstructorResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func renderSetOfMarks(
        scene: ScreenScene,
        marks: [SetOfMark]
    ) async throws -> MarkedScreenScene {
        try await Task.detached(priority: .userInitiated) {
            try SetOfMarksRenderer().render(scene: scene, marks: marks)
        }.value
    }

    private func beginProcessingActivity() {
        endProcessingActivity()
        processingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Processing an explicit Beacon guidance request"
        )
    }

    private func endProcessingActivity() {
        guard let processingActivity else { return }
        ProcessInfo.processInfo.endActivity(processingActivity)
        self.processingActivity = nil
    }
}

enum GuideProgressPolicy {
    private static let continuousGuidanceWords: Set<String> = [
        "account", "avatar", "button", "change", "choose", "click", "configure",
        "edit", "enable", "disable", "find", "guide", "how", "menu", "open",
        "photo", "picture", "profile", "select", "set", "setting", "settings",
        "show", "switch", "turn", "where"
    ]

    static func prefersContinuousGuidance(_ question: String) -> Bool {
        let words = Set(question.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
        return !words.isDisjoint(with: continuousGuidanceWords)
    }

    static func highlightedMenuOpened(
        event: AccessibilityChangeEvent,
        target: UIElementDescriptor?,
        latest: ScreenScene
    ) -> Bool {
        guard let target,
              target.role == "AXMenuBarItem" || target.role == "AXPopUpButton" else {
            return false
        }
        if target.selected != true,
           latest.elements.first(where: { $0.id == target.id })?.selected == true {
            return true
        }
        guard case let .notification(name, _, observedLabel) = event,
              name == kAXMenuOpenedNotification,
              let observedLabel else { return false }
        let expected = normalizedMenuLabel(target.bestLabel)
        let observed = normalizedMenuLabel(observedLabel)
        guard !expected.isEmpty, !observed.isEmpty else { return false }
        return expected == observed
            || observed.hasPrefix(expected + " ")
            || expected.hasPrefix(observed + " ")
    }

    private static func normalizedMenuLabel(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

enum LocalVisualContextPolicy {
    private static let confidentAccessibleMatch = 0.65
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.safari",
        "com.brave.browser",
        "com.google.chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.browser",
        "org.mozilla.firefox"
    ]
    private static let staticMenuBundleIdentifiers: Set<String> = [
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.vscodium"
    ]

    static func requiresVisualFallback(scene: ScreenScene, question: String) -> Bool {
        let normalized = question.lowercased()
        let explicitlyVisual = [
            "circle", "rectangle", "shape", "drawing", "canvas", "icon", "symbol",
            "image", "screenshot", "visible", "on screen"
        ].contains(where: normalized.contains)
        let semanticMatch = SemanticElementMatcher.bestMatch(for: question, in: scene.elements)
        let needsBrowserContext = scene.activeApplication.bundleIdentifier
            .map { browserBundleIdentifiers.contains($0.lowercased()) } == true
            && GuideProgressPolicy.prefersContinuousGuidance(question)
        let needsStaticMenuContext = scene.activeApplication.bundleIdentifier
            .map { staticMenuBundleIdentifiers.contains($0.lowercased()) } == true
            && GuideProgressPolicy.prefersContinuousGuidance(question)
        let needsVisibleMenuTransition = GuideProgressPolicy.prefersContinuousGuidance(question)
            && semanticMatch?.element.role == "AXMenuBarItem"
        return explicitlyVisual
            || needsBrowserContext
            || needsStaticMenuContext
            || needsVisibleMenuTransition
            || (semanticMatch?.score ?? 0) < confidentAccessibleMatch
    }
}

struct SceneFingerprint: Equatable {
    let app: String?
    let processIdentifier: Int32
    let window: String?
    let hasWindow: Bool
    let windowID: String?
    let windows: [WindowState]
    let displays: [DisplayDescriptor]
    let elements: [ElementState]
    let focused: String?

    init(scene: ScreenScene) {
        app = scene.activeApplication.bundleIdentifier
        processIdentifier = scene.activeApplication.processIdentifier
        window = scene.activeWindow?.title
        hasWindow = scene.activeWindow != nil
        windowID = scene.activeWindow?.id
        // Identity and title, not geometry: moving or resizing a window is not a change
        // in what the interface offers, and it must not read as the user's action.
        windows = scene.windows.map(WindowState.init).sorted { ($0.id ?? "") < ($1.id ?? "") }
        displays = scene.displays.sorted { $0.id < $1.id }
        elements = scene.elements.map(ElementState.init).sorted { $0.id < $1.id }
        focused = scene.elements.first(where: \.focused)?.id
    }

    /// Focus alone is too weak to prove that a navigation click revealed the next step.
    /// Menus, popovers, pages, control values, and application/window changes are useful
    /// progress; a button merely becoming focused is not.
    func interfaceChanged(comparedTo other: SceneFingerprint) -> Bool {
        app != other.app
            || processIdentifier != other.processIdentifier
            || window != other.window
            || hasWindow != other.hasWindow
            || windowID != other.windowID
            || windows != other.windows
            || displays != other.displays
            || elements != other.elements
    }

    struct WindowState: Equatable {
        let id: String?
        let title: String?
        let role: String?
        let parentWindowID: String?

        init(_ window: WindowDescriptor) {
            id = window.id
            title = window.title
            role = window.role
            parentWindowID = window.parentWindowID
        }
    }

    struct ElementState: Equatable {
        let id: String
        let label: String
        let value: String?
        let enabled: Bool
        let selected: Bool?

        init(_ element: UIElementDescriptor) {
            id = element.id
            label = element.bestLabel
            value = element.value
            enabled = element.enabled
            selected = element.selected
        }
    }
}

private enum InstructorOperation {
    @TaskLocal static var id: UUID?
}

private enum PresentationValidation {
    case valid(scene: ScreenScene, target: GroundedTarget)
    case stale(issue: SceneFreshnessIssue, latest: ScreenScene)
    case inconclusive
}

private enum SceneFreshnessValidationError: LocalizedError {
    case incompleteCapture

    var errorDescription: String? {
        "Beacon could not finish checking the current interface. Try again after the application has finished updating."
    }
}

private enum InstructorResponseValidationError: LocalizedError {
    case incompleteGuideStep(String)

    var errorDescription: String? {
        guard case let .incompleteGuideStep(message) = self else { return nil }
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Beacon could not locate a safe on-screen target for the next guide step."
            + (detail.isEmpty ? "" : " \(detail)")
    }
}

private extension InstructorResponse {
    /// Guide mode may finish only on an explicit completion claim. Every other response
    /// must identify a real target; otherwise `instructionPresented(expectsChange: false)`
    /// would incorrectly turn an incomplete guide into a completed informational answer.
    var isActionableGuideResponse: Bool {
        switch action?.type {
        case .pointToElement:
            // A proposed action and a claim that the task is already complete describe
            // mutually exclusive scene states.
            return taskComplete != true
        case .complete:
            return taskComplete != false && completesTaskAfterSuccess != true
        case .explain:
            return false
        case nil:
            return taskComplete == true && completesTaskAfterSuccess != true
        }
    }
}

private struct ActiveGuide {
    let question: String
    let maximumSteps = 8
    var completedSteps: [CompletedGuideStep] = []

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
            id: id,
            date: date,
            question: question,
            answer: answer,
            applicationName: applicationName,
            succeeded: succeeded
        )
    }
}
