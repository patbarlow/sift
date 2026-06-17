import Foundation

/// Anthropic Messages API client. Uses prompt caching for system prompts.
actor AnthropicClient: LLMProvider {
    private let apiKey: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let fastModel: String
    private let smartModel: String

    init(apiKey: String,
         fastModel: String = "claude-haiku-4-5",
         smartModel: String = "claude-sonnet-4-5") {
        self.apiKey = apiKey
        self.fastModel = fastModel
        self.smartModel = smartModel
    }

    func send(tier: LLMTier,
              system: String,
              userMessage: String,
              maxTokens: Int?,
              temperature: Double) async throws -> String {
        let model = tier == .fast ? fastModel : smartModel
        let maxTok = maxTokens ?? (tier == .fast ? 1024 : 2048)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTok,
            "temperature": temperature,
            "system": [
                [
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"],
                ]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": userMessage,
                ]
            ],
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw LLMError.http(0, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        struct Response: Decodable {
            let content: [Content]
            struct Content: Decodable { let type: String; let text: String? }
        }

        do {
            let r = try JSONDecoder().decode(Response.self, from: data)
            return r.content.compactMap(\.text).joined()
        } catch {
            throw LLMError.decode("\(error) — \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
    }
}
