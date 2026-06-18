import SwiftUI
import AppKit

// MARK: - Request

/// What the thread sheet needs to open: the channel + parent ts to fetch, a
/// label for the header, and the Slack permalink for the "Open in Slack" button.
/// Holds no token — the loader reads that from Keychain when it fetches.
struct ThreadSheetRequest: Identifiable, Equatable {
    let id = UUID()
    let channelID: String
    let parentTs: String
    let title: String
    let slackURL: URL?
}

// MARK: - Rendered message

struct ThreadMessage: Identifiable {
    let id: String          // Slack ts
    let date: Date?
    let authorName: String
    let avatarURL: URL?
    let text: AttributedString
    let reactions: [SlackClient.Message.Reaction]
    /// True when this message starts a new author block (show avatar + name).
    let startsGroup: Bool
}

// MARK: - Loader

/// Fetches a thread's replies and resolves every referenced user into a name +
/// avatar, then renders each message's Slack markdown into an AttributedString.
/// Live-fetches on open (one `conversations.replies` call + cached user lookups)
/// rather than caching messages, so the thread is always current.
@MainActor
final class ThreadLoader: ObservableObject {
    @Published var messages: [ThreadMessage] = []
    @Published var loading = true
    @Published var error: String?

    private let channelID: String
    private let parentTs: String

    init(channelID: String, parentTs: String) {
        self.channelID = channelID
        self.parentTs = parentTs
    }

    func load() async {
        loading = true
        error = nil
        guard let token = Keychain.read(SecretKey.slack) else {
            error = "Slack isn't connected."
            loading = false
            return
        }
        let client = SlackClient(token: token)
        do {
            let raw = try await fetchThread(client)

            // Resolve every user we'll need: message authors plus anyone @-mentioned
            // in the bodies. Lookups are independent, so fan them out.
            let authorIDs = raw.compactMap(\.user)
            let mentionedIDs = raw.compactMap(\.text).flatMap(Self.mentionedUserIDs)
            let ids = Set(authorIDs + mentionedIDs)
            var cards: [String: SlackClient.UserCard] = [:]
            await withTaskGroup(of: SlackClient.UserCard?.self) { group in
                for id in ids {
                    group.addTask { try? await client.userCard(userID: id) }
                }
                for await card in group {
                    if let card { cards[card.id] = card }
                }
            }

            let names = cards.mapValues(\.displayName)
            var built: [ThreadMessage] = []
            var prevAuthor: String?
            var prevDate: Date?
            for m in raw {
                let date = SlackClient.dateFromTs(m.ts)
                let card = m.user.flatMap { cards[$0] }
                let author = card?.displayName ?? m.username ?? (m.isFromBot ? "Bot" : "Unknown")
                // Start a new block when the author changes or there's a >5min gap.
                let gap = (prevDate.map { (date ?? .distantPast).timeIntervalSince($0) } ?? .infinity) > 300
                let starts = m.user != prevAuthor || gap
                built.append(ThreadMessage(
                    id: m.ts,
                    date: date,
                    authorName: author,
                    avatarURL: card?.avatarURL,
                    text: SlackText.attributed(m.text ?? "", names: names),
                    reactions: m.reactions ?? [],
                    startsGroup: starts
                ))
                prevAuthor = m.user
                prevDate = date
            }
            messages = built
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    /// Fetch the thread's messages, oldest-first. Mirrors the sync worker:
    /// DMs are flat (replies are new top-level messages, so read history from
    /// the ask onward), and a channel ts can be a reply rather than the root —
    /// `conversations.replies` on a reply ts returns only that one message, so
    /// re-fetch from the real parent when the first message points at one.
    private func fetchThread(_ client: SlackClient) async throws -> [SlackClient.Message] {
        if channelID.hasPrefix("D") {
            let oldest = String(format: "%.6f", (Double(parentTs) ?? 0) - 1)
            let history = try await client.conversationHistory(channelID: channelID, after: oldest)
            return history.sorted { (Double($0.ts) ?? 0) < (Double($1.ts) ?? 0) }
        }
        var replies = try await client.conversationReplies(channelID: channelID, threadTs: parentTs)
        if let root = replies.first?.thread_ts, root != parentTs {
            replies = try await client.conversationReplies(channelID: channelID, threadTs: root)
        }
        return replies
    }

    /// Pull `Uxxxx` / `Wxxxx` user IDs out of `<@U…>` mention tokens.
    static func mentionedUserIDs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<@([UW][A-Z0-9]+)") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Slack markdown → AttributedString

/// A small Slack "mrkdwn" renderer. Handles the constructs that actually show
/// up in threads: `<@U…>` user mentions, `<#C…|name>` channels, `<!here>` and
/// friends, `<url|label>` links, the `*bold* _italic_ ~strike~ \`code\`` wrappers,
/// and `&amp;`/`&lt;`/`&gt;` entities. Emoji shortcodes are left as `:text:`.
enum SlackText {
    static func attributed(_ raw: String, names: [String: String]) -> AttributedString {
        var out = AttributedString()
        var idx = raw.startIndex
        while idx < raw.endIndex {
            if raw[idx] == "<", let close = raw[idx...].firstIndex(of: ">") {
                let inner = String(raw[raw.index(after: idx)..<close])
                out.append(renderAngle(inner, names: names))
                idx = raw.index(after: close)
            } else {
                let next = raw[raw.index(after: idx)...].firstIndex(of: "<") ?? raw.endIndex
                out.append(formatInline(String(raw[idx..<next])))
                idx = next
            }
        }
        return out
    }

    /// Render the contents of a `<…>` token.
    private static func renderAngle(_ inner: String, names: [String: String]) -> AttributedString {
        let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
        let head = parts.first ?? inner
        let label = parts.count > 1 ? parts[1] : nil

        func accented(_ s: String, semibold: Bool = false) -> AttributedString {
            var a = AttributedString(unescape(s))
            a.foregroundColor = .themeAccent
            if semibold { a.inlinePresentationIntent = .stronglyEmphasized }
            return a
        }

        if head.hasPrefix("@") {                       // user mention
            let id = String(head.dropFirst())
            return accented("@" + (label ?? names[id] ?? id), semibold: true)
        }
        if head.hasPrefix("#") {                       // channel reference
            let id = String(head.dropFirst())
            return accented("#" + (label ?? id))
        }
        if head.hasPrefix("!") {                       // broadcast / subteam
            let kw = String(head.dropFirst())
            let shown = label ?? (["here", "channel", "everyone"].contains(kw) ? "@\(kw)" : "@\(kw)")
            return accented(shown, semibold: true)
        }
        // Plain link: head is the URL, label (if any) is the display text.
        var a = AttributedString(unescape(label ?? head))
        a.foregroundColor = .themeAccent
        a.underlineStyle = .single
        if let url = URL(string: head) { a.link = url }
        return a
    }

    /// Apply `*bold*`, `_italic_`, `~strike~`, `\`code\`` to a plain span and
    /// unescape entities. Markers must hug their content (no inner whitespace)
    /// and the opener must sit on a word boundary, so `2 * 3` stays literal.
    private static func formatInline(_ span: String) -> AttributedString {
        let chars = Array(span)
        var out = AttributedString()
        var plain = ""
        var i = 0
        func flush() {
            if !plain.isEmpty { out.append(AttributedString(unescape(plain))); plain = "" }
        }
        while i < chars.count {
            let c = chars[i]
            if let intent = intent(for: c),
               (i == 0 || !chars[i - 1].isLetter && !chars[i - 1].isNumber),
               let close = closer(chars, open: i, marker: c) {
                flush()
                var seg = AttributedString(unescape(String(chars[(i + 1)..<close])))
                seg.inlinePresentationIntent = intent
                out.append(seg)
                i = close + 1
            } else {
                plain.append(c)
                i += 1
            }
        }
        flush()
        return out
    }

    private static func intent(for c: Character) -> InlinePresentationIntent? {
        switch c {
        case "*": return .stronglyEmphasized
        case "_": return .emphasized
        case "~": return .strikethrough
        case "`": return .code
        default: return nil
        }
    }

    /// Index of the matching close marker, or nil if there isn't a well-formed
    /// one (empty content, or whitespace hugging either marker).
    private static func closer(_ chars: [Character], open: Int, marker: Character) -> Int? {
        guard open + 1 < chars.count, !chars[open + 1].isWhitespace else { return nil }
        var j = open + 2
        while j < chars.count {
            if chars[j] == marker, !chars[j - 1].isWhitespace { return j }
            j += 1
        }
        return nil
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Sheet

/// A dimmed overlay hosting a scrollable rendering of a Slack thread: avatars,
/// names, timestamps, formatted text, and reactions. Tap-out or Esc to close.
struct ThreadSheet: View {
    let request: ThreadSheetRequest
    let onClose: () -> Void
    @StateObject private var loader: ThreadLoader
    @EnvironmentObject var settings: AppSettings
    @State private var contentHeight: CGFloat = 0

    /// Keep the sheet comfortably inside the window rather than filling it.
    static let maxWidth: CGFloat = 460
    static let maxBodyHeight: CGFloat = 440

    init(request: ThreadSheetRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _loader = StateObject(wrappedValue: ThreadLoader(channelID: request.channelID, parentTs: request.parentTs))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                bodyContent
            }
            .frame(maxWidth: Self.maxWidth)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.themeCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            )
            .padding(20)
        }
        .task { await loader.load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IntegrationLogoView(logo: .slack, size: 15)
            Text(request.title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let url = request.slackURL {
                SiftButton("Open in Slack", leading: "arrow.right.circle", variant: .secondary) {
                    NSWorkspace.shared.open(url)
                }
            }
            SiftButton(leading: "xmark", variant: .subtle, action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if loader.loading && loader.messages.isEmpty {
            SiftSpinner().frame(maxWidth: .infinity).frame(height: 120)
        } else if let error = loader.error {
            VStack(spacing: 8) {
                LucideIcon(sf: "exclamationmark.circle", size: 22).foregroundStyle(.secondary)
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .padding(.horizontal, 24)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(loader.messages) { msg in
                        ThreadMessageRow(message: msg, redacted: settings.redactionEnabled)
                    }
                }
                .padding(.vertical, 8)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ThreadHeightKey.self, value: proxy.size.height)
                })
            }
            // Hug the content, but never grow past the cap (then it scrolls).
            .frame(height: min(max(contentHeight, 1), Self.maxBodyHeight))
            .onPreferenceChange(ThreadHeightKey.self) { contentHeight = $0 }
        }
    }
}

private struct ThreadMessageRow: View {
    let message: ThreadMessage
    let redacted: Bool

    private var authorName: String {
        redacted ? message.authorName.redactingPII() : message.authorName
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if message.startsGroup {
                ThreadAvatar(url: redacted ? nil : message.avatarURL, name: authorName)
            } else {
                Color.clear.frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                if message.startsGroup {
                    HStack(spacing: 6) {
                        Text(authorName)
                            .font(.system(size: 13, weight: .semibold))
                        if let date = message.date {
                            Text(Self.time(date))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(displayText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .tint(.themeAccent)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.reactions.isEmpty {
                    ThreadReactions(reactions: message.reactions)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, message.startsGroup ? 10 : 2)
        .padding(.bottom, 2)
    }

    /// When redaction is on, replace the rendered text with a plain redacted
    /// string so screenshots stay clean.
    private var displayText: AttributedString {
        guard redacted else { return message.text }
        return AttributedString(String(message.text.characters).redactingPII())
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "MMM d, h:mm a"
        return f.string(from: d)
    }
}

private struct ThreadReactions: View {
    let reactions: [SlackClient.Message.Reaction]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.name) { r in
                HStack(spacing: 3) {
                    Text(Emoji.render(r.name)).font(.system(size: 11))
                    Text("\(r.count ?? r.users?.count ?? 1)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.1)))
            }
        }
        .padding(.top, 2)
    }
}

/// Height of the scrollable message list, so the sheet can hug short threads.
private struct ThreadHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Maps common Slack reaction shortcodes to their Unicode emoji. Strips skin-
/// tone modifiers (`::skin-tone-3`); unknown or custom emoji fall back to the
/// `:name:` shortcode so nothing silently vanishes.
enum Emoji {
    static func render(_ name: String) -> String {
        let base = name.components(separatedBy: "::").first ?? name
        return map[base] ?? ":\(base):"
    }

    private static let map: [String: String] = [
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "ballot_box_with_check": "☑️",
        "x": "❌", "heavy_multiplication_x": "✖️", "negative_squared_cross_mark": "❎",
        "tada": "🎉", "confetti_ball": "🎊", "pray": "🙏", "raised_hands": "🙌", "clap": "👏",
        "fire": "🔥", "100": "💯", "rocket": "🚀", "sparkles": "✨", "star": "⭐", "star2": "🌟",
        "eyes": "👀", "thinking_face": "🤔", "muscle": "💪", "ok_hand": "👌", "handshake": "🤝",
        "wave": "👋", "raised_hand": "✋", "point_up": "☝️", "point_up_2": "👆", "point_down": "👇",
        "point_right": "👉", "point_left": "👈", "crossed_fingers": "🤞", "saluting_face": "🫡",
        "heart": "❤️", "orange_heart": "🧡", "yellow_heart": "💛", "green_heart": "💚",
        "blue_heart": "💙", "purple_heart": "💜", "black_heart": "🖤", "white_heart": "🤍",
        "heart_hands": "🫶", "smile": "😄", "smiley": "😃", "grin": "😁", "joy": "😂", "rofl": "🤣",
        "sweat_smile": "😅", "blush": "😊", "wink": "😉", "upside_down_face": "🙃", "slightly_smiling_face": "🙂",
        "heart_eyes": "😍", "star_struck": "🤩", "sunglasses": "😎", "partying_face": "🥳",
        "hugging_face": "🤗", "thinking": "🤔", "shrug": "🤷", "facepalm": "🤦", "grimacing": "😬",
        "pleading_face": "🥺", "cry": "😢", "sob": "😭", "rage": "😡", "scream": "😱",
        "exploding_head": "🤯", "skull": "💀", "melting_face": "🫠", "salute": "🫡",
        "warning": "⚠️", "exclamation": "❗", "heavy_exclamation_mark": "❗", "question": "❓",
        "bulb": "💡", "bug": "🐛", "zap": "⚡", "dart": "🎯", "pushpin": "📌", "memo": "📝",
        "pencil": "✏️", "mag": "🔍", "lock": "🔒", "key": "🔑", "bell": "🔔", "mega": "📣",
        "speech_balloon": "💬", "robot_face": "🤖", "ok": "🆗", "new": "🆕",
        "red_circle": "🔴", "large_blue_circle": "🔵", "green_circle": "🟢", "large_green_circle": "🟢",
        "yellow_circle": "🟡", "large_yellow_circle": "🟡", "white_circle": "⚪", "black_circle": "⚫",
        "coffee": "☕", "beers": "🍻", "pizza": "🍕", "birthday": "🎂", "money_with_wings": "💸",
        "boom": "💥", "snail": "🐌", "turtle": "🐢", "hourglass": "⌛", "alarm_clock": "⏰",
    ]
}

/// Square, slightly-rounded avatar (Slack style) with an initial placeholder
/// while the image loads or when the user has none.
private struct ThreadAvatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color.secondary.opacity(0.18))
            .overlay(
                Text(name.first.map(String.init)?.uppercased() ?? "?")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.secondary)
            )
    }
}

extension View {
    /// Presents a `ThreadSheet` over this view while `request` is non-nil.
    func siftThreadSheet(_ request: Binding<ThreadSheetRequest?>) -> some View {
        overlay {
            if let req = request.wrappedValue {
                ThreadSheet(request: req) { request.wrappedValue = nil }
                    .id(req.id)
            }
        }
    }
}
