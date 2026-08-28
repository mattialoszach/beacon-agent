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
    @Published private(set) var history: [GuideHistoryItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage = "Ready — press Option + Space"
    @Published var screenAccessPaused = false

    var privacySettings = PrivacySettingsStore()
    var modelSettings = ModelConfigurationStore()

    private let accessibility = AccessibilityService()
    private let screenCapture = ScreenCaptureService()
    private let redactor = RedactionService()
    private let grounder: any GroundingStrategy = HybridGrounder()
    private let shortcut = GlobalShortcutMonitor()
    private let prompt = FloatingPromptController()
    private let overlay = OverlayController()
    private var machine = InstructorStateMachine()
    private var preparedScene: ScreenScene?
    private var observationTask: Task<Void, Never>?
    private var debugObservationTask: Task<Void, Never>?
    private var settingsCancellables = Set<AnyCancellable>()
    private var started = false

    var isObserving: Bool { [.capturingScene, .understanding, .grounding, .waitingForChange, .verifying].contains(state) }

    init() {
        privacySettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &settingsCancellables)
        modelSettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &settingsCancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        shortcut.registerOptionSpace { [weak self] in self?.showPrompt(mode: .guide) }
        overlay.onDismiss = { [weak self] in self?.cancel() }
    }

    func showPrompt(mode: InteractionMode) {
        guard !screenAccessPaused else {
            statusMessage = "Screen access is paused"
            return
        }
        errorMessage = nil
        do {
            preparedScene = try accessibility.captureScene()
        } catch {
            preparedScene = nil
            errorMessage = error.localizedDescription
        }
        prompt.show(
            mode: mode,
            onSubmit: { [weak self] question, selectedMode in
                Task { await self?.run(question: question, mode: selectedMode) }
            },
            onCancel: { [weak self] in self?.cancel() }
        )
    }

    func run(question: String, mode: InteractionMode) async {
        cancel(resetMessage: false)
        currentQuestion = question
        errorMessage = nil
        do {
            try transition(.questionReceived)
            statusMessage = "Reading the current interface…"
            var scene = try preparedScene ?? accessibility.captureScene()
            preparedScene = nil

            if privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier) {
                statusMessage = "\(scene.activeApplication.name) is excluded; no screenshot was captured"
            } else if CGPreflightScreenCaptureAccess() {
                do {
                    let point = scene.activeWindow?.bounds
                        .flatMap(DisplayGeometryProvider().currentMapper().axRect(from:))?.center
                    let snapshot = try await screenCapture.captureDisplay(containing: point)
                    let regions = redactor.automaticRegions(in: scene)
                    let safeSnapshot = try redactor.redact(snapshot: snapshot, regions: regions)
                    scene = scene.replacingScreenshot(with: safeSnapshot)
                } catch {
                    statusMessage = "Continuing without a screenshot: \(error.localizedDescription)"
                }
            }
            currentScene = scene
            try transition(.sceneCaptured)

            let request = InstructorRequest(question: question, scene: scene, mode: mode)
            let model = try selectedModel(for: request)
            statusMessage = "Reasoning with \(model.id)…"
            let response = try await model.reason(request: request)
            _ = try response.action?.validated(in: scene)
            currentResponse = response
            rawModelResponse = encodeForInspection(response)
            try transition(.responseGenerated(needsTarget: response.action?.type == .pointToElement))

            if let action = response.action, action.type == .pointToElement {
                let result = try await grounder.resolve(
                    intention: UIIntention(
                        question: question,
                        preferredElementID: action.targetElementId,
                        preferredBounds: action.targetBounds
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

            try transition(.instructionPresented(expectsChange: response.expectedOutcome != nil && response.action != nil))
            statusMessage = state == .waitingForChange ? "Waiting for the interface to change…" : "Answered"
            appendHistory(question: question, response: response, scene: scene, succeeded: state == .completed ? true : nil)
            if state == .waitingForChange { beginObservation(from: scene) }
        } catch {
            fail(with: error)
        }
    }

    func refreshInspector() async {
        do {
            var scene = try accessibility.captureScene()
            if !privacySettings.isExcluded(bundleIdentifier: scene.activeApplication.bundleIdentifier),
               CGPreflightScreenCaptureAccess() {
                let snapshot = try await screenCapture.captureDisplay()
                let safe = try redactor.redact(snapshot: snapshot, regions: redactor.automaticRegions(in: scene))
                scene = scene.replacingScreenshot(with: safe)
            }
            currentScene = scene
            statusMessage = "Inspector refreshed: \(scene.elements.count) interactive elements"
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
                guard let scene = try? self.accessibility.captureScene() else { continue }
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
        debugObservationTask?.cancel()
        debugObservationTask = nil
        overlay.dismiss()
        prompt.close()
        try? transition(.cancel)
        selectedTarget = nil
        if resetMessage { statusMessage = "Ready — press Option + Space" }
    }

    func requestPermission(_ permission: PermissionKind) {
        PermissionCenter().request(permission)
    }

    private func selectedModel(for request: InstructorRequest) throws -> any InstructorModel {
        if privacySettings.isExcluded(bundleIdentifier: request.scene.activeApplication.bundleIdentifier) {
            return AccessibilityHeuristicProvider()
        }
        switch modelSettings.provider {
        case .accessibility:
            return AccessibilityHeuristicProvider()
        case .openAI:
            guard privacySettings.cloudProcessingEnabled,
                  modelSettings.processingMode != .localOnly else {
                return AccessibilityHeuristicProvider()
            }
            return OpenAIProvider(
                model: modelSettings.openAIModel,
                apiKey: modelSettings.apiKey
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

    private func beginObservation(from baseline: ScreenScene) {
        observationTask?.cancel()
        let baselineFingerprint = SceneFingerprint(scene: baseline)
        let targetID = selectedTarget?.elementID
        observationTask = Task { [weak self] in
            for _ in 0..<150 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(650))
                guard let self else { return }
                do {
                    let newScene = try self.accessibility.captureScene()
                    if let targetID,
                       let element = newScene.elements.first(where: { $0.id == targetID }),
                       let bounds = element.bounds {
                        let target = GroundedTarget.accessibilityElement(elementId: targetID, bounds: bounds)
                        self.selectedTarget = target
                        self.overlay.updateTarget(target)
                    }
                    guard SceneFingerprint(scene: newScene) != baselineFingerprint else { continue }
                    try self.transition(.meaningfulChangeDetected)
                    self.currentScene = newScene
                    self.statusMessage = "Verifying the result…"
                    try self.transition(.verificationFinished(success: true, hasNextStep: false))
                    self.overlay.dismiss()
                    self.statusMessage = "Step completed"
                    if let index = self.history.indices.last { self.history[index] = self.history[index].withSucceeded(true) }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                }
            }
        }
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

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension ScreenScene {
    func replacingScreenshot(with snapshot: ScreenSnapshot?) -> ScreenScene {
        ScreenScene(
            timestamp: timestamp,
            activeApplication: activeApplication,
            activeWindow: activeWindow,
            screenshot: snapshot,
            elements: elements,
            displays: displays
        )
    }
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
