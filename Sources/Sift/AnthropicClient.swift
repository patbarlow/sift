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

    /// Whether a model accepts sampling params (`temperature` etc.). The 4.5
    /// generation and earlier do; Claude 4.6+ and the 5 family removed them.
    /// Unknown models default to `false` — omitting is always safe, sending is
    /// what 400s.
    private static func acceptsTemperature(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("-4-5") || m.contains("-4-1") || m.contains("claude-3")
    }

    func send(tier: LLMTier,
              system: String,
              userMessage: String,
              maxTokens: Int?,
              temperature: Double) async throws -> String {
        let model = tier == .fast ? fastModel : smartModel
        let maxTok = maxTokens ?? (tier == .fast ? 1024 : 2048)

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTok,
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
        // Sampling params were removed on Claude 4.6+ and the 5 family — sending
        // `temperature` there returns a 400. Only send it to models known to
        // accept it (the 4.5 generation and earlier); newer/unknown models omit
        // it and use their default, which never errors.
        if Self.acceptsTemperature(model) {
            body["temperature"] = temperature
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        // Background sync calls are not latency-sensitive; the heaviest one
        // (memory glossary rebuild over all todos) can exceed the 60s default.
        req.timeoutInterval = 180
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
            let usage: Usage?
            struct Content: Decodable { let type: String; let text: String? }
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_read_input_tokens: Int?
                let cache_creation_input_tokens: Int?
            }
        }

        do {
            let r = try JSONDecoder().decode(Response.self, from: data)
            if let u = r.usage {
                await LLMUsageStore.shared.record(
                    input: u.input_tokens ?? 0,
                    output: u.output_tokens ?? 0,
                    cacheRead: u.cache_read_input_tokens ?? 0,
                    cacheCreation: u.cache_creation_input_tokens ?? 0)
            }
            return r.content.compactMap(\.text).joined()
        } catch {
            throw LLMError.decode("\(error) — \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
    }
}
