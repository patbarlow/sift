import Foundation

/// Anthropic Messages API client. Uses prompt caching, per-model capability
/// detection (so it adapts sampling/effort/structured-output support to
/// whatever model the user picks), and structured outputs where available.
actor AnthropicClient: LLMProvider {
    private let apiKey: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let fastModel: String
    private let smartModel: String

    /// What a given model supports, fetched once from the Models API and cached.
    private struct ModelCaps {
        let acceptsTemperature: Bool
        let supportsEffort: Bool
        let supportsStructuredOutputs: Bool
    }
    private var capsByModel: [String: ModelCaps] = [:]

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
        try await post(model: modelFor(tier), system: system, userMessage: userMessage,
                       maxTokens: maxTokens ?? defaultTokens(tier), temperature: temperature, schema: nil)
    }

    func sendForJSON(tier: LLMTier,
                     system: String,
                     userMessage: String,
                     maxTokens: Int?,
                     temperature: Double,
                     schema: [String: Any]?) async throws -> [String: Any] {
        let raw = try await post(model: modelFor(tier), system: system, userMessage: userMessage,
                                 maxTokens: maxTokens ?? defaultTokens(tier), temperature: temperature, schema: schema)
        return try extractJSON(from: raw)
    }

    private func modelFor(_ tier: LLMTier) -> String { tier == .fast ? fastModel : smartModel }
    private func defaultTokens(_ tier: LLMTier) -> Int { tier == .fast ? 1024 : 2048 }

    private func post(model: String,
                      system: String,
                      userMessage: String,
                      maxTokens: Int,
                      temperature: Double,
                      schema: [String: Any]?) async throws -> String {
        let caps = await capabilities(for: model)

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            // 1-hour cache TTL: syncs run tens of minutes apart, so the default
            // 5-minute window would expire between runs and re-pay the write.
            "system": [
                [
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral", "ttl": "1h"],
                ]
            ],
            "messages": [
                ["role": "user", "content": userMessage]
            ],
        ]
        // Sampling params were removed on Claude 4.6+ and the 5 family; only send
        // temperature to models that still accept it. Omitting never errors.
        if caps.acceptsTemperature {
            body["temperature"] = temperature
        }
        // output_config carries both the effort dial and the structured-output
        // schema; only include the pieces the model supports.
        var outputConfig: [String: Any] = [:]
        if caps.supportsEffort {
            outputConfig["effort"] = "low"
        }
        if let schema, caps.supportsStructuredOutputs {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        if !outputConfig.isEmpty {
            body["output_config"] = outputConfig
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

    /// Fetch (once, then cache) what this model supports from the Models API.
    /// On any failure we assume nothing — omitting params never errors, which
    /// keeps a plain request working against any model.
    private func capabilities(for model: String) async -> ModelCaps {
        if let c = capsByModel[model] { return c }
        let caps = await fetchCapabilities(model)
        capsByModel[model] = caps
        return caps
    }

    private func fetchCapabilities(_ model: String) async -> ModelCaps {
        let none = ModelCaps(acceptsTemperature: false, supportsEffort: false, supportsStructuredOutputs: false)
        guard let url = URL(string: "https://api.anthropic.com/v1/models/\(model)") else { return none }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caps = obj["capabilities"] as? [String: Any] else {
            return none
        }
        func flag(_ path: [String]) -> Bool {
            var cur: Any? = caps
            for key in path { cur = (cur as? [String: Any])?[key] }
            return (cur as? Bool) ?? false
        }
        // Adaptive-thinking models dropped sampling params; the older
        // enabled/budget-style thinking models still accept temperature.
        return ModelCaps(
            acceptsTemperature: flag(["thinking", "types", "enabled", "supported"]),
            supportsEffort: flag(["effort", "supported"]),
            supportsStructuredOutputs: flag(["structured_outputs", "supported"])
        )
    }
}
