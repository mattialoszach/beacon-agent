import Foundation

enum CloudProviderError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Int, String)
    case refused(String)
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an OpenAI API key in Model settings before using cloud processing."
        case .invalidResponse: "The cloud model returned an unreadable response."
        case let .requestFailed(code, message): "The model request failed (\(code)): \(message)"
        case let .refused(reason):
            "The cloud model declined this request: \(reason) Try rephrasing the question."
        case let .incomplete(reason):
            switch reason {
            case "max_output_tokens":
                "The cloud model ran out of response space. Ask about a smaller part of the screen."
            case "content_filter":
                "The cloud model stopped this response with its content filter. Try rephrasing the question."
            default:
                "The cloud model returned an incomplete response (\(reason))."
            }
        }
    }
}

struct OpenAIProvider: InstructorModel {
    let id = "OpenAI"
    var capabilities: ModelCapabilities {
        allowsVision ? [.text, .vision, .structuredOutput] : [.text, .structuredOutput]
    }
    let model: String
    let apiKey: String
    var allowsVision = false
    var session: URLSession = .shared

    func reason(request: InstructorRequest) async throws -> InstructorResponse {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw CloudProviderError.missingAPIKey }
        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(for: request))

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw CloudProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // A non-JSON body is usually an infrastructure error page, which is noise in
            // an error banner; the status description is more useful there.
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw CloudProviderError.requestFailed(http.statusCode, message)
        }

        try Task.checkCancellation()
        return try decodeResponse(data, for: request)
    }

    func decodeResponse(_ data: Data, for request: InstructorRequest) throws -> InstructorResponse {
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        let messageContent = envelope.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
        // A refusal and a truncated response are both readable and actionable; reporting
        // them as an unreadable response tells the user nothing.
        if let refusal = messageContent.compactMap(\.refusal).first {
            throw CloudProviderError.refused(refusal)
        }
        guard envelope.status == "completed" else {
            if envelope.status == "incomplete" {
                throw CloudProviderError.incomplete(
                    envelope.incompleteDetails?.reason ?? envelope.status
                )
            }
            throw CloudProviderError.invalidResponse
        }
        guard let json = messageContent.first(where: { $0.type == "output_text" })?.text,
              let payload = json.data(using: .utf8) else { throw CloudProviderError.invalidResponse }
        let decoded = try JSONDecoder().decode(InstructorResponse.self, from: payload)
            .normalizingVisualTarget(in: request.scene)
        guard !decoded.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudProviderError.invalidResponse
        }
        _ = try decoded.action?.validated(in: request.scene, marks: request.setOfMarks)
        return decoded
    }

    func requestBody(for request: InstructorRequest) -> [String: Any] {
        let context = ModelContextBuilder(maximumElements: 100, maximumCharacters: 12_000).build(for: request)
        var userContent: [[String: Any]] = [["type": "input_text", "text": context.userPrompt]]
        if allowsVision, let snapshot = request.visualContextImage {
            userContent.append([
                "type": "input_image",
                "image_url": "data:image/png;base64,\(snapshot.pngData.base64EncodedString())",
                "detail": "high"
            ])
        }

        return [
            "model": model,
            "store": false,
            "input": [
                ["role": "developer", "content": [["type": "input_text", "text": "You are Beacon, a macOS UI instructor. Prefer supplied stable element IDs. If a numbered visual preview is present, use targetMark to select its exact badge for canvas, CAD, icon, or unlabeled targets. Otherwise use only listed visual bounds. Never invent an ID, mark, or coordinate. Give one short next step and account for completed steps. taskComplete means the overall task is already done in the current scene. completesTaskAfterSuccess means verifying the proposed action will finish the overall task. A control that opens a menu, account panel, settings page, sidebar section, or profile editor is a navigation step, not a final step; keep guiding after the interface changes. In Guide mode, return a pointToElement action for the next visible step or complete only when current scene evidence proves completion; never substitute a prose answer for a missing target. Set expectedOutcome.applicationScope to mayChange only when this step is expected to open or activate another application; otherwise use sameApplication. Supply exact expectedOutcome.element labels and AX role for appearance or focus, plus the expected value for a value change. Use a listed ID only for an existing expected control. Supply the exact destinationBundleIdentifier for app handoffs. Use null for unknown evidence; those steps require user confirmation. A generic visual change or closed Save dialog does not prove success."]]],
                ["role": "user", "content": userContent]
            ],
            "text": ["format": [
                "type": "json_schema",
                "name": "beacon_instruction",
                "strict": true,
                "schema": responseSchema
            ]]
        ]
    }

    private var responseSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "message", "action", "expectedOutcome", "taskComplete",
                "completesTaskAfterSuccess"
            ],
            "properties": [
                "message": ["type": "string"],
                "action": [
                    "anyOf": [
                        ["type": "null"],
                        [
                            "type": "object", "additionalProperties": false,
                            "required": ["type", "targetElementId", "targetBounds", "targetMark", "overlay"],
                            "properties": [
                                "type": ["type": "string", "enum": ["pointToElement", "explain", "complete"]],
                                "targetElementId": ["anyOf": [["type": "string"], ["type": "null"]]],
                                "targetBounds": [
                                    "anyOf": [
                                        ["type": "null"],
                                        [
                                            "type": "object", "additionalProperties": false,
                                            "required": ["x", "y", "width", "height"],
                                            "properties": [
                                                "x": ["type": "number", "minimum": 0, "maximum": 1],
                                                "y": ["type": "number", "minimum": 0, "maximum": 1],
                                                "width": ["type": "number", "minimum": 0, "maximum": 1],
                                                "height": ["type": "number", "minimum": 0, "maximum": 1]
                                            ]
                                        ]
                                    ]
                                ],
                                "targetMark": [
                                    "anyOf": [
                                        ["type": "integer", "minimum": 1, "maximum": 80],
                                        ["type": "null"]
                                    ]
                                ],
                                "overlay": ["type": "string", "enum": OverlayStyle.allCases.map(\.rawValue)]
                            ]
                        ]
                    ]
                ],
                "expectedOutcome": [
                    "anyOf": [
                        ["type": "null"],
                        [
                            "type": "object", "additionalProperties": false,
                            "required": ["type", "description", "applicationScope", "element", "windowTitle", "destinationBundleIdentifier"],
                            "properties": [
                                "type": ["type": "string", "enum": ["windowAppears", "windowDisappears", "focusedElementChanges", "elementAppears", "visualChange"]],
                                "description": ["type": "string"],
                                "applicationScope": ["type": "string", "enum": ["sameApplication", "mayChange"]],
                                "windowTitle": ["type": ["string", "null"]],
                                "destinationBundleIdentifier": ["type": ["string", "null"]],
                                "element": ["anyOf": [
                                    ["type": "null"],
                                    ["type": "object", "additionalProperties": false,
                                     "required": ["id", "labels", "role", "value"],
                                     "properties": [
                                        "id": ["type": ["string", "null"]],
                                        "labels": ["type": "array", "items": ["type": "string"]],
                                        "role": ["type": ["string", "null"]],
                                        "value": ["type": ["string", "null"]]
                                     ]]
                                ]]
                            ]
                        ]
                    ]
                ],
                "taskComplete": ["type": "boolean"],
                "completesTaskAfterSuccess": ["type": "boolean"]
            ]
        ]
    }

    private struct ResponseEnvelope: Decodable {
        let status: String
        let output: [Output]
        let incompleteDetails: IncompleteDetails?

        enum CodingKeys: String, CodingKey {
            case status
            case output
            case incompleteDetails = "incomplete_details"
        }
    }

    private struct IncompleteDetails: Decodable {
        let reason: String?
    }

    private struct Output: Decodable {
        let type: String
        let content: [Content]?
    }

    private struct Content: Decodable {
        let type: String
        let text: String?
        let refusal: String?
    }
}
