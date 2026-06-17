import Foundation
import Security

/// Tiny wrapper around macOS Keychain for storing user secrets (API tokens).
/// Secrets never touch disk in plaintext.
enum Keychain {
    static let service = "Sift"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

enum SecretKey {
    static let anthropic = "AnthropicAPIKey"
    static let openai = "OpenAIAPIKey"
    static let groq = "GroqAPIKey"
    static let gemini = "GeminiAPIKey"
    static let deepseek = "DeepSeekAPIKey"
    static let slack = "SlackUserToken"
    static let granola = "GranolaAPIKey"
}
