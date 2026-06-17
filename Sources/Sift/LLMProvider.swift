import Foundation

/// Abstract tiers that each provider maps to its own model names.
/// "fast" handles classification / assessment; "smart" handles summarisation.
enum LLMTier {
    case fast
    case smart
}

/// Unified interface for all LLM backends. Implementations are responsible
/// for mapping tiers to concrete model identifiers and handling their own
/// HTTP / auth differences.
protocol LLMProvider: Sendable {
    func send(tier: LLMTier,
              system: String,
              userMessage: String,
              maxTokens: Int?,
              temperature: Double) async throws -> String

    func sendForJSON(tier: LLMTier,
                     system: String,
                     userMessage: String,
                     maxTokens: Int?,
                     temperature: Double) async throws -> [String: Any]

    func extractJSON(from text: String) throws -> [String: Any]
}

// Default sendForJSON implementation — parse JSON from the raw text response.
extension LLMProvider {
    func sendForJSON(tier: LLMTier,
                     system: String,
                     userMessage: String,
                     maxTokens: Int?,
                     temperature: Double) async throws -> [String: Any] {
        let raw = try await send(
            tier: tier,
            system: system,
            userMessage: userMessage,
            maxTokens: maxTokens,
            temperature: temperature
        )
        return try extractJSON(from: raw)
    }

    /// Extracts a JSON object from model output. Tolerates fenced code blocks
    /// and surrounding prose.
    func extractJSON(from text: String) throws -> [String: Any] {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        guard let open = cleaned.firstIndex(of: "{") else {
            throw LLMError.decode("no JSON object found in response: \(text.prefix(200))")
        }
        var depth = 0
        var endIdx: String.Index?
        var i = open
        while i < cleaned.endIndex {
            let c = cleaned[i]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { endIdx = i; break }
            }
            i = cleaned.index(after: i)
        }
        guard let close = endIdx else {
            throw LLMError.decode("unbalanced JSON in response: \(text.prefix(200))")
        }
        let blob = String(cleaned[open...close])
        guard let data = blob.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decode("could not parse JSON: \(blob.prefix(200))")
        }
        return obj
    }
}

enum LLMError: LocalizedError {
    case http(Int, String)
    case decode(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .http(let c, let body): return "LLM HTTP \(c): \(body.prefix(300))"
        case .decode(let s): return "LLM decode: \(s)"
        case .api(let s): return "LLM API: \(s)"
        }
    }
}

// MARK: - Provider registry

enum LLMProviderKind: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case gemini
    case groq
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .groq: return "Groq"
        case .deepseek: return "DeepSeek"
        }
    }

    var needsAPIKey: Bool { true }

    var keychainKey: String {
        switch self {
        case .anthropic: return SecretKey.anthropic
        case .openai: return SecretKey.openai
        case .gemini: return SecretKey.gemini
        case .groq: return SecretKey.groq
        case .deepseek: return SecretKey.deepseek
        }
    }

    var defaultFastModel: String {
        switch self {
        case .anthropic: return "claude-haiku-4-5"
        case .openai: return "gpt-4o-mini"
        case .gemini: return "gemini-2.5-flash"
        case .groq: return "llama-3.1-8b-instant"
        case .deepseek: return "deepseek-chat"
        }
    }

    var defaultSmartModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-5"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.5-pro"
        case .groq: return "llama-3.3-70b-versatile"
        case .deepseek: return "deepseek-reasoner"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .gemini: return "AIza…"
        case .groq: return "gsk_…"
        case .deepseek: return "sk-…"
        }
    }

    /// `true` when this provider speaks the OpenAI chat-completions shape.
    var isOpenAICompatible: Bool { self != .anthropic }

    func defaultBaseURL() -> String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .groq: return "https://api.groq.com/openai/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        }
    }

    /// A provider is usable if its key is stored.
    func isConnected() -> Bool {
        Keychain.read(keychainKey) != nil
    }

    /// Fetch the list of model IDs this provider/key can use, so the user picks
    /// from a list instead of typing. Returns a sorted, de-duplicated list.
    func availableModels(apiKey: String) async throws -> [String] {
        let base = defaultBaseURL()
        var req: URLRequest
        switch self {
        case .anthropic:
            req = URLRequest(url: URL(string: "\(base)/models")!)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai, .gemini, .groq, .deepseek:
            req = URLRequest(url: URL(string: "\(base)/models")!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decode("model list not an object")
        }
        var ids: [String] = []
        for m in (obj["data"] as? [[String: Any]] ?? []) {
            if var id = m["id"] as? String {
                // Gemini prefixes ids with "models/" — strip for the API.
                if id.hasPrefix("models/") { id = String(id.dropFirst("models/".count)) }
                ids.append(id)
            }
        }
        return Array(Set(ids)).sorted()
    }

    /// Build a provider that uses `model` for both tiers (each Sift task maps to
    /// one provider+model, so the tier the call site passes is irrelevant).
    func makeProvider(apiKey: String, model: String) -> LLMProvider {
        if self == .anthropic {
            return AnthropicClient(apiKey: apiKey, fastModel: model, smartModel: model)
        }
        return OpenAICompatibleClient(
            apiKey: apiKey,
            baseURL: defaultBaseURL(),
            fastModel: model,
            smartModel: model
        )
    }
}

/// Routes the two Sift task tiers (fast / smart) to their assigned provider +
/// model, which may live on different providers.
struct RoutingLLM: LLMProvider {
    let fast: LLMProvider
    let smart: LLMProvider

    func send(tier: LLMTier, system: String, userMessage: String, maxTokens: Int?, temperature: Double) async throws -> String {
        let p = tier == .fast ? fast : smart
        return try await p.send(tier: tier, system: system, userMessage: userMessage, maxTokens: maxTokens, temperature: temperature)
    }
}
