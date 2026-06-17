import Foundation

/// Client for any OpenAI-compatible chat completions API (OpenAI, Groq, Ollama,
/// Together, etc.). Same request shape, different base URL and model names.
actor OpenAICompatibleClient: LLMProvider {
    private let apiKey: String
    private let baseURL: String
    private let fastModel: String
    private let smartModel: String

    init(apiKey: String, baseURL: String, fastModel: String, smartModel: String) {
        self.apiKey = apiKey
        self.baseURL = baseURL
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
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userMessage],
            ],
        ]

        let url = URL(string: "\(baseURL)/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw LLMError.http(0, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        struct Response: Decodable {
            let choices: [Choice]
            struct Choice: Decodable {
                let message: Message
                struct Message: Decodable {
                    let content: String?
                }
            }
        }

        do {
            let r = try JSONDecoder().decode(Response.self, from: data)
            return r.choices.first?.message.content ?? ""
        } catch {
            throw LLMError.decode("\(error) — \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
    }
}
