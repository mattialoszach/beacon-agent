#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct AppleFoundationModelProvider: InstructorModel {
    let id = "Apple Intelligence"
    let capabilities: ModelCapabilities = [.text, .structuredOutput, .local]

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        let session = LanguageModelSession(instructions: """
        You are Beacon, a macOS UI instructor. Choose only from the supplied element IDs.
        Return JSON with message, action, and expectedOutcome matching the supplied schema description.
        Never invent an element ID or pixel coordinate.
        """)
        let response = try await session.respond(to: Prompt(modelPrompt(for: request)))
        let data = Data(response.content.utf8)
        let decoded = try JSONDecoder().decode(InstructorResponse.self, from: data)
        _ = try decoded.action?.validated(in: request.scene)
        return decoded
    }

    private func modelPrompt(for request: InstructorRequest) -> String {
        let elements = request.scene.elements.map {
            "[\($0.id)] \($0.role ?? "UIElement") \"\($0.bestLabel)\""
        }.joined(separator: "\n")
        return """
        Question: \(request.question)
        Application: \(request.scene.activeApplication.name)
        Window: \(request.scene.activeWindow?.title ?? "Unknown")
        Visible controls:\n\(elements)

        JSON shape:
        {"message":"...","action":{"type":"pointToElement","targetElementId":"e_...","targetBounds":null,"overlay":"spotlight"},"expectedOutcome":{"type":"visualChange","description":"..."}}
        """
    }
}
#endif
