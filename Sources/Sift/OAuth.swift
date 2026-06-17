import Foundation
import AppKit

/// Coordinates the Slack OAuth handshake. The Mac app opens the worker's
/// `/oauth/slack/start` URL in the user's default browser, then waits for a
/// `sift://oauth/slack` callback from the AppDelegate's URL handler.
@MainActor
final class OAuthCoordinator: ObservableObject {
    static let shared = OAuthCoordinator()

    @Published private(set) var pendingState: String?
    @Published var lastResult: Result?
    @Published var inProgress: Bool = false

    struct Result {
        let token: String
        let userID: String
        let userName: String
        let teamID: String
        let teamName: String
    }

    enum OAuthError: LocalizedError {
        case stateMismatch
        case missingToken
        case userCancelled

        var errorDescription: String? {
            switch self {
            case .stateMismatch: return "OAuth state mismatch — possible CSRF attempt. Try again."
            case .missingToken: return "OAuth callback was missing a token."
            case .userCancelled: return "OAuth flow was cancelled."
            }
        }
    }

    /// Kick off the OAuth flow. Opens the user's browser.
    func start() {
        let state = UUID().uuidString
        pendingState = state
        inProgress = true
        NSWorkspace.shared.open(Config.slackOAuthStartURL(state: state))
    }

    /// Cancel a pending flow (e.g. user clicked Cancel in the UI).
    func cancel() {
        pendingState = nil
        inProgress = false
    }

    /// Process a URL callback delivered via the custom URL scheme. Returns the
    /// extracted result on success, throws on failure.
    func handleCallback(_ url: URL) throws -> Result {
        defer {
            pendingState = nil
            inProgress = false
        }

        // The token is in the URL fragment (`#token=…&user_id=…`) so it
        // doesn't appear in browser referer chains.
        let fragment = url.fragment ?? ""
        var items: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0) }
            guard parts.count == 2 else { continue }
            let key = parts[0].removingPercentEncoding ?? parts[0]
            let value = parts[1].removingPercentEncoding ?? parts[1]
            items[key] = value
        }

        let state = items["state"] ?? ""
        if let pending = pendingState, pending != state {
            throw OAuthError.stateMismatch
        }

        guard let token = items["token"], !token.isEmpty else {
            throw OAuthError.missingToken
        }

        let result = Result(
            token: token,
            userID: items["user_id"] ?? "",
            userName: items["user_name"] ?? "",
            teamID: items["team_id"] ?? "",
            teamName: items["team_name"] ?? ""
        )
        lastResult = result
        return result
    }
}
