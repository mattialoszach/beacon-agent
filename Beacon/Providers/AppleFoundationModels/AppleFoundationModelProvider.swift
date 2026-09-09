#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct AppleFoundationModelProvider: InstructorModel {
    let id = "Apple Intelligence"
    let capabilities: ModelCapabilities = [.text, .structuredOutput, .local]
    var onContextPrepared: (@Sendable (String) async -> Void)? = nil

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        do {
            return try await reason(request: request, builder: ModelContextBuilder())
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            return try await reason(
                request: request,
                builder: ModelContextBuilder(maximumElements: 20, maximumCharacters: 2_800)
            )
        }
    }

    private func reason(
        request: InstructorRequest,
        builder: ModelContextBuilder
    ) async throws -> InstructorResponse {
        let context = builder.build(for: request)
        await onContextPrepared?(context.userPrompt)
        try Task.checkCancellation()
        let session = LanguageModelSession(instructions: """
        You are Beacon, a concise macOS UI instructor. Prefer an element ID listed in the prompt. You may
        choose a listed mark number for a visual fallback. Give exactly one next step. Never invent an element
        ID, mark, or coordinate. If the task is already done,
        choose complete. In Guide mode, point to the next useful listed control; never substitute an explanation
        for a missing target. taskComplete describes the current scene. Set completesTaskAfterSuccess only when
        successful verification of this proposed action will finish the user's overall goal. Controls that open
        a menu, account panel, settings page, sidebar section, or profile editor are navigation steps, not final
        steps; keep guiding after the interface changes.
        Set expectedApplicationScope to mayChange only when this step should open or activate another app;
        otherwise use sameApplication.
        Describe the exact expected control label and role for automatic verification, and its expected
        value for a value change. Use none when unknown. A generic visual change needs user confirmation.
        For app changes specify the destination bundle identifier; never guess it.
        """)
        let response = try await session.respond(
            to: context.userPrompt,
            generating: AppleInstructionPayload.self,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 448)
        )
        let payload = response.content
        let actionType = ActionType(rawValue: payload.actionType) ?? .explain
        let targetID = Self.value(payload.targetElementID)
        let targetMark = payload.targetMark > 0 ? payload.targetMark : nil
        // Only a pointing answer uses a target, so an unusable placeholder in an explain
        // or complete answer must not discard an otherwise valid response.
        if actionType == .pointToElement {
            if let targetID,
               !context.includedElementIDs.contains(targetID),
               !context.includedVisualElementIDs.contains(targetID) {
                throw GroundingError.elementNotFound(targetID)
            }
            if let targetMark, !context.includedMarkIDs.contains(targetMark) {
                throw GroundingError.markNotFound(targetMark)
            }
        }
        let expectedType = ExpectedOutcomeType(rawValue: payload.expectedOutcomeType)
        let expectedApplicationScope = ExpectedApplicationScope(
            rawValue: payload.expectedApplicationScope
        ) ?? .sameApplication
        let action: SuggestedAction? = actionType == .pointToElement
            ? SuggestedAction(
                type: .pointToElement,
                targetElementId: targetID,
                targetBounds: nil,
                targetMark: targetMark,
                overlay: OverlayStyle(rawValue: payload.overlay) ?? .spotlight
            )
            : nil
        let expectedLabel = Self.value(payload.expectedElementLabel)
        let result = InstructorResponse(
            message: payload.message,
            action: action,
            expectedOutcome: expectedType.map {
                ExpectedOutcome(
                    type: $0,
                    description: payload.expectedOutcomeDescription,
                    applicationScope: expectedApplicationScope,
                    element: expectedLabel.map { label in
                        ExpectedElement(
                            labels: [label],
                            role: Self.value(payload.expectedElementRole),
                            value: Self.value(payload.expectedElementValue)
                        )
                    },
                    windowTitle: Self.value(payload.expectedWindowTitle),
                    destinationBundleIdentifier: Self.value(payload.destinationBundleIdentifier)
                )
            },
            taskComplete: payload.taskComplete || actionType == .complete,
            completesTaskAfterSuccess: payload.completesTaskAfterSuccess
        )
        let normalized = result.normalizingVisualTarget(in: request.scene)
        _ = try normalized.action?.validated(in: request.scene, marks: request.setOfMarks)
        return normalized
    }

    /// The schema asks for the word "none" when a field does not apply, but a local model
    /// also emits an empty string, "None" or "N/A". All of them mean absent.
    static func value(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders: Set<String> = ["", "none", "n/a", "null", "nil", "unknown"]
        return placeholders.contains(trimmed.lowercased()) ? nil : trimmed
    }
}

@available(macOS 26.0, *)
@Generable(description: "One safe, concise Beacon UI instruction")
private struct AppleInstructionPayload {
    @Guide(description: "A short instruction or explanation for the user")
    let message: String

    @Guide(description: "The kind of response", .anyOf(["pointToElement", "explain", "complete"]))
    let actionType: String

    @Guide(description: "An exact listed element ID, or the word none")
    let targetElementID: String

    @Guide(description: "An exact listed mark number, or zero")
    let targetMark: Int

    @Guide(description: "How Beacon should highlight the target", .anyOf(["arrow", "rectangle", "circle", "spotlight", "tooltip"]))
    let overlay: String

    @Guide(description: "Expected change after the step, or none", .anyOf(["windowAppears", "windowDisappears", "focusedElementChanges", "elementAppears", "visualChange", "none"]))
    let expectedOutcomeType: String

    @Guide(description: "One short description of the expected result")
    let expectedOutcomeDescription: String

    @Guide(description: "Whether the expected result stays in this app or may open another app", .anyOf(["sameApplication", "mayChange"]))
    let expectedApplicationScope: String

    @Guide(description: "Exact label of the control that should appear, focus, or change value; none if unknown")
    let expectedElementLabel: String

    @Guide(description: "AX role of that expected control, or none")
    let expectedElementRole: String

    @Guide(description: "Exact expected value after a value change, or none")
    let expectedElementValue: String

    @Guide(description: "Exact title of the window that should appear, or none")
    let expectedWindowTitle: String

    @Guide(description: "Destination application bundle identifier for mayChange, or none")
    let destinationBundleIdentifier: String

    @Guide(description: "True only when the user's overall task is complete")
    let taskComplete: Bool

    @Guide(description: "True only when successful verification of this proposed action will finish the overall task")
    let completesTaskAfterSuccess: Bool
}
#endif
