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
    let capabilities: ModelCapabilities = [.text, .structuredOutput]
    let model: String
    let apiKey: String
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
        _ = try decoded.action?.validated(in: request.scene)
        return decoded
    }

    private func requestBody(for request: InstructorRequest) -> [String: Any] {
        let controls = request.scene.elements.map {
            "[\($0.id)] \($0.role ?? "UIElement") \"\($0.bestLabel)\" bounds=\($0.bounds.map(String.init(describing:)) ?? "none")"
        }.joined(separator: "\n")
        let userPrompt = """
        Question: \(request.question)
        Mode: \(request.mode.rawValue)
        Application: \(request.scene.activeApplication.name)
        Window: \(request.scene.activeWindow?.title ?? "Unknown")
        Visible accessible controls:\n\(controls)
        """

        return [
            "model": model,
            "input": [
                ["role": "developer", "content": [["type": "input_text", "text": "You are Beacon, a macOS UI instructor. Select only supplied element IDs. Never invent coordinates. Give one short next step."]]],
                ["role": "user", "content": [["type": "input_text", "text": userPrompt]]]
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
            "required": ["message", "action", "expectedOutcome"],
            "properties": [
                "message": ["type": "string"],
                "action": [
                    "anyOf": [
                        ["type": "null"],
                        [
                            "type": "object", "additionalProperties": false,
                            "required": ["type", "targetElementId", "targetBounds", "overlay"],
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
                            "required": ["type", "description"],
                            "properties": [
                                "type": ["type": "string", "enum": ["windowAppears", "windowDisappears", "focusedElementChanges", "elementAppears", "visualChange"]],
                                "description": ["type": "string"]
                            ]
                        ]
                    ]
                ]
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
