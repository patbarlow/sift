import SwiftUI
import SwiftData

// MARK: - Tabs

enum SettingsTab: String, Identifiable, Hashable, CaseIterable {
    case integrations, context, personalisation, sync, feedback, dangerZone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .integrations: return "Integrations"
        case .context: return "Context"
        case .personalisation: return "Personalisation"
        case .sync: return "Sync"
        case .feedback: return "Feedback"
        case .dangerZone: return "Danger Zone"
        }
    }

    var systemImage: String {
        switch self {
        case .integrations: return "puzzlepiece.extension.fill"
        case .context: return "text.book.closed.fill"
        case .personalisation: return "paintpalette.fill"
        case .sync: return "arrow.triangle.2.circlepath"
        case .feedback: return "bubble.left.and.bubble.right.fill"
        case .dangerZone: return "exclamationmark.triangle.fill"
        }
    }

    var iconTint: Color {
        switch self {
        case .integrations: return .blue
        case .context: return .indigo
        case .personalisation: return .pink
        case .sync: return .teal
        case .feedback: return .purple
        case .dangerZone: return .red
        }
    }
}

enum SettingsGroup: String, CaseIterable, Identifiable {
    case setup, preferences, support, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setup: return "Setup"
        case .preferences: return "Preferences"
        case .support: return "Support"
        case .advanced: return "Advanced"
        }
    }
    var tabs: [SettingsTab] {
        switch self {
        case .setup: return [.integrations, .context]
        case .preferences: return [.personalisation, .sync]
        case .support: return [.feedback]
        case .advanced: return [.dangerZone]
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var selected: SettingsTab = .integrations
    @State private var hovered: SettingsTab?
    @State private var activeIntegration: IntegrationKind?
    @State private var modal: SiftModalConfig?

    enum IntegrationKind: Identifiable, Hashable {
        case slack, granola
        case ai(LLMProviderKind)
        var id: String {
            switch self {
            case .slack: return "slack"
            case .granola: return "granola"
            case .ai(let p): return "ai-\(p.rawValue)"
            }
        }
    }

    private var background: Color { Color.themeSettingsBackground }

    var body: some View {
        // Manual HStack rather than NavigationSplitView — no translucent
        // material, no resizable/collapsible splitter. Flat sidebar that blends
        // into the window background, content on cards.
        HStack(spacing: 0) {
            sidebar.frame(width: 220).frame(maxHeight: .infinity)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 820, height: 580)
        .background(background.ignoresSafeArea())
        // Full rebuild on theme change so every card repaints at once.
        .id(settings.themeID)
        .siftModal($modal)
        .sheet(item: $activeIntegration) { kind in
            IntegrationSheet(kind: kind) { activeIntegration = nil }
                .environmentObject(state)
                .environmentObject(settings)
                .frame(width: 520)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsGroup.allCases) { group in
                Text(group.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 2)
                ForEach(group.tabs) { tab in
                    sidebarRow(tab)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = selected == tab
        let isHovered = hovered == tab && !isSelected
        return Button {
            selected = tab
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tab.iconTint)
                        .frame(width: 22, height: 22)
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(tab.title)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.themeAccent
                          : isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { hovered = $0 ? tab : nil }
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(selected.title)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 4)

                switch selected {
                case .integrations: IntegrationsPane(activeIntegration: $activeIntegration)
                case .context: ContextPane()
                case .personalisation: PersonalisationPane()
                case .sync: SyncPane()
                case .feedback: FeedbackPane()
                case .dangerZone: DangerZonePane(modal: $modal)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Click anywhere off a field to commit it and drop focus.
            .background(
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
            )
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Integrations

struct IntegrationsPane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @Binding var activeIntegration: SettingsView.IntegrationKind?

    private let cols = [GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "AI providers",
                subtitle: "Connect one or more. Choose which model handles each task in Sync."
            ) {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(LLMProviderKind.allCases) { kind in
                        IntegrationTile(
                            logo: .provider(kind),
                            name: kind.displayName,
                            isConnected: kind.isConnected()
                        ) { activeIntegration = .ai(kind) }
                    }
                }
            }

            SettingsCard(
                title: "Sources",
                subtitle: "Where Sift looks for incoming work."
            ) {
                LazyVGrid(columns: cols, spacing: 12) {
                    IntegrationTile(
                        logo: .slack,
                        name: "Slack",
                        isConnected: Keychain.read(SecretKey.slack) != nil
                                     && !settings.slackHandle.isEmpty
                    ) { activeIntegration = .slack }
                    IntegrationTile(
                        logo: .granola,
                        name: "Granola",
                        isConnected: settings.granolaConfigured
                    ) { activeIntegration = .granola }
                }
            }
        }
    }
}

// MARK: - Context

struct ContextPane: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MemoryEntry.mentions, order: .reverse) private var memory: [MemoryEntry]
    @State private var selectedKind: MemoryKind = .person

    private var visible: [MemoryEntry] { memory.filter { $0.confirmed || $0.pinned } }
    private var nonEmptyKinds: [MemoryKind] {
        MemoryKind.allCases.filter { kind in visible.contains { $0.kind == kind } }
    }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Identity",
                subtitle: "How you're addressed. Auto-populated from Slack on first connect."
            ) {
                LabeledField("Name") {
                    TextField("", text: $settings.displayName).textFieldStyle(.roundedBorder)
                }
                LabeledField("Email") {
                    TextField("", text: $settings.email).textFieldStyle(.roundedBorder)
                }
                LabeledField("Aliases") {
                    TextField("Comma-separated", text: $settings.aliases).textFieldStyle(.roundedBorder)
                }
            }

            SettingsCard(
                title: "About you",
                subtitle: "Your role, what you work on, the names you go by."
            ) {
                TextEditor(text: $settings.userContext)
                    .font(.system(size: 13))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }

            contextCard
        }
    }

    private var contextCard: some View {
        SettingsCard(
            title: "Memory",
            subtitle: "People, organizations, projects, and terms Sift picks up from your activity, used to triage and merge todos."
        ) {
            if let updated = visible.map(\.lastSeen).max() {
                Text("Updated \(relative(updated)) \u{00b7} refreshes automatically about once a day.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            if visible.isEmpty {
                Text("Nothing yet \u{2014} Sift builds this as it syncs.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                let kinds = nonEmptyKinds
                let active = kinds.contains(selectedKind) ? selectedKind : (kinds.first ?? .person)
                let rows = visible.filter { $0.kind == active }.sorted { $0.lastSeen > $1.lastSeen }

                HStack(spacing: 2) {
                    ForEach(kinds, id: \.self) { kind in
                        let count = visible.filter { $0.kind == kind }.count
                        SiftButton(variant: .subtle, selected: active == kind,
                                   action: { selectedKind = kind }) {
                            HStack(spacing: 5) {
                                Text(kind.label).lineLimit(1)
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(active == kind ? Color.white.opacity(0.25) : Color.primary.opacity(0.1)))
                            }
                        }
                    }
                }
                .padding(.top, 6)

                VStack(spacing: 10) {
                    ForEach(rows) { ContextRow(entry: $0) }
                }
                .padding(.top, 4)
            }
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// A reusable label-above-field group for settings inputs.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Read-only glossary row: name + one-line description, with when it was last
/// seen. Delete prunes a wrong entry; the rebuild won't bring it back unless it
/// genuinely recurs across multiple todos.
struct ContextRow: View {
    let entry: MemoryEntry
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 13, weight: .medium))
                if !entry.detail.isEmpty {
                    Text(entry.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Text(relative(entry.lastSeen)).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .rowHover()
        .siftContextMenu { dismiss in
            SiftMenuItem(title: "Delete", systemImage: "trash", destructive: true) {
                modelContext.delete(entry); dismiss()
            }
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Sync

struct SyncPane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var intervalOpen = false

    private static let intervals = [5, 10, 15, 30, 60, 120, 180, 240, 360]

    static func intervalLabel(_ min: Int) -> String {
        if min < 60 { return "\(min) min" }
        let h = min / 60, m = min % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    var body: some View {
        VStack(spacing: 16) {
            AITasksCard()
                .zIndex(2)  // so its open dropdown paints above the cards below

            SettingsCard(title: "Schedule", subtitle: "How often Sift checks for new activity in the background.") {
                HStack(spacing: 8) {
                    Text("Run every").font(.system(size: 13))
                    SiftMenu(isOpen: $intervalOpen, variant: .secondary, minWidth: 140) {
                        SiftButtonLabel(title: Self.intervalLabel(settings.syncIntervalMinutes),
                                        leading: nil, trailing: "chevron.up.chevron.down")
                    } content: { dismiss in
                        ForEach(Self.intervals, id: \.self) { m in
                            SiftMenuItem(title: Self.intervalLabel(m),
                                         checked: settings.syncIntervalMinutes == m) {
                                settings.syncIntervalMinutes = m
                                state.restartSchedulerIfRunning()
                                dismiss()
                            }
                        }
                    }
                    .zIndex(intervalOpen ? 10 : 0)
                    Spacer()
                }
            }
            .zIndex(1)
        }
    }
}

// MARK: - AI task models

struct AITasksCard: View {
    @EnvironmentObject var settings: AppSettings
    @State private var modelsByProvider: [LLMProviderKind: [String]] = [:]

    private var connected: [LLMProviderKind] {
        LLMProviderKind.allCases.filter { $0.isConnected() }
    }

    var body: some View {
        SettingsCard(
            title: "AI tasks",
            subtitle: "Pick which connected model handles each kind of work. They can be different providers."
        ) {
            if connected.isEmpty {
                Text("Connect an AI provider under Integrations first.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ModelTaskPicker(
                    title: "Fast model",
                    subtitle: "Classifying messages and extracting action items.",
                    provider: $settings.fastProvider, model: $settings.fastModel,
                    modelsByProvider: modelsByProvider
                )
                Divider().padding(.vertical, 4)
                ModelTaskPicker(
                    title: "Smart model",
                    subtitle: "Writing summaries, grouping work items, and tricky judgment calls.",
                    provider: $settings.smartProvider, model: $settings.smartModel,
                    modelsByProvider: modelsByProvider
                )
            }
        }
        .task { await loadModels() }
    }

    private func loadModels() async {
        for p in connected where modelsByProvider[p] == nil {
            let key = p.needsAPIKey ? (Keychain.read(p.keychainKey) ?? "") : ""
            if let list = try? await p.availableModels(apiKey: key), !list.isEmpty {
                modelsByProvider[p] = list
            }
        }
    }
}

/// A model selector grouped by connected provider, with the provider's logo on
/// the trigger so the active choice is easy to spot.
struct ModelTaskPicker: View {
    let title: String
    let subtitle: String
    @Binding var provider: LLMProviderKind
    @Binding var model: String
    let modelsByProvider: [LLMProviderKind: [String]]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            SiftMenu(isOpen: $open, variant: .secondary, minWidth: 260, scrolls: true) {
                HStack(spacing: 8) {
                    IntegrationLogoView(logo: .provider(provider), size: 16)
                    Text(model.isEmpty ? "Choose a model…" : model).lineLimit(1)
                    Spacer(minLength: 4)
                    LucideIcon(sf: "chevron.up.chevron.down", size: 13)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } content: { dismiss in
                ForEach(LLMProviderKind.allCases.filter { $0.isConnected() }) { p in
                    SiftMenuHeader(title: p.displayName)
                    let models = modelsByProvider[p] ?? [p.defaultFastModel, p.defaultSmartModel]
                    ForEach(models, id: \.self) { m in
                        SiftMenuItem(title: m, checked: provider == p && model == m) {
                            provider = p; model = m; dismiss()
                        }
                    }
                }
            }
        }
        .zIndex(open ? 10 : 0)
    }
}

// MARK: - Danger Zone

struct DangerZonePane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.modelContext) private var ctx
    @ObservedObject private var usage = LLMUsageStore.shared
    @Binding var modal: SiftModalConfig?

    /// A task button that shows a spinner + running label and disables all
    /// actions while any one runs.
    @ViewBuilder
    private func taskButton(_ task: AppState.ActiveTask, _ idle: String, _ busy: String,
                            variant: SiftButtonVariant, run: @escaping () -> Void) -> some View {
        let running = state.activeTask == task
        SiftButton(variant: variant, enabled: state.activeTask == nil, action: run) {
            HStack(spacing: 6) {
                if running { SiftSpinner(dot: 2.4, spacing: 2, color: variant == .primary ? .white : .secondary) }
                Text(running ? busy : idle).lineLimit(1)
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Sync", subtitle: "Run a sync now, see what the last one did, and when the next is due.") {
                HStack(spacing: 8) {
                    taskButton(.sync, "Sync now", "Syncing…", variant: .primary) { state.runSync() }
                    Spacer()
                    if let r = state.lastRefresh {
                        Text("Last sync \(relative(r))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let last = state.lastReport {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\u{2022} \(last.newMentions) from mentions, \(last.newFromWatchedChannels) from watched, \(last.newFromDMs) from DMs")
                        Text("\u{2022} \(last.refreshed) refreshed \u{00b7} \(last.autoClosed) auto-closed \u{00b7} \(last.movedInProgress) \u{2192} in progress")
                        Text("\u{2022} \(last.mergedSources) merged \u{00b7} \(last.archived) archived")
                        if !last.errors.isEmpty {
                            Text("\u{2022} errors: \(last.errors.first ?? "")").foregroundStyle(.red)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let next = state.nextSyncDate {
                    TimelineView(.periodic(from: Date(), by: 30)) { _ in
                        Text(nextSyncLabel(next)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            if usage.hasCacheData {
                SettingsCard(title: "LLM usage", subtitle: "Tokens sent to your AI provider, and how much was served straight from the prompt cache.") {
                    usageRows("Today", usage.today)
                    Divider().opacity(0.4)
                    usageRows("All time", usage.lifetime)
                }
            }

            SettingsCard(title: "Maintenance", subtitle: "Re-run assessment or merging across every todo. Sync already does these as needed.") {
                HStack(spacing: 8) {
                    taskButton(.reevaluate, "Re-evaluate", "Re-evaluating…", variant: .secondary) { state.reevaluateAll() }
                    taskButton(.consolidate, "Consolidate", "Consolidating…", variant: .secondary) { state.runConsolidation() }
                    Spacer()
                }
            }

            SettingsCard(title: "Danger zone", subtitle: "Destructive actions. No undo.") {
                SiftButton("Delete all todos", leading: "trash", variant: .secondary) {
                    modal = confirm("Delete all todos",
                        "This will permanently remove every todo — open, done, and archived. The next sync can re-create them if the underlying threads come back through.",
                        clearTodos)
                }
                SiftButton("Clear all credentials", leading: "key.slash", variant: .secondary) {
                    modal = confirm("Clear all credentials",
                        "This will remove your Slack, Granola, and AI provider keys from the Keychain and disconnect everything. You'll need to reconnect to sync again.",
                        clearCredentials)
                }
                SiftButton("Reset memory", leading: "trash", variant: .secondary) {
                    modal = confirm("Reset memory",
                        "This will clear everything in the Memory tab — all the people, organizations, projects, and terms Sift has learned. It rebuilds over time as you sync.",
                        clearMemory)
                }
            }
        }
    }

    private func confirm(_ title: String, _ message: String, _ action: @escaping () -> Void) -> SiftModalConfig {
        SiftModalConfig(
            title: title, message: message,
            fieldPrompt: "Type confirm to continue",
            actionLabel: title, destructive: true,
            isEnabled: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "confirm" },
            onSubmit: { _ in action() }
        )
    }

    private func clearTodos() {
        guard let all = try? ctx.fetch(FetchDescriptor<Todo>()) else { return }
        for t in all { ctx.delete(t) }
        try? ctx.save()
    }

    private func clearMemory() {
        guard let all = try? ctx.fetch(FetchDescriptor<MemoryEntry>()) else { return }
        for e in all { ctx.delete(e) }
        try? ctx.save()
    }

    private func clearCredentials() {
        Keychain.delete(SecretKey.anthropic)
        Keychain.delete(SecretKey.openai)
        Keychain.delete(SecretKey.groq)
        Keychain.delete(SecretKey.slack)
        Keychain.delete(SecretKey.granola)
        settings.slackUserID = ""
        settings.slackHandle = ""
        settings.slackTeamID = ""
        settings.slackAuthMethod = ""
        settings.granolaConfigured = false
        state.refreshConfigured()
    }

    @ViewBuilder
    private func usageRows(_ label: String, _ t: LLMUsageStore.Totals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Self.pct(t.cacheHitRate)) from cache")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                stat("Input", Self.compact(t.totalInput))
                stat("Cached", Self.compact(t.cacheReadTokens))
                stat("Output", Self.compact(t.outputTokens))
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private static func compact(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000...: return String(format: "%.1fM", d / 1_000_000)
        case 10_000...: return String(format: "%.0fK", d / 1_000)
        case 1_000...: return String(format: "%.1fK", d / 1_000)
        default: return "\(n)"
        }
    }

    private static func pct(_ r: Double) -> String { "\(Int((r * 100).rounded()))%" }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func nextSyncLabel(_ d: Date) -> String {
        let secs = d.timeIntervalSinceNow
        if secs <= 0 { return "Next sync due now" }
        let mins = Int(secs / 60)
        return mins < 1 ? "Next sync in under a minute" : "Next sync in ~\(mins) min"
    }
}

// MARK: - Personalisation

struct PersonalisationPane: View {
    @EnvironmentObject var settings: AppSettings

    private let cols = [GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Theme",
                subtitle: "Palette and type style. Each theme adapts to light and dark mode."
            ) {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(SiftTheme.all) { theme in
                        ThemeSwatch(theme: theme, selected: settings.themeID == theme.id) {
                            settings.themeID = theme.id
                        }
                    }
                }
            }

            SettingsCard(title: "Appearance") {
                HStack(spacing: 8) {
                    ForEach(AppearanceMode.allCases) { mode in
                        SiftButton(mode.label, variant: .secondary,
                                   selected: settings.appearanceMode == mode) {
                            settings.appearanceMode = mode
                        }
                    }
                    Spacer()
                }
            }

        }
    }
}

/// Mini preview tile for a theme: its background, accent dot, and name set in
/// its own type design.
struct ThemeSwatch: View {
    let theme: SiftTheme
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.windowSolid)
                    HStack(spacing: 4) {
                        Circle().fill(theme.accent).frame(width: 10, height: 10)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 34, height: 5)
                    }
                }
                .frame(height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                Text(theme.name)
                    .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(.primary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hovering && !selected ? Color.primary.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? theme.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
