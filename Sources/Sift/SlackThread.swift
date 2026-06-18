import SwiftUI
import AppKit

// MARK: - Rendered message

/// A block of a rendered message — Slack messages mix normal paragraphs, block
/// quotes (`>`), and fenced code (```` ``` ````).
enum SlackBlock: Hashable {
    case paragraph(AttributedString)
    case quote(AttributedString)
    case code(String)
}

struct ThreadMessage: Identifiable {
    let id: String          // Slack ts
    let date: Date?
    let authorName: String
    let avatarURL: URL?
    let blocks: [SlackBlock]
    let rawText: String     // unrendered original, used for the redacted view
    let reactions: [ThreadReaction]
    /// True when this message starts a new author block (show avatar + name).
    let startsGroup: Bool
}

/// A reaction resolved for display: Unicode for standard emoji, an image URL for
/// custom ones, or neither (render the `:name:` shortcode).
struct ThreadReaction: Identifiable, Hashable {
    let name: String
    let count: Int
    let unicode: String?
    let imageURL: URL?
    var id: String { name }
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

    /// Workspace custom emoji (name → image URL). Workspace-wide and stable, so
    /// fetch once per app run and reuse across threads.
    private static var emojiCatalog: [String: URL]?

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

            // Custom emoji catalog (cached after the first fetch). Empty if the
            // token lacks emoji:read — reactions then fall back to shortcodes.
            let emoji: [String: URL]
            if let cached = Self.emojiCatalog {
                emoji = cached
            } else {
                emoji = (try? await client.customEmoji()) ?? [:]
                Self.emojiCatalog = emoji
            }

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
                    blocks: SlackText.blocks(m.text ?? "", names: names),
                    rawText: m.text ?? "",
                    reactions: (m.reactions ?? []).map { r in
                        let base = r.name.components(separatedBy: "::").first ?? r.name
                        return ThreadReaction(
                            name: base,
                            count: r.count ?? r.users?.count ?? 1,
                            unicode: Emoji.unicode(base),
                            imageURL: emoji[base]
                        )
                    },
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
    /// Split a message into block-level pieces: fenced code, block quotes, and
    /// normal paragraphs (inline-formatted). Code is left raw; everything else
    /// runs through the inline renderer.
    static func blocks(_ raw: String, names: [String: String]) -> [SlackBlock] {
        var blocks: [SlackBlock] = []
        // ``` fences toggle code on/off, so odd-indexed segments are code.
        for (i, segment) in raw.components(separatedBy: "```").enumerated() {
            if i % 2 == 1 {
                let code = segment.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                if !code.isEmpty { blocks.append(.code(unescape(code))) }
            } else {
                appendTextBlocks(segment, names: names, into: &blocks)
            }
        }
        return blocks
    }

    /// Group consecutive `>`-quoted lines into quote blocks; the rest become
    /// paragraph blocks (newlines preserved within each).
    private static func appendTextBlocks(_ text: String, names: [String: String], into blocks: inout [SlackBlock]) {
        var para: [String] = []
        var quote: [String] = []
        func flushPara() {
            let joined = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(attributed(joined, names: names))) }
            para.removeAll()
        }
        func flushQuote() {
            let joined = quote.joined(separator: "\n")
            if !joined.isEmpty { blocks.append(.quote(attributed(joined, names: names))) }
            quote.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let quoted = quoteContent(line) {
                flushPara()
                quote.append(quoted)
            } else {
                flushQuote()
                para.append(line)
            }
        }
        flushPara()
        flushQuote()
    }

    /// The content of a `>`/`&gt;` quote line, or nil if the line isn't a quote.
    private static func quoteContent(_ line: String) -> String? {
        let trimmed = line.drop { $0 == " " }
        for marker in ["&gt;", ">"] where trimmed.hasPrefix(marker) {
            var rest = trimmed.dropFirst(marker.count)
            if rest.first == " " { rest = rest.dropFirst() }
            return String(rest)
        }
        return nil
    }

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
            if !plain.isEmpty { out.append(AttributedString(emojify(unescape(plain)))); plain = "" }
        }
        while i < chars.count {
            let c = chars[i]
            if let intent = intent(for: c),
               (i == 0 || !chars[i - 1].isLetter && !chars[i - 1].isNumber),
               let close = closer(chars, open: i, marker: c) {
                flush()
                let inner = unescape(String(chars[(i + 1)..<close]))
                // Don't emojify inside inline code — it's meant to be literal.
                var seg = AttributedString(intent == .code ? inner : emojify(inner))
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

    /// Replace `:shortcode:` with its Unicode emoji where known; custom or
    /// unrecognised codes are left as-is (they need the `emoji:read` scope).
    private static func emojify(_ s: String) -> String {
        guard s.contains(":"),
              let regex = try? NSRegularExpression(pattern: ":([a-zA-Z0-9_'+-]+):") else { return s }
        var result = s
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let full = Range(match.range, in: result),
                  let nameR = Range(match.range(at: 1), in: result),
                  let unicode = Emoji.unicode(String(result[nameR])) else { continue }
            result.replaceSubrange(full, with: unicode)
        }
        return result
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Detail sheet

/// A dimmed overlay hosting the focused single-todo view, in one column: title,
/// summary, properties (priority, recent activity, merged sources), then the
/// Slack thread in its own container. Tap-out or Esc to close.
struct TodoDetailSheet: View {
    let todo: Todo
    let onClose: () -> Void
    @StateObject private var loader: ThreadLoader
    @EnvironmentObject var settings: AppSettings
    @State private var contentHeight: CGFloat = 0

    /// Keep the sheet inside the window, and let it hug short content. The body
    /// (everything below the fixed title) scrolls past `maxBodyHeight`;
    /// `headerReserve` approximates the title header for the top-pin maths.
    static let maxWidth: CGFloat = 544
    static let maxBodyHeight: CGFloat = 560
    static let headerReserve: CGFloat = 64

    init(todo: Todo, onClose: @escaping () -> Void) {
        self.todo = todo
        self.onClose = onClose
        let parts = todo.threadKey.split(separator: ":", maxSplits: 1).map(String.init)
        _loader = StateObject(wrappedValue: ThreadLoader(
            channelID: parts.first ?? todo.channelID,
            parentTs: parts.count > 1 ? parts[1] : ""
        ))
    }

    private var isSlack: Bool { todo.sourceKind != .granola }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            // Pin the card's top to where it sits at max height, so a shorter
            // todo only moves its bottom edge — switching todos loads and
            // expands downward instead of growing from the middle.
            GeometryReader { geo in
                card
                    .frame(maxWidth: Self.maxWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                    // Keep a margin off the window edges as it shrinks on resize.
                    .padding(.horizontal, 16)
                    .padding(.top, topInset(geo.size.height))
            }

            // No visible close button, so keep Esc working via a hidden one.
            Button("", action: onClose)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task { if isSlack { await loader.load() } }
    }

    /// Top margin that keeps the card's top edge fixed regardless of content
    /// height (centred as if it were at its maximum size).
    private func topInset(_ available: CGFloat) -> CGFloat {
        max(16, (available - Self.maxBodyHeight - Self.headerReserve) / 2)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            scrollBody
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.themeCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        )
    }

    /// Fixed header: just the title (up to two lines, then truncated), centred
    /// vertically. Closing is via click-outside or Esc — no close button.
    private var header: some View {
        Text(todo.title.redacting(settings.redactionEnabled))
            .font(.system(size: 16, weight: .semibold, design: settings.theme.fontDesign))
            .foregroundStyle(Color.primary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
    }

    /// Everything below the fixed title scrolls.
    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !todo.summary.isEmpty {
                    Text(todo.displaySummary.redacting(settings.redactionEnabled))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DetailPanel(todo: todo)
                if isSlack { threadContainer } else { granolaNote }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ThreadHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(height: min(max(contentHeight, 1), Self.maxBodyHeight))
        .onPreferenceChange(ThreadHeightKey.self) { contentHeight = $0 }
    }

    private var granolaNote: some View {
        Text("This item came from a Granola note — use the source to view it.")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The Slack thread in its own rounded container: a header (channel name +
    /// Open in Slack) over the messages.
    private var threadContainer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                IntegrationLogoView(logo: .slack, size: 14)
                Text(todo.channelName.redacting(settings.redactionEnabled))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let url = todo.sourceURL {
                    SiftButton(variant: .secondary) { NSWorkspace.shared.open(url) } content: {
                        HStack(spacing: 5) {
                            IntegrationLogoView(logo: .slack, size: 13)
                            Text("Open in Slack").lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().opacity(0.5)
            threadBody
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var threadBody: some View {
        if loader.loading && loader.messages.isEmpty {
            HStack { Spacer(); SiftSpinner(); Spacer() }.frame(height: 80)
        } else if let error = loader.error {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn’t load the thread").font(.system(size: 12, weight: .medium))
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(loader.messages) { msg in
                    ThreadMessageRow(message: msg, redacted: settings.redactionEnabled)
                }
            }
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
                if redacted {
                    Text(message.rawText.redactingPII())
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SlackBlocksView(blocks: message.blocks)
                }
                if !message.reactions.isEmpty {
                    ThreadReactions(reactions: message.reactions)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, message.startsGroup ? 10 : 2)
        .padding(.bottom, 2)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "MMM d, h:mm a"
        return f.string(from: d)
    }
}

/// Renders a message's blocks: paragraphs, quote bars, and code boxes.
private struct SlackBlocksView: View {
    let blocks: [SlackBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .tint(.themeAccent)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .quote(let text):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .tint(.themeAccent)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
            }
        }
    }
}

private struct ThreadReactions: View {
    let reactions: [ThreadReaction]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { r in
                HStack(spacing: 3) {
                    glyph(r)
                    Text("\(r.count)")
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

    @ViewBuilder
    private func glyph(_ r: ThreadReaction) -> some View {
        if let unicode = r.unicode {
            Text(unicode).font(.system(size: 11))
        } else if let url = r.imageURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(width: 14, height: 14)
        } else {
            Text(":\(r.name):").font(.system(size: 10))
        }
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
    /// Unicode for a shortcode (skin-tone modifier stripped), or nil if unknown.
    static func unicode(_ name: String) -> String? {
        map[name.components(separatedBy: "::").first ?? name]
    }

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
    /// Presents the focused `TodoDetailSheet` while `todo` is non-nil.
    func siftTodoDetail(_ todo: Binding<Todo?>) -> some View {
        overlay {
            if let t = todo.wrappedValue {
                TodoDetailSheet(todo: t) { todo.wrappedValue = nil }
                    .id(t.persistentModelID)
            }
        }
    }
}
