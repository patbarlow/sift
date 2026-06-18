import SwiftUI
import SwiftData
import AppKit

// MARK: - Logo / Tile

/// Logo asset for an integration. SVGs are bundled as resources and loaded
/// via `NSImage`, which supports SVG natively on macOS 14+.
enum IntegrationLogo {
    case slack
    case claude
    case granola
    case openai
    case gemini
    case groq
    case deepseek

    /// Logo for an AI provider.
    static func provider(_ kind: LLMProviderKind) -> IntegrationLogo {
        switch kind {
        case .anthropic: return .claude
        case .openai: return .openai
        case .gemini: return .gemini
        case .groq: return .groq
        case .deepseek: return .deepseek
        }
    }

    @MainActor
    func image(for colorScheme: ColorScheme) -> NSImage? {
        let dark = colorScheme == .dark
        let name: String
        switch self {
        case .slack: name = "slack"
        case .claude: name = "claude"
        case .granola: name = dark ? "granola-dark" : "granola-light"
        case .openai: name = dark ? "openai-dark" : "openai-light"
        case .gemini: name = "gemini"
        case .groq: name = "groq"
        case .deepseek: name = "deepseek"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

struct IntegrationLogoView: View {
    @Environment(\.colorScheme) private var colorScheme
    let logo: IntegrationLogo
    let size: CGFloat

    var body: some View {
        if let nsImage = logo.image(for: colorScheme) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "square.grid.2x2")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// Clickable tile for an integration. Connection state is conveyed entirely
/// by the green checkmark badge in the top-right — no redundant text below.
struct IntegrationTile: View {
    let logo: IntegrationLogo
    let name: String
    let isConnected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                IntegrationLogoView(logo: logo, size: 36)
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if isConnected {
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 18, height: 18)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards & masked secrets

/// White rounded card used as the building block on every settings pane.
struct SettingsCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil,
         subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Fill and border both live in the background so content (e.g. an open
        // SiftMenu dropdown) paints above the border instead of behind it.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.themeCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                // Click a card's empty area to commit + unfocus any field.
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        )
    }
}

/// Read-only display of a secret already in the Keychain. Fixed run of dots
/// so it's visually clear the key is set; the actual value is never put
/// into a view, never selectable, never copyable.
struct MaskedSecretRow: View {
    let label: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(String(repeating: "•", count: 16))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Stored securely")
        }
    }
}

// MARK: - Integration sheet shell

struct IntegrationSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let kind: SettingsView.IntegrationKind
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch kind {
                    case .ai(let p): AIProviderView(provider: p)
                    case .slack: SlackIntegrationView()
                    case .granola: GranolaIntegrationView()
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                SiftButton("Done", variant: .primary) { onClose() }
            }
            .padding(12)
        }
        .frame(minHeight: 420)
    }

    private var logo: IntegrationLogo {
        switch kind {
        case .ai(let p): return .provider(p)
        case .slack: return .slack
        case .granola: return .granola
        }
    }

    private var title: String {
        switch kind {
        case .ai(let p): return p.displayName
        case .slack: return "Slack"
        case .granola: return "Granola"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IntegrationLogoView(logo: logo, size: 28)
            Text(title).font(.title3).bold()
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Per-integration content

struct AIProviderView: View {
    @EnvironmentObject var state: AppState
    let provider: LLMProviderKind
    @State private var newKey: String = ""
    @State private var editingKey = false

    private var stored: Bool { provider.isConnected() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(provider.displayName) with your own API key. Once connected, pick which Sift tasks use its models under Sync.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if stored && !editingKey {
                HStack {
                    MaskedSecretRow(label: "API key")
                    Spacer()
                    SiftButton("Replace", variant: .secondary) { editingKey = true }
                    SiftButton("Disconnect", leading: "xmark.circle", variant: .secondary) {
                        Keychain.delete(provider.keychainKey)
                        state.refreshConfigured()
                    }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("\(provider.displayName) API key (\(provider.keyPlaceholder))", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                    let canSave = !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    SiftButton("Save", variant: .primary) {
                        guard canSave else { return }
                        Keychain.write(newKey.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.keychainKey)
                        newKey = ""
                        editingKey = false
                        state.refreshConfigured()
                    }
                    .opacity(canSave ? 1 : 0.5)
                    .disabled(!canSave)
                    if stored {
                        SiftButton("Cancel", variant: .subtle) { newKey = ""; editingKey = false }
                    }
                }
            }
        }
    }
}

struct SlackIntegrationView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.modelContext) private var ctx
    @Query(sort: \WatchedChannel.name) private var watched: [WatchedChannel]
    @Query(sort: \IgnoredMentionChannel.name) private var ignored: [IgnoredMentionChannel]
    @State private var stored: Bool = Keychain.read(SecretKey.slack) != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            connectionBlock

            if stored {
                Divider()
                channelsBlock(
                    title: "Watched channels",
                    subtitle: "Top-level messages here are scanned even when you're not @mentioned.",
                    existing: watched.map { ($0.channelID, $0.name) },
                    onAdd: { channel in addWatched(channel) },
                    onRemove: { id in
                        if let row = watched.first(where: { $0.channelID == id }) {
                            ctx.delete(row)
                            try? ctx.save()
                        }
                    }
                )

                Divider()
                channelsBlock(
                    title: "Ignored channels",
                    subtitle: "Mentions of you in these channels are skipped. Useful for aggregator channels that re-post mentions from elsewhere.",
                    existing: ignored.map { ($0.channelID, $0.name) },
                    onAdd: { channel in
                        ctx.insert(IgnoredMentionChannel(channelID: channel.id,
                                                         name: channel.name ?? channel.id))
                        try? ctx.save()
                    },
                    onRemove: { id in
                        if let row = ignored.first(where: { $0.channelID == id }) {
                            ctx.delete(row)
                            try? ctx.save()
                        }
                    }
                )
            }
        }
    }

    @State private var showManualToken = false
    @State private var manualToken: String = ""
    @State private var resolvingToken = false
    @State private var tokenError: String?
    @State private var showSwitchMethod = false

    private var methodLabel: String {
        switch settings.slackAuthMethod {
        case "oauth": return "Connected via the Sift Slack app (one-click OAuth)"
        case "manual": return "Connected with a token from your own Slack app"
        default: return "Connected"
        }
    }

    @ViewBuilder
    private var connectionBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connects to your Slack workspace. Sift reads messages where you're mentioned, your DMs, plus channels you mark below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if stored {
                connectedView
            } else {
                disconnectedView
            }
        }
    }

    // Clean connected state: account + how it's connected + Disconnect, with
    // the (rarely needed) method-switching tucked behind a disclosure.
    @ViewBuilder
    private var connectedView: some View {
        HStack {
            Text("Account").foregroundStyle(.secondary)
            Spacer()
            Text(settings.slackHandle.isEmpty ? settings.slackUserID : "@\(settings.slackHandle)")
        }
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(methodLabel).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { disconnect() } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
        Button(showSwitchMethod ? "Hide" : "Switch connection method") {
            showSwitchMethod.toggle()
        }
        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        if showSwitchMethod {
            VStack(alignment: .leading, spacing: 10) {
                Button("Reconnect via the Sift Slack app") { OAuthCoordinator.shared.start() }
                manualTokenEntry
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    @ViewBuilder
    private var disconnectedView: some View {
        Button("Connect with Slack") { OAuthCoordinator.shared.start() }
        Button(showManualToken ? "Hide manual entry" : "Or paste a token manually") {
            showManualToken.toggle()
        }
        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        if showManualToken { manualTokenEntry }
    }

    @ViewBuilder
    private var manualTokenEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste a Slack user token (xoxp-…) from your own Slack app.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField("xoxp-…", text: $manualToken)
                    .textFieldStyle(.roundedBorder)
                Button("Connect") { resolveManualSlackToken() }
                    .disabled(manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvingToken)
                if resolvingToken { SiftSpinner() }
            }
            if let err = tokenError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func disconnect() {
        Keychain.delete(SecretKey.slack)
        settings.slackUserID = ""
        settings.slackHandle = ""
        settings.slackTeamID = ""
        settings.slackAuthMethod = ""
        stored = false
        showSwitchMethod = false
        state.refreshConfigured()
    }

    private func resolveManualSlackToken() {
        let trimmed = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        resolvingToken = true
        tokenError = nil
        Task {
            do {
                let client = SlackClient(token: trimmed)
                let auth = try await client.authTest()
                let profile = try await client.userProfile(userID: auth.userID)
                await MainActor.run {
                    Keychain.write(trimmed, for: SecretKey.slack)
                    settings.slackUserID = auth.userID
                    settings.slackHandle = auth.userName
                    settings.slackTeamID = auth.teamID
                    settings.slackAuthMethod = "manual"
                    if !profile.displayName.isEmpty { settings.displayName = profile.displayName }
                    if !profile.email.isEmpty { settings.email = profile.email }
                    manualToken = ""
                    showManualToken = false
                    showSwitchMethod = false
                    stored = true
                    resolvingToken = false
                    state.refreshConfigured()
                }
            } catch {
                await MainActor.run {
                    tokenError = "Token validation failed: \(error.localizedDescription)"
                    resolvingToken = false
                }
            }
        }
    }

    @ViewBuilder
    private func channelsBlock(
        title: String,
        subtitle: String,
        existing: [(id: String, name: String)],
        onAdd: @escaping (SlackClient.Channel) -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        let excludedIDs = Set(existing.map(\.id))
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).bold()
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(existing, id: \.id) { row in
                HStack {
                    Text("#\(row.name)")
                    Spacer()
                    Button(role: .destructive) {
                        onRemove(row.id)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            SlackChannelPicker(excludedIDs: excludedIDs, onPick: onAdd)
        }
    }

    private func addWatched(_ channel: SlackClient.Channel) {
        let name = channel.name ?? channel.id
        ctx.insert(WatchedChannel(channelID: channel.id, name: name))
        // Seed the channel's cursor at "now" so the first scan only picks up
        // new messages — otherwise we'd dump weeks of history into the list.
        let nowTs = String(format: "%.6f", Date().timeIntervalSince1970)
        let cursorKey = "channel:\(channel.id)"
        let pred = #Predicate<SyncCursor> { $0.key == cursorKey }
        if let existing = try? ctx.fetch(FetchDescriptor<SyncCursor>(predicate: pred)).first {
            existing.cursor = nowTs
        } else {
            ctx.insert(SyncCursor(key: cursorKey, cursor: nowTs))
        }
        try? ctx.save()
    }
}

struct GranolaIntegrationView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var newKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Granola (docs.granola.ai) to pull action items from meeting notes that are assigned to you. Generate an API key in the Granola app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.granolaConfigured {
                MaskedSecretRow(label: "API key")
            }

            SecureField(settings.granolaConfigured ? "Replace API key" : "Granola API key",
                        text: $newKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(settings.granolaConfigured ? "Replace key" : "Save & enable") {
                    let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Keychain.write(trimmed, for: SecretKey.granola)
                    settings.granolaConfigured = true
                    newKey = ""
                }
                .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if settings.granolaConfigured {
                    Spacer()
                    Button(role: .destructive) {
                        Keychain.delete(SecretKey.granola)
                        settings.granolaConfigured = false
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            }
        }
    }
}

// MARK: - Slack channel picker

/// Search field over the user's Slack channels. Fetches `users.conversations`
/// once (paginated), then filters in-memory as the user types. Picking a
/// result calls `onPick` with the channel and clears the field.
struct SlackChannelPicker: View {
    let excludedIDs: Set<String>
    let onPick: (SlackClient.Channel) -> Void

    @State private var query: String = ""
    @State private var channels: [SlackClient.Channel] = []
    @State private var loading: Bool = false
    @State private var loadError: String?

    private var matches: [SlackClient.Channel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return channels
            .filter { !excludedIDs.contains($0.id) }
            .filter { ($0.name ?? "").lowercased().contains(q) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if !matches.isEmpty {
                resultsList
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search channels…", text: $query)
                .textFieldStyle(.plain)
                .onAppear { if channels.isEmpty { Task { await load() } } }
            if loading {
                SiftSpinner()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            ForEach(matches) { channel in
                resultRow(channel)
                if channel.id != matches.last?.id { Divider() }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func resultRow(_ channel: SlackClient.Channel) -> some View {
        Button {
            onPick(channel)
            query = ""
        } label: {
            HStack {
                Image(systemName: channel.is_private == true ? "lock.fill" : "number")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(channel.name ?? channel.id)
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.themeAccent)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func load() async {
        guard let token = Keychain.read(SecretKey.slack) else {
            loadError = "Slack not connected."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let list = try await SlackClient(token: token).listChannels()
            channels = list.sorted { ($0.name ?? "") < ($1.name ?? "") }
            loadError = nil
        } catch {
            loadError = "Couldn't load channels: \(error.localizedDescription)"
        }
    }
}
