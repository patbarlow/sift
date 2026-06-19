import SwiftUI
import SwiftData
import AppKit

// MARK: - Adaptive colors + helpers

extension Color {
    static let softFill = Color.primary.opacity(0.06)
    static let softFillHover = Color.primary.opacity(0.12)
}

private let redactionSafeWords: Set<String> = [
    "I", "I'll", "I'm", "I've", "I'd",
    "A", "An", "The", "This", "That", "These", "Those",
    "You", "Your", "Yours", "You're", "You've", "Yet",
    "He", "She", "It", "It's", "We", "They", "Their", "Them", "Theirs",
    "Me", "My", "Myself", "Us",
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
    "Jan", "Feb", "Mar", "Apr", "Jun", "Jul", "Aug", "Sep", "Sept", "Oct", "Nov", "Dec",
    "AM", "PM", "EOD", "EOW", "ETA", "TBD", "TBC", "FYI", "OK",
    "FAQ", "API", "URL", "URI", "MCP", "FDE", "LLM", "AI", "UI", "UX",
    "PR", "QA", "QBR", "CSAT", "OKR", "KR", "SOP", "SLA",
    "Was", "Were", "Has", "Have", "Had", "Will", "Would", "Could", "Should",
    "Did", "Does", "Is", "Are", "Be", "Been", "Being",
    "If", "When", "Then", "While", "Until", "Before", "After", "Although",
    "Because", "However", "Maybe", "Yes", "No",
    "GitHub", "Slack", "Linear", "Notion", "Granola", "Zendesk", "Intercom",
    "Salesforce", "Vercel", "Google", "Anthropic", "Claude",
]

extension String {
    func redacting(_ enabled: Bool) -> String {
        enabled ? self.redactingPII() : self
    }
    func redactingPII() -> String {
        var result = self
        result = result.replacingPattern("#[A-Za-z0-9_-]+") { _ in "#████" }
        result = result.replacingPattern("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}") { _ in "████@████" }
        result = result.replacingPattern("https?://[^\\s)\\]>]+") { _ in "████" }
        result = result.replacingPattern("\\b[A-Z][A-Za-z'-]+\\b") { word in
            redactionSafeWords.contains(word) ? word : "████"
        }
        return result
    }
    fileprivate func replacingPattern(_ pattern: String, with replacement: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        var result = self
        let nsrange = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: nsrange).reversed()
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let word = String(result[range])
            result.replaceSubrange(range, with: replacement(word))
        }
        return result
    }
}

extension AppSettings {
    // The theme supplies the type design so a theme can read like the tool it
    // borrows its palette from (e.g. Gotham → mono, Claude → serif).
    func titleFont() -> Font {
        .system(.body, design: theme.fontDesign).weight(.semibold)
    }
    func summaryFont() -> Font {
        .system(.callout, design: theme.fontDesign)
    }
    func channelFont() -> Font {
        .system(.caption2, design: theme.fontDesign).weight(.medium)
    }
}

// MARK: - Source filter tabs

/// Top-level lifecycle tabs. A todo is a source-agnostic work item (it can
/// link multiple Slack threads and/or a Granola meeting), so the list is
/// organised by lifecycle stage rather than by source.
enum MainTab: String, CaseIterable, Identifiable {
    case review = "Review"
    case todos = "Todos"
    case stale = "Stale"
    case completed = "Completed"
    case archived = "Archived"
    case snoozed = "Snoozed"
    case activity = "Activity"
    var id: String { rawValue }
}

// MARK: - Main content view

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    let onClose: () -> Void
    let onSnap: (WindowSnapAction) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        // ZStack + ignoresSafeArea so the *content* (not just the background)
        // lays out from the true window top — the header then sits level with
        // the traffic lights instead of below the titlebar's safe-area inset.
        ZStack(alignment: .top) {
            Color.themeHeader
            listView
        }
        .ignoresSafeArea()
        // Rebuild the whole tree on theme change so every view repaints at
        // once — theme colors are read from a global, which SwiftUI's diffing
        // won't otherwise re-evaluate in views whose inputs didn't change.
        .id(settings.themeID)
        .siftModal($state.modal)
        .siftTodoDetail($state.detailTodo)
    }

    @ViewBuilder
    private var content: some View {
        switch state.mainTab {
        case .todos, .stale:
            TodosScrollView(tab: state.mainTab)
        case .completed:
            ArchiveScrollView(archived: false)
        case .archived:
            ArchiveScrollView(archived: true)
        case .snoozed:
            SnoozedScrollView()
        case .review:
            ReviewScrollView()
        case .activity:
            ActivityScrollView()
        }
    }

    @ViewBuilder
    private var listView: some View {
        VStack(spacing: 0) {
            HeaderBar(
                onClose: onClose,
                onSnap: onSnap,
                onOpenSettings: onOpenSettings
            )
            // Left inset clears the macOS traffic lights with breathing room
            // before the first tab. The header sizes to its content (no fixed
            // band) so there's no slack below it; the 5px bottom matches the
            // card's grey frame on the other three sides.
            .padding(.leading, 94)
            .padding(.trailing, 12)
            .padding(.top, 7)
            .padding(.bottom, 5)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(settings.theme.windowSolid)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                // Uniform 5px grey frame on all four sides of the card.
                .padding(.horizontal, 5)
                .padding(.bottom, 5)
        }
    }
}

// MARK: - List view (SwiftData powered)

struct TodosScrollView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    let tab: MainTab

    @Query private var openTodos: [Todo]

    init(tab: MainTab) {
        self.tab = tab
        let predicate = #Predicate<Todo> { $0.status != "done" && $0.status != "archived" }
        var descriptor = FetchDescriptor<Todo>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.lastSlackActivity, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        _openTodos = Query(descriptor)
    }

    var visible: [Todo] {
        // Stale tab shows the quiet-but-active items; Todos shows the rest.
        let active = openTodos.filter { !$0.isSnoozed && !$0.pendingReview }
        let base = tab == .stale ? active.filter(\.isStale) : active.filter { !$0.isStale }
        // High-priority first; recency breaks ties (the fetch is date-sorted,
        // but make the tiebreak explicit rather than relying on sort stability).
        return base.sorted {
            if $0.effectivePriority != $1.effectivePriority { return $0.effectivePriority < $1.effectivePriority }
            return $0.lastSlackActivity > $1.lastSlackActivity
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if visible.isEmpty && !state.isSyncing {
                    emptyState
                } else if settings.groupingMode == .none {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(visible) { todo in
                            IssueRow(todo: todo)
                        }
                    }
                } else {
                    ForEach(groupedSections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(section.todos) { todo in
                                    IssueRow(todo: todo)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct GroupedSection {
        let title: String
        let todos: [Todo]
    }

    private var groupedSections: [GroupedSection] {
        let mode = settings.groupingMode
        let buckets = Dictionary(grouping: visible) { todo -> String in
            switch mode {
            case .none: return ""
            case .channel: return todo.sourceLabel
            case .status:
                switch todo.statusEnum {
                case .inProgress: return "In progress"
                case .open: return "Open"
                case .done: return "Done"
                case .archived: return "Archived"
                }
            case .createdDate: return DateBucket.label(for: todo.createdAt)
            case .updatedDate: return DateBucket.label(for: todo.lastSlackActivity)
            }
        }
        let sectionKeys = buckets.keys.sorted { a, b in
            switch mode {
            case .channel: return a.localizedStandardCompare(b) == .orderedAscending
            case .status:
                let order = ["In progress": 0, "Open": 1, "Done": 2]
                return (order[a] ?? 99) < (order[b] ?? 99)
            case .createdDate, .updatedDate:
                return DateBucket.sortKey(for: a) < DateBucket.sortKey(for: b)
            case .none: return false
            }
        }
        return sectionKeys.map { GroupedSection(title: $0, todos: buckets[$0] ?? []) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tab == .stale {
                Text("Nothing stale.")
                    .font(.system(.title3, design: .serif).italic())
                Text("Open todos that go quiet for \(Int(Todo.staleAfterDays)) days land here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("You've cleared all your items!")
                    .font(.system(.title3, design: .serif).italic())
                Text("Nothing needs your attention right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

}

// MARK: - Archive (completed todos)

/// Suggestions the app isn't confident enough to apply on its own — grouped
/// by type, each accepted or declined inline.
struct ReviewScrollView: View {
    @EnvironmentObject var state: AppState
    @Query private var all: [Todo]

    private var byKind: [(ReviewKind, [Todo])] {
        let flagged = all.filter(\.needsReview)
        return [ReviewKind.forYou, .merge, .done].compactMap { kind in
            let items = flagged.filter { $0.reviewKindEnum == kind }
                .sorted { $0.reviewConfidence > $1.reviewConfidence }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    private func primaryTitle(for todo: Todo) -> String? {
        guard let key = todo.reviewMergeIntoKey else { return nil }
        return all.first { $0.threadKey == key }?.title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if byKind.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing to review.")
                            .font(.system(.title3, design: .serif).italic())
                        Text("When Sift is unsure whether something's yours, a duplicate, or done, it'll ask you here.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(byKind, id: \.0) { kind, items in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(kind.sectionTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary).textCase(.uppercase)
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(items) { todo in
                                    ReviewRow(todo: todo, mergeInto: primaryTitle(for: todo))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReviewRow: View {
    let todo: Todo
    let mergeInto: String?
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var hovering = false

    private var icon: String {
        switch todo.reviewKindEnum {
        case .forYou: return "person.crop.circle.badge.questionmark"
        case .merge: return "arrow.triangle.merge"
        case .done: return "checkmark.circle"
        case .none: return "questionmark"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title.redacting(settings.redactionEnabled))
                    .font(settings.titleFont())
                    .fixedSize(horizontal: false, vertical: true)
                if let mergeInto, todo.reviewKindEnum == .merge {
                    Text("Merge into “\(mergeInto.redacting(settings.redactionEnabled))”")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let reason = todo.reviewReason, !reason.isEmpty {
                    Text(reason.redacting(settings.redactionEnabled))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(Int(todo.reviewConfidence * 100))% confident")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                SiftButton(variant: .secondary, iconOnly: true) { state.acceptReview(todo) } content: {
                    LucideIcon(sf: "checkmark", size: 13)
                        .foregroundStyle(InProgressBadge.adaptiveGreen)
                }
                .help("Accept")
                SiftButton(variant: .secondary, iconOnly: true) { state.declineReview(todo) } content: {
                    LucideIcon(sf: "xmark", size: 13)
                        .foregroundStyle(.secondary)
                }
                .help("Decline")
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0.03))
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// Parked (snoozed) todos, waiting on a reply or a date.
struct SnoozedScrollView: View {
    @EnvironmentObject var state: AppState
    @Query private var openTodos: [Todo]

    init() {
        let predicate = #Predicate<Todo> { $0.status != "done" && $0.status != "archived" }
        var d = FetchDescriptor<Todo>(predicate: predicate,
                                      sortBy: [SortDescriptor(\.lastSlackActivity, order: .reverse)])
        d.fetchLimit = 200
        _openTodos = Query(d)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let snoozed = openTodos.filter(\.isSnoozed)
                if snoozed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing snoozed.")
                            .font(.system(.title3, design: .serif).italic())
                        Text("Right-click a todo → Snooze to park it until a reply or a date.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(snoozed) { IssueRow(todo: $0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A running log of what Sift did — newest first, grouped by day.
struct ActivityScrollView: View {
    @EnvironmentObject var settings: AppSettings
    @Query(sort: \ActivityEvent.createdAt, order: .reverse) private var events: [ActivityEvent]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if events.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing yet.")
                            .font(.system(.title3, design: .serif).italic())
                        Text("As Sift creates, merges, snoozes, and closes todos, it logs each step here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(groupedByDay, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(section.events) { ActivityRow(event: $0) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct DaySection { let title: String; let events: [ActivityEvent] }

    private var groupedByDay: [DaySection] {
        let buckets = Dictionary(grouping: events) { DateBucket.label(for: $0.createdAt) }
        return buckets.keys
            .sorted { DateBucket.sortKey(for: $0) < DateBucket.sortKey(for: $1) }
            .map { DaySection(title: $0, events: buckets[$0] ?? []) }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.kind.systemImage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(event.kind.verb)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail.redacting(settings.redactionEnabled))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(event.title.redacting(settings.redactionEnabled))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(relative(event.createdAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .rowHover()
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct ArchiveScrollView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    let archived: Bool
    @Query private var doneTodos: [Todo]

    init(archived: Bool) {
        self.archived = archived
        let status = archived ? "archived" : "done"
        var descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { $0.status == status },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        _doneTodos = Query(descriptor)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if doneTodos.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(archived ? "Nothing archived." : "Nothing completed yet.")
                            .font(.system(.title3, design: .serif).italic())
                        Text(archived
                             ? "Todos with no activity for \(Int(Todo.archiveAfterDays)) days land here."
                             : "Resolved and auto-closed todos appear here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(groupedByCompletedDate, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(section.todos) { todo in
                                    ArchivedRow(todo: todo)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct ArchiveSection { let title: String; let todos: [Todo] }

    private var groupedByCompletedDate: [ArchiveSection] {
        let buckets = Dictionary(grouping: doneTodos) { todo in
            DateBucket.label(for: todo.completedAt ?? todo.updatedAt)
        }
        return buckets.keys
            .sorted { DateBucket.sortKey(for: $0) < DateBucket.sortKey(for: $1) }
            .map { ArchiveSection(title: $0, todos: buckets[$0] ?? []) }
    }
}

struct ArchivedRow: View {
    let todo: Todo
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var hovering = false

    var body: some View {
        // Same layout as IssueRow: status icon centered in the title line,
        // detail text indented to the shared gutter underneath.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: todo.statusEnum == .archived ? "archivebox.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(todo.statusEnum == .archived
                                     ? Color.secondary.opacity(0.7)
                                     : InProgressBadge.adaptiveGreen.opacity(0.85))
                    .frame(width: 16)
                    .padding(.trailing, 6)
                Text(todo.title.redacting(settings.redactionEnabled))
                    .font(settings.titleFont())
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let c = todo.completedAt {
                    Text(relative(c))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let reason = todo.completionReason, !reason.isEmpty {
                    Text(reason.redacting(settings.redactionEnabled))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SourcePill(todo: todo, font: settings.channelFont(), redacted: settings.redactionEnabled)
                    .padding(.top, 1)
            }
            .padding(.leading, IssueRow.gutter)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.openDetail(todo) }
        .rowHover()
        .siftContextMenu { dismiss in
            SiftMenuItem(title: "Open", systemImage: "rectangle.on.rectangle") {
                state.openDetail(todo); dismiss()
            }
            if let url = todo.sourceURL {
                SiftMenuItem(title: todo.sourceKind == .granola ? "Open Granola note" : "Open in Slack",
                             systemImage: todo.sourceKind == .granola ? "note.text" : "bubble.left") {
                    NSWorkspace.shared.open(url); dismiss()
                }
            }
            SiftMenuItem(title: "Restore (re-open)", systemImage: "arrow.uturn.backward") {
                reopen(); dismiss()
            }
            SiftMenuItem(title: "Delete", systemImage: "trash", destructive: true) {
                state.delete(todo); dismiss()
            }
        }
    }

    private func reopen() {
        let id = todo.persistentModelID
        Task { @MainActor in
            let ctx = ModelContext(state.container)
            if let t = ctx.model(for: id) as? Todo {
                t.status = TodoStatus.open.rawValue
                t.completedAt = nil
                t.completionReason = nil
                t.updatedAt = Date()
                t.lastActivityAt = Date()  // fresh clock so it won't instantly re-archive
                try? ctx.save()
            }
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    let onClose: () -> Void
    let onSnap: (WindowSnapAction) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HeaderTabs()
                .fixedSize()
                .layoutPriority(1)
            WindowDragHandle()
                .frame(maxWidth: .infinity)
            if state.isSyncing {
                SiftSpinner(dot: 2.2, spacing: 2)
            }
            NavMenu(onSnap: onSnap, onOpenSettings: onOpenSettings)
        }
    }
}

/// The always-visible working tabs (Todos / Snoozed / Stale, plus Review when
/// there's something to review, plus whichever browse destination is active).
struct HeaderTabs: View {
    @EnvironmentObject var state: AppState
    @Query private var all: [Todo]

    private static let primary: [MainTab] = [.todos, .snoozed, .stale]
    // These live in the menu, but surface as a tab while you're on them.
    private static let browse: [MainTab] = [.completed, .archived, .activity]

    private var tabs: [MainTab] {
        var t: [MainTab] = []
        if count(.review) > 0 || state.mainTab == .review { t.append(.review) }
        t += Self.primary
        if Self.browse.contains(state.mainTab) { t.append(state.mainTab) }
        return t
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = state.mainTab == tab
                SiftButton(variant: .subtle, selected: isSelected, action: { state.mainTab = tab }) {
                    HStack(spacing: 5) {
                        Text(tab.rawValue).lineLimit(1)
                        if count(tab) > 0 {
                            Text("\(count(tab))")
                                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : Color.primary.opacity(0.1)))
                        }
                    }
                }
            }
        }
    }

    private func count(_ tab: MainTab) -> Int {
        switch tab {
        case .review: return all.filter(\.needsReview).count
        case .todos: return all.filter { $0.isOpen && !$0.isStale && !$0.isSnoozed && !$0.pendingReview }.count
        case .stale: return all.filter { $0.isOpen && $0.isStale && !$0.isSnoozed && !$0.pendingReview }.count
        case .completed: return all.filter { $0.statusEnum == .done }.count
        case .archived: return all.filter { $0.statusEnum == .archived }.count
        case .snoozed: return all.filter { $0.isSnoozed && !$0.pendingReview }.count
        case .activity: return 0
        }
    }
}

/// The header menu: a hamburger on the right that clicks open to the browse
/// destinations (Completed / Archived / Activity) plus view / window / settings.
struct NavMenu: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    let onSnap: (WindowSnapAction) -> Void
    let onOpenSettings: () -> Void
    @State private var open = false

    var body: some View {
        SiftMenu(isOpen: $open, iconOnly: true, minWidth: 220, alignTrailing: true) {
            LucideIcon(sf: "line.3.horizontal", size: 16)
        } content: { dismiss in
            SiftMenuHeader(title: "Browse")
            SiftMenuItem(title: "Completed", systemImage: "checkmark.circle",
                         checked: state.mainTab == .completed, shortcut: "O C") {
                state.mainTab = .completed; dismiss()
            }
            SiftMenuItem(title: "Archived", systemImage: "archivebox",
                         checked: state.mainTab == .archived, shortcut: "O A") {
                state.mainTab = .archived; dismiss()
            }
            SiftMenuItem(title: "Activity", systemImage: "clock.arrow.circlepath",
                         checked: state.mainTab == .activity, shortcut: "O V") {
                state.mainTab = .activity; dismiss()
            }

            SiftMenuHeader(title: "View")
            SiftSubmenu(title: "Group by", systemImage: "rectangle.3.group") { d in
                ForEach(TodoGrouping.allCases) { mode in
                    SiftMenuItem(title: mode.displayName, checked: settings.groupingMode == mode) {
                        settings.groupingMode = mode; d()
                    }
                }
            }

            SiftMenuHeader(title: "Window")
            SiftMenuItem(title: "Snap to left", systemImage: "rectangle.lefthalf.inset.filled") { onSnap(.snapLeft); dismiss() }
            SiftMenuItem(title: "Snap to right", systemImage: "rectangle.righthalf.inset.filled") { onSnap(.snapRight); dismiss() }
            if NSScreen.screens.count > 1 {
                SiftMenuItem(title: "Next display: left", systemImage: "rectangle.on.rectangle") { onSnap(.nextDisplayLeft); dismiss() }
                SiftMenuItem(title: "Next display: right", systemImage: "rectangle.on.rectangle") { onSnap(.nextDisplayRight); dismiss() }
            }

            SiftMenuDivider()
            SiftMenuItem(title: "Settings…", systemImage: "gearshape", shortcut: "O ,") { onOpenSettings(); dismiss() }
        }
        .zIndex(open ? 100 : 0)
    }
}

struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct PositionMenu: View {
    let onSnap: (WindowSnapAction) -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            Button(action: { onSnap(.snapLeft) }) {
                Label("Snap to left", systemImage: "rectangle.lefthalf.inset.filled")
            }
            Button(action: { onSnap(.snapRight) }) {
                Label("Snap to right", systemImage: "rectangle.righthalf.inset.filled")
            }
            if NSScreen.screens.count > 1 {
                Divider()
                Button(action: { onSnap(.nextDisplayLeft) }) {
                    Label("Next display: snap left", systemImage: "rectangle.on.rectangle")
                }
                Button(action: { onSnap(.nextDisplayRight) }) {
                    Label("Next display: snap right", systemImage: "rectangle.on.rectangle")
                }
            }
        } label: {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Window position")
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Drag handle (NSView)

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 24)
    }
    private final class DragNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

// MARK: - Issue row

struct IssueRow: View {
    let todo: Todo
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var checkHovering = false

    var body: some View {
        mainRow
        .rowHover()
        .siftContextMenu { dismiss in
            SiftMenuItem(title: "Open", systemImage: "rectangle.on.rectangle") {
                state.openDetail(todo); dismiss()
            }
            if let url = todo.sourceURL {
                SiftMenuItem(title: todo.sourceKind == .granola ? "Open Granola note" : "Open in Slack",
                             systemImage: todo.sourceKind == .granola ? "note.text" : "bubble.left") {
                    NSWorkspace.shared.open(url); dismiss()
                }
            }
            SiftMenuItem(title: "Mark done", systemImage: "checkmark.circle") {
                state.markDone(todo); dismiss()
            }

            if todo.isSnoozed {
                SiftMenuItem(title: "Wake now", systemImage: "bell") {
                    state.unsnooze(todo); dismiss()
                }
            } else {
                SiftSubmenu(title: "Snooze", systemImage: "moon.zzz") { dismiss in
                    SiftMenuItem(title: "Until a reply", systemImage: "bubble.left") {
                        state.snooze(todo, watching: nil); dismiss()
                    }
                    SiftMenuItem(title: "Watch a thread…", systemImage: "link") {
                        dismiss()
                        state.modal = SiftModalConfig(
                            title: "Watch a thread",
                            message: "Paste a Slack message link. This todo wakes when that thread gets a new reply.",
                            fieldPrompt: "https://….slack.com/archives/…",
                            actionLabel: "Watch",
                            destructive: false,
                            isEnabled: { state.threadKey(fromSlackURL: $0) != nil },
                            onSubmit: { url in
                                if let key = state.threadKey(fromSlackURL: url) {
                                    state.snooze(todo, watching: key)
                                }
                            }
                        )
                    }
                    SiftMenuItem(title: "Until tomorrow", systemImage: "sun.max") {
                        state.snooze(todo, until: Self.snoozeDate(days: 1)); dismiss()
                    }
                    SiftMenuItem(title: "Until next week", systemImage: "calendar") {
                        state.snooze(todo, until: Self.snoozeDate(days: 7)); dismiss()
                    }
                }
            }

            SiftSubmenu(title: "Priority", systemImage: "flag") { dismiss in
                SiftMenuItem(title: "Auto", systemImage: "wand.and.stars",
                             checked: !todo.priorityOverridden) {
                    state.setPriority(todo, nil); dismiss()
                }
                SiftMenuItem(title: "High", systemImage: "exclamationmark.circle",
                             checked: todo.priorityOverridden && todo.priorityEnum == .high) {
                    state.setPriority(todo, .high); dismiss()
                }
                SiftMenuItem(title: "Normal", systemImage: "circle",
                             checked: todo.priorityOverridden && todo.priorityEnum == .normal) {
                    state.setPriority(todo, .normal); dismiss()
                }
                SiftMenuItem(title: "Low", systemImage: "arrow.down.circle",
                             checked: todo.priorityOverridden && todo.priorityEnum == .low) {
                    state.setPriority(todo, .low); dismiss()
                }
            }

            SiftMenuDivider()
            SiftMenuItem(title: "Delete", systemImage: "trash", destructive: true) {
                state.delete(todo); dismiss()
            }
        }
    }

    /// Start of day, `days` from now — snooze wakes at that midnight.
    static func snoozeDate(days: Int) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: days, to: base) ?? Date().addingTimeInterval(Double(days) * 86400)
    }

    /// Indent for everything under the title line — checkbox (16) + its
    /// trailing pad (6) + the line's spacing (6).
    static let gutter: CGFloat = 28

    private var mainRow: some View {
        // The checkbox sits IN the title line and the whole line is
        // center-aligned, so circle, priority icon, title, and pills share one
        // vertical axis. Summary and sources indent to the gutter. Tapping the
        // row (outside the checkbox) opens the focused detail view.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: { state.markDone(todo) }) {
                    Image(systemName: checkHovering ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(checkHovering ? Color.themeAccent : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.borderless)
                .frame(width: 16)
                .padding(.trailing, 6)
                .onHover { h in
                    checkHovering = h
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                if todo.effectivePriority == .high {
                    Image(systemName: "exclamationmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .font(.system(size: 13, weight: .semibold))
                        .help("High priority")
                }
                Text(todo.title.redacting(settings.redactionEnabled))
                    .font(settings.titleFont())
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let label = todo.snoozeLabel { SnoozeBadge(label: label) }
                if let due = todo.dueDate, todo.isOpen, !todo.isSnoozed { DueBadge(date: due) }
                if todo.isInProgress && !todo.isSnoozed { InProgressBadge() }
                if todo.isStale { StaleBadge() }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { state.openDetail(todo) }

            VStack(alignment: .leading, spacing: 4) {
                if !todo.summary.isEmpty {
                    Text(todo.displaySummary.redacting(settings.redactionEnabled))
                        .font(settings.summaryFont())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SourcePill(todo: todo, font: settings.channelFont(), redacted: settings.redactionEnabled)
                    .padding(.top, 2)
            }
            .padding(.leading, Self.gutter)
            .contentShape(Rectangle())
            .onTapGesture { state.openDetail(todo) }
        }
    }
}

struct SourcePill: View {
    let todo: Todo
    let font: Font
    var redacted: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(todo.sourcePills) { pill in
                SingleSourcePill(pill: pill, font: font, redacted: redacted)
            }
        }
    }
}

private struct SingleSourcePill: View {
    let pill: Todo.SourcePill
    let font: Font
    var redacted: Bool = false
    @State private var hovering = false

    var body: some View {
        // Clickable: takes you straight to the source (Slack thread / Granola
        // note). Tapping the rest of the row opens the detail view instead.
        let hasLink = pill.url != nil
        let content = HStack(spacing: 4) {
            sourceIcon
            Text(redacted ? pill.label.redacting(true) : pill.label).font(font)
        }
        .foregroundStyle(hovering && hasLink ? Color.themeAccent : Color.secondary.opacity(0.75))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().solidTint(hovering && hasLink ? Color.themeAccent.opacity(0.12) : Color.secondary.opacity(0.08))
        )

        if let url = pill.url {
            Button { NSWorkspace.shared.open(url) } label: { content }
                .buttonStyle(.plain)
                .onHover { h in
                    hovering = h
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        switch pill.kind {
        case .granola:
            IntegrationLogoView(logo: .granola, size: 12)
        case .slackChannel, .slackDM:
            IntegrationLogoView(logo: .slack, size: 12)
        }
    }
}

struct InProgressBadge: View {
    static let adaptiveGreen = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.40, green: 0.78, blue: 0.50, alpha: 1)
            : NSColor(red: 0.18, green: 0.45, blue: 0.27, alpha: 1)
    })

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(Self.adaptiveGreen).frame(width: 5, height: 5)
            Text("In progress")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Self.adaptiveGreen)
        }
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Capsule().solidTint(Self.adaptiveGreen.opacity(0.16)))
    }
}

struct StaleBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 8, weight: .semibold))
            Text("Stale")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Capsule().solidTint(Color.orange.opacity(0.16)))
        .help("No activity for over \(Int(Todo.staleAfterDays)) days — will archive at \(Int(Todo.archiveAfterDays))")
    }
}

struct SnoozeBadge: View {
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 8, weight: .semibold))
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Capsule().solidTint(Color.secondary.opacity(0.14)))
        .help("Snoozed")
    }
}

struct DueBadge: View {
    let date: Date

    private var dueNow: Bool {
        Calendar.current.startOfDay(for: date) <= Calendar.current.startOfDay(for: Date())
    }

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Due today" }
        if date < Date() { return "Overdue" }
        if cal.isDateInTomorrow(date) { return "Due tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return "Due \(f.string(from: date))"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 8, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(dueNow ? Color.red : Color.secondary)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Capsule().solidTint((dueNow ? Color.red : Color.secondary).opacity(0.14)))
        .help("Deadline picked up from the thread")
    }
}


// MARK: - Detail panel

struct DetailPanel: View {
    let todo: Todo
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    private var recentNotes: [TodoComment] {
        Array(todo.comments.sorted(by: { $0.createdAt > $1.createdAt }).prefix(3))
    }

    private var priorityTint: Color {
        switch todo.effectivePriority {
        case .high: return .red
        case .normal: return .blue
        case .low: return .secondary
        }
    }

    /// The stored rationale — prefixed with the deadline when that's what
    /// elevated the priority, so the banner explains itself.
    private var priorityText: String? {
        let reason = todo.displayPriorityReason?.trimmingCharacters(in: .whitespaces)
        if todo.isDueNow && todo.priorityEnum != .high && !todo.priorityOverridden {
            let base = "A deadline set in the thread has arrived."
            if let reason, !reason.isEmpty { return "\(base) \(reason)" }
            return base
        }
        return (reason?.isEmpty == false) ? reason : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(todo.effectivePriority.rawValue.capitalized) priority")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(priorityTint)
                if let text = priorityText {
                    Text(text.redacting(settings.redactionEnabled))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(priorityTint.opacity(0.09))
            )

            // A short progress trail — the few meaningful status changes, not a
            // wall of every sync. The row's summary carries the current story.
            if !recentNotes.isEmpty {
                Text("Recent activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(recentNotes) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Color.secondary.opacity(0.4))
                                .frame(width: 4, height: 4).padding(.top, 6)
                            Text(c.body.redacting(settings.redactionEnabled))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.primary.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 6)
                            Text(relative(c.createdAt))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if !todo.extraSources.isEmpty {
                Text("Merged sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(todo.extraSources.sorted(by: { $0.mergedAt > $1.mergedAt })) { src in
                    MergedSourceRow(source: src, redacted: settings.redactionEnabled) {
                        state.unmerge(src)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .solidTint(Color.primary.opacity(0.05))
        )
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// A merged source: title + source label, with open + unmerge icon buttons
/// that reveal on hover.
struct MergedSourceRow: View {
    let source: TodoSource
    let redacted: Bool
    let onUnmerge: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title.redacting(redacted))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.85))
                Text(source.sourceLabel.redacting(redacted))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                if let url = source.sourceURL {
                    SiftButton(variant: .subtle, iconOnly: true) { NSWorkspace.shared.open(url) } content: {
                        IntegrationLogoView(logo: source.sourceKind == .granola ? .granola : .slack, size: 14)
                    }
                    .help(source.sourceKind == .granola ? "Open Granola note" : "Open in Slack")
                }
                SiftButton(variant: .subtle, iconOnly: true, action: onUnmerge) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .medium))
                }
                .help("Unmerge")
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0.04))
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

struct ActionPill: View {
    let label: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.primary : Color.primary.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(hovering ? Color.softFillHover : Color.softFill))
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
