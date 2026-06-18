import Foundation

/// Thin wrapper over the Slack Web API. Uses a user token (xoxp-…) since we
/// want to read DMs and channels the user is in. The token is provided once
/// during onboarding and stored in Keychain.
actor SlackClient {
    enum SlackError: LocalizedError {
        case missingToken
        case http(Int, String)
        case apiError(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingToken: return "Slack token not configured."
            case .http(let c, let body): return "Slack HTTP \(c): \(body.prefix(200))"
            case .apiError(let s): return "Slack API: \(s)"
            case .decode(let s): return "Slack decode: \(s)"
            }
        }
    }

    private let token: String
    private let base = URL(string: "https://slack.com/api")!

    init(token: String) { self.token = token }

    // MARK: - API surface used by the worker

    struct Message: Decodable, Hashable {
        let ts: String
        let user: String?
        let text: String?
        let thread_ts: String?
        let parent_user_id: String?
        let subtype: String?
        let bot_id: String?
        let username: String?
        let reactions: [Reaction]?

        struct Reaction: Decodable, Hashable {
            let name: String
            let users: [String]?
            let count: Int?
        }

        var isFromBot: Bool { bot_id != nil || subtype == "bot_message" }
        var threadParentTs: String { thread_ts ?? ts }
    }

    struct SearchMatch: Decodable, Hashable {
        let ts: String
        let user: String?
        let text: String?
        let channel: SearchChannel
        let permalink: URL?
        /// Present when the match is a thread reply.
        let thread_ts: String?

        struct SearchChannel: Decodable, Hashable {
            let id: String
            let name: String?
        }

        /// The parent ts of the thread the match belongs to. Same as `ts`
        /// when the match itself IS the parent.
        var threadParentTs: String { thread_ts ?? ts }
    }

    /// Find messages mentioning the user's @handle after the given Slack ts.
    func searchMentions(handle: String, after slackTs: String?) async throws -> [SearchMatch] {
        let afterDate = slackTs.flatMap { Self.dateString(forSlackTs: $0, minusDays: 1) }
        let query = afterDate.map { "@\(handle) after:\($0)" } ?? "@\(handle)"
        let params: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "sort", value: "timestamp"),
            URLQueryItem(name: "sort_dir", value: "desc"),
            URLQueryItem(name: "count", value: "25"),
        ]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let messages: Container?
            struct Container: Decodable { let matches: [SearchMatch]? }
        }
        let resp: Resp = try await get("search.messages", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        return resp.messages?.matches ?? []
    }

    /// Find messages authored by the user since the given Slack ts. Used to
    /// surface threads the user is participating in but might not have a fresh
    /// @mention.
    func searchMessagesFromUser(handle: String, after slackTs: String?) async throws -> [SearchMatch] {
        let afterDate = slackTs.flatMap { Self.dateString(forSlackTs: $0, minusDays: 1) }
        let query = afterDate.map { "from:@\(handle) after:\($0)" } ?? "from:@\(handle)"
        let params: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "sort", value: "timestamp"),
            URLQueryItem(name: "sort_dir", value: "desc"),
            URLQueryItem(name: "count", value: "50"),
        ]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let messages: Container?
            struct Container: Decodable { let matches: [SearchMatch]? }
        }
        let resp: Resp = try await get("search.messages", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        return resp.messages?.matches ?? []
    }

    /// Top-level history for a channel since a given Slack ts.
    func conversationHistory(channelID: String, after slackTs: String?) async throws -> [Message] {
        var params: [URLQueryItem] = [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "limit", value: "30"),
        ]
        if let s = slackTs { params.append(URLQueryItem(name: "oldest", value: s)) }
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let messages: [Message]?
        }
        let resp: Resp = try await get("conversations.history", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        return resp.messages ?? []
    }

    /// Full thread replies for a parent ts.
    func conversationReplies(channelID: String, threadTs: String) async throws -> [Message] {
        let params: [URLQueryItem] = [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "ts", value: threadTs),
            URLQueryItem(name: "limit", value: "200"),
        ]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let messages: [Message]?
        }
        let resp: Resp = try await get("conversations.replies", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        return resp.messages ?? []
    }

    /// Fetch the full profile for a user — display name + email. Used during
    /// onboarding to auto-populate identity fields.
    func userProfile(userID: String) async throws -> Profile {
        let params: [URLQueryItem] = [URLQueryItem(name: "user", value: userID)]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let user: User?
            struct User: Decodable {
                let real_name: String?
                let name: String?
                let profile: ProfileDTO?
                struct ProfileDTO: Decodable {
                    let display_name: String?
                    let real_name: String?
                    let email: String?
                }
            }
        }
        let resp: Resp = try await get("users.info", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        let name = resp.user?.profile?.real_name
            ?? resp.user?.real_name
            ?? resp.user?.profile?.display_name
            ?? resp.user?.name
            ?? ""
        let email = resp.user?.profile?.email ?? ""
        return Profile(displayName: name, email: email)
    }

    struct Profile {
        let displayName: String
        let email: String
    }

    /// Resolve a user ID into a display name.
    func userDisplayName(userID: String) async throws -> String {
        let params: [URLQueryItem] = [URLQueryItem(name: "user", value: userID)]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let user: User?
            struct User: Decodable {
                let real_name: String?
                let name: String?
                let profile: Profile?
                struct Profile: Decodable {
                    let display_name: String?
                    let real_name: String?
                }
            }
        }
        let resp: Resp = try await get("users.info", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        return resp.user?.profile?.display_name
            ?? resp.user?.profile?.real_name
            ?? resp.user?.real_name
            ?? resp.user?.name
            ?? userID
    }

    struct UserCard: Hashable {
        let id: String
        let displayName: String
        let avatarURL: URL?
    }

    /// Display name + avatar for rendering a message author in the thread view.
    func userCard(userID: String) async throws -> UserCard {
        let params: [URLQueryItem] = [URLQueryItem(name: "user", value: userID)]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let user: User?
            struct User: Decodable {
                let real_name: String?
                let name: String?
                let profile: Profile?
                struct Profile: Decodable {
                    let display_name: String?
                    let real_name: String?
                    let image_72: String?
                    let image_48: String?
                }
            }
        }
        let resp: Resp = try await get("users.info", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        func pick(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
        let name = pick(resp.user?.profile?.display_name)
            ?? pick(resp.user?.profile?.real_name)
            ?? pick(resp.user?.real_name)
            ?? pick(resp.user?.name)
            ?? userID
        let img = (resp.user?.profile?.image_72 ?? resp.user?.profile?.image_48)
            .flatMap { URL(string: $0) }
        return UserCard(id: userID, displayName: name, avatarURL: img)
    }

    struct UserIdentity {
        let email: String?
        let teamID: String?
        let isGuest: Bool
    }

    /// Email, home team, and guest flag for a user — used to tell internal
    /// colleagues from external contacts and to derive their company.
    func userIdentity(userID: String) async throws -> UserIdentity {
        let params: [URLQueryItem] = [URLQueryItem(name: "user", value: userID)]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let user: User?
            struct User: Decodable {
                let team_id: String?
                let is_restricted: Bool?
                let is_ultra_restricted: Bool?
                let profile: Profile?
                struct Profile: Decodable { let email: String? }
            }
        }
        let resp: Resp = try await get("users.info", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        return UserIdentity(
            email: resp.user?.profile?.email,
            teamID: resp.user?.team_id,
            isGuest: (resp.user?.is_restricted ?? false) || (resp.user?.is_ultra_restricted ?? false)
        )
    }

    /// Resolve the authenticated user's identity. Used during onboarding to
    /// confirm the token works and to capture the user's Slack user ID.
    func authTest() async throws -> AuthInfo {
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let user: String?
            let user_id: String?
            let team: String?
            let team_id: String?
        }
        let resp: Resp = try await get("auth.test", [])
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        return AuthInfo(
            userID: resp.user_id ?? "",
            userName: resp.user ?? "",
            teamID: resp.team_id ?? "",
            teamName: resp.team ?? ""
        )
    }

    struct AuthInfo {
        let userID: String
        let userName: String
        let teamID: String
        let teamName: String
    }

    /// Construct a deep-link permalink for a thread reply, including the
    /// thread_ts/cid query params so Slack opens the sidebar.
    func chatPermalink(channelID: String, messageTs: String) async throws -> URL? {
        let params: [URLQueryItem] = [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "message_ts", value: messageTs),
        ]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let permalink: URL?
        }
        let resp: Resp = try await get("chat.getPermalink", params)
        if !resp.ok { return nil }
        return resp.permalink
    }

    /// Channel name lookup (cache externally if calling repeatedly).
    func conversationInfo(channelID: String) async throws -> ConversationInfo {
        let params: [URLQueryItem] = [URLQueryItem(name: "channel", value: channelID)]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let channel: Channel?
            struct Channel: Decodable {
                let id: String
                let name: String?
                let is_im: Bool?
                let is_mpim: Bool?
                let user: String?
            }
        }
        let resp: Resp = try await get("conversations.info", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        let ch = resp.channel
        return ConversationInfo(
            id: ch?.id ?? channelID,
            name: ch?.name ?? "(direct message)",
            isDM: ch?.is_im == true,
            isGroupDM: ch?.is_mpim == true,
            dmPartnerUserID: ch?.is_im == true ? ch?.user : nil
        )
    }

    /// Fetch member user IDs for a conversation (used for group DM name resolution).
    func conversationMembers(channelID: String) async throws -> [String] {
        let params: [URLQueryItem] = [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "limit", value: "20"),
        ]
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let members: [String]?
        }
        let resp: Resp = try await get("conversations.members", params)
        if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
        return resp.members ?? []
    }

    struct ConversationInfo: Hashable {
        let id: String
        let name: String
        let isDM: Bool
        let isGroupDM: Bool
        let dmPartnerUserID: String?
    }

    struct Channel: Decodable, Hashable, Identifiable {
        let id: String
        let name: String?
        let is_private: Bool?
        let is_archived: Bool?
        let is_member: Bool?
    }

    /// Every public channel in the workspace, plus private channels the user
    /// is a member of. Paginates through every page so the caller can filter
    /// in-memory. Excludes archived channels and DMs.
    ///
    /// Uses `conversations.list` rather than `users.conversations` so the
    /// caller can pick aggregator channels they're @-mentioned in but not a
    /// member of (the common case for the Ignored list).
    func listChannels() async throws -> [Channel] {
        var all: [Channel] = []
        var cursor: String? = nil
        // Cap at 20 pages (20k channels) so a massive workspace can't hang
        // the picker indefinitely. The user can still type to filter; they
        // just won't have the very long tail of rarely-used channels.
        var pages = 0
        repeat {
            var params: [URLQueryItem] = [
                URLQueryItem(name: "types", value: "public_channel,private_channel"),
                URLQueryItem(name: "exclude_archived", value: "true"),
                URLQueryItem(name: "limit", value: "1000"),
            ]
            if let c = cursor, !c.isEmpty {
                params.append(URLQueryItem(name: "cursor", value: c))
            }
            struct Resp: Decodable {
                let ok: Bool
                let error: String?
                let channels: [Channel]?
                let response_metadata: Meta?
                struct Meta: Decodable { let next_cursor: String? }
            }
            let resp: Resp = try await get("conversations.list", params)
            if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
            all.append(contentsOf: resp.channels ?? [])
            let next = resp.response_metadata?.next_cursor ?? ""
            cursor = next.isEmpty ? nil : next
            pages += 1
        } while cursor != nil && pages < 20
        return all
    }

    struct DMChannel {
        let id: String
        let userID: String?   // the other person (nil for group DMs)
        let isGroup: Bool
    }

    /// List the user's open DMs and group DMs. Requires `im:read` / `mpim:read`.
    func listDMs() async throws -> [DMChannel] {
        var all: [DMChannel] = []
        var cursor: String? = nil
        var pages = 0
        repeat {
            var params: [URLQueryItem] = [
                URLQueryItem(name: "types", value: "im,mpim"),
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let c = cursor, !c.isEmpty {
                params.append(URLQueryItem(name: "cursor", value: c))
            }
            struct C: Decodable { let id: String; let user: String?; let is_mpim: Bool? }
            struct Resp: Decodable {
                let ok: Bool
                let error: String?
                let channels: [C]?
                let response_metadata: Meta?
                struct Meta: Decodable { let next_cursor: String? }
            }
            let resp: Resp = try await get("conversations.list", params)
            if !resp.ok { throw SlackError.apiError(resp.error ?? "unknown") }
            all.append(contentsOf: (resp.channels ?? []).map {
                DMChannel(id: $0.id, userID: $0.user, isGroup: $0.is_mpim == true)
            })
            let next = resp.response_metadata?.next_cursor ?? ""
            cursor = next.isEmpty ? nil : next
            pages += 1
        } while cursor != nil && pages < 10
        return all
    }

    // MARK: - HTTP plumbing

    private func get<T: Decodable>(_ path: String, _ params: [URLQueryItem]) async throws -> T {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = params
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SlackError.http(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw SlackError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SlackError.decode("\(error) — \(String(data: data, encoding: .utf8) ?? "")")
        }
    }

    // MARK: - ts helpers

    /// Convert a Slack ts (e.g. "1778634214.777449") into a date.
    static func dateFromTs(_ ts: String) -> Date? {
        guard let interval = Double(ts) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// Render a Slack ts as YYYY-MM-DD for search queries. `minusDays` backs the
    /// date up — Slack's `after:` operator EXCLUDES the named day, so to include
    /// the cursor's own day (and absorb UTC-vs-local-tz drift) we name the day
    /// before. Exact-ts dedup downstream prevents the wider window re-ingesting.
    static func dateString(forSlackTs ts: String, minusDays days: Int = 0) -> String? {
        guard let base = dateFromTs(ts) else { return nil }
        let d = days == 0 ? base : base.addingTimeInterval(TimeInterval(-days) * 86400)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Build a thread-sidebar deep link manually (fallback when chat.getPermalink
    /// fails).
    static func threadDeepLink(workspaceDomain: String,
                               channelID: String,
                               messageTs: String,
                               parentTs: String) -> URL? {
        let tsNoDot = messageTs.replacingOccurrences(of: ".", with: "")
        let url = "https://\(workspaceDomain).slack.com/archives/\(channelID)/p\(tsNoDot)?thread_ts=\(parentTs)&cid=\(channelID)"
        return URL(string: url)
    }
}
