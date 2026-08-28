#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct AppleFoundationModelProvider: InstructorModel {
    let id = "Apple Intelligence"
    let capabilities: ModelCapabilities = [.text, .structuredOutput, .local]

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
        let session = LanguageModelSession(instructions: """
        You are Beacon, a concise macOS UI instructor. Prefer an element ID listed in the prompt. You may
        choose a listed mark number for a visual fallback. Give exactly one next step. Never invent an element
        ID, mark, or coordinate. If the task is already done,
        choose complete. If no listed control is useful, choose explain and say what the user should reveal.
        """)
        let response = try await session.respond(
            to: "Question: \(request.question)\n\(context.text)",
            generating: AppleInstructionPayload.self,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 320)
        )
        let payload = response.content
        let targetID = payload.targetElementID == "none" ? nil : payload.targetElementID
        if let targetID,
           !context.includedElementIDs.contains(targetID),
           !context.includedVisualElementIDs.contains(targetID) {
            throw GroundingError.elementNotFound(targetID)
        }
        let targetMark = payload.targetMark > 0 ? payload.targetMark : nil
        if let targetMark, !context.includedMarkIDs.contains(targetMark) {
            throw GroundingError.markNotFound(targetMark)
        }
        let actionType = ActionType(rawValue: payload.actionType) ?? .explain
        let expectedType = ExpectedOutcomeType(rawValue: payload.expectedOutcomeType)
        let action: SuggestedAction? = actionType == .pointToElement
            ? SuggestedAction(
                type: .pointToElement,
                targetElementId: targetID,
                targetBounds: nil,
                targetMark: targetMark,
                overlay: OverlayStyle(rawValue: payload.overlay) ?? .spotlight
            )
            : nil
        let result = InstructorResponse(
            message: payload.message,
            action: action,
            expectedOutcome: expectedType.map {
                ExpectedOutcome(type: $0, description: payload.expectedOutcomeDescription)
            },
            taskComplete: payload.taskComplete || actionType == .complete
        )
        let normalized = result.normalizingVisualTarget(in: request.scene)
        _ = try normalized.action?.validated(in: request.scene, marks: request.setOfMarks)
        return normalized
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

    @Guide(description: "True only when the user's overall task is complete")
    let taskComplete: Bool
}
#endif
