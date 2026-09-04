import Foundation

enum CloudProviderError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an OpenAI API key in Model settings before using cloud processing."
        case .invalidResponse: "The cloud model returned an unreadable response."
        case let .requestFailed(code, message): "The model request failed (\(code)): \(message)"
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
        guard !apiKey.isEmpty else { throw CloudProviderError.missingAPIKey }
        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(for: request))

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw CloudProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw CloudProviderError.requestFailed(http.statusCode, message)
        }

        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        guard let json = envelope.output
            .flatMap(\.content)
            .first(where: { $0.type == "output_text" })?.text,
              let payload = json.data(using: .utf8) else { throw CloudProviderError.invalidResponse }
        let decoded = try JSONDecoder().decode(InstructorResponse.self, from: payload)
            .normalizingVisualTarget(in: request.scene)
        _ = try decoded.action?.validated(in: request.scene, marks: request.setOfMarks)
        return decoded
    }

    func requestBody(for request: InstructorRequest) -> [String: Any] {
        let context = ModelContextBuilder(maximumElements: 100, maximumCharacters: 12_000).build(for: request)
        let userPrompt = """
        Question: \(request.question)
        \(context.text)
        """
        var userContent: [[String: Any]] = [["type": "input_text", "text": userPrompt]]
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
                ["role": "developer", "content": [["type": "input_text", "text": "You are Beacon, a macOS UI instructor. Prefer supplied stable element IDs. If a numbered visual preview is present, use targetMark to select its exact badge for canvas, CAD, icon, or unlabeled targets. Otherwise use only listed visual bounds. Never invent an ID, mark, or coordinate. Give one short next step, account for completed steps, and mark taskComplete only when the overall task is done. Set expectedOutcome.applicationScope to mayChange only when this step is expected to open or activate another application; otherwise use sameApplication."]]],
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
            "required": ["message", "action", "expectedOutcome", "taskComplete"],
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
                            "required": ["type", "description", "applicationScope"],
                            "properties": [
                                "type": ["type": "string", "enum": ["windowAppears", "windowDisappears", "focusedElementChanges", "elementAppears", "visualChange"]],
                                "description": ["type": "string"],
                                "applicationScope": ["type": "string", "enum": ["sameApplication", "mayChange"]]
                            ]
                        ]
                    ]
                ],
                "taskComplete": ["type": "boolean"]
            ]
        ]
    }

    private struct ResponseEnvelope: Decodable {
        let output: [Output]
    }

    private struct Output: Decodable {
        let content: [Content]
    }

    private struct Content: Decodable {
        let type: String
        let text: String?
    }
}
