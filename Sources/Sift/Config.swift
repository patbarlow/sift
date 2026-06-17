import Foundation

/// Build-time configuration. The OAuth worker URL is the only thing per
/// deployment — everything else (Slack scopes, client ID) lives in the worker.
enum Config {
    /// Cloudflare Worker base URL. Override at runtime via `SIFT_OAUTH_BASE`
    /// env var for development against a local `wrangler dev` instance.
    static var oauthWorkerBaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["SIFT_OAUTH_BASE"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://sift-oauth.pat-barlow.workers.dev")!
    }

    /// Custom URL scheme this app handles. Must match `CFBundleURLTypes` in
    /// Info.plist and the `APP_URL_SCHEME` var on the worker.
    static let urlScheme = "sift"

    /// Build the Slack OAuth start URL on the worker with a random state token.
    static func slackOAuthStartURL(state: String) -> URL {
        var comps = URLComponents(url: oauthWorkerBaseURL.appendingPathComponent("/oauth/slack/start"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "state", value: state)]
        return comps.url!
    }
}
