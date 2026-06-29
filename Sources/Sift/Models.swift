import Foundation
import SwiftData

/// A single tracked todo or update, sourced from a Slack thread (or, later,
/// other sources). The thread key uniquely identifies the source.
@Model
final class Todo {
    @Attribute(.unique) var threadKey: String  // "<channel_id>:<parent_ts>"
    var title: String
    var summary: String
    var classification: String  // "todo" | "update"
    var status: String          // "open" | "in_progress" | "done"
    var channelID: String
    var channelName: String
    var sourceURL: URL?

    var lastSlackActivity: Date
    var lastSeenTs: String      // last Slack message ts we've already processed
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var completionReason: String?  // populated when status moves to "done"

    // WIP detection — populated when the routine detects active work in
    // another thread (or just in this one).
    var workingChannel: String?
    var workingQuote: String?
    var workingThreadURL: URL?
    var workingDetectedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \TodoComment.todo)
    var comments: [TodoComment] = []

    // Additional sources merged into this todo by the consolidation pass.
    // The todo's own channelID/threadKey/etc. are the primary (first) source.
    @Relationship(deleteRule: .cascade, inverse: \TodoSource.todo)
    var extraSources: [TodoSource] = []

    // Set when the user splits this todo back out of a merge, so the
    // consolidation pass won't immediately re-merge it.
    var excludeFromAutoMerge: Bool = false

    // Assessed urgency. "high" is reserved for someone-blocked-on-you /
    // deadline-soon; most todos stay "normal" so the signal means something.
    var priority: String = "normal"
    // One-sentence rationale from the assessor, shown in the expanded view.
    var priorityReason: String?
    // Set when the user picks the priority by hand — reassessment then leaves
    // priority alone (and the auto deadline-elevation is suppressed).
    var priorityOverridden: Bool = false

    // Which external customer this work item is about (derived from the
    // channel name or external participants' email domains). nil = internal.
    // Used to keep different customers' work from merging.
    var customer: String?

    // Compact "who's in the thread" snapshot (name + company/colleague), from
    // Slack user info. Grounds the memory rebuild's people + organizations.
    var participantsNote: String?

    // Review queue: when the app isn't confident about a decision it surfaces
    // it for the user to accept/decline instead of acting silently.
    // reviewKind: nil | "for_you" | "merge" | "done".
    var reviewKind: String?
    var reviewReason: String?            // one line: why we think this
    var reviewConfidence: Double = 0     // 0..1
    var reviewMergeIntoKey: String?      // for "merge": the primary todo's threadKey
    // "for_you" suggestions live here un-confirmed and stay out of every normal
    // list until accepted.
    var pendingReview: Bool = false
    // After declining a "done" suggestion, don't re-suggest until fresh activity.
    var reviewDismissedAt: Date?

    // Snooze: park the todo out of the active lists until a wake condition.
    // Either a date (`snoozedUntil`) or new activity in a watched thread
    // (`snoozeWatchKey`, compared against `snoozeBaselineTs`).
    var snoozedUntil: Date?
    var snoozeWatchKey: String?
    var snoozeBaselineTs: String?
    // Set when the user manually wakes an auto-snoozed (waiting-on-others) todo,
    // so the assessor won't keep re-parking it.
    var autoSnoozeOptOut: Bool = false
    // True when the sync closed/archived this itself (vs. the user marking it
    // done) — drives the "Auto-completed" pill in the Completed list.
    var autoCompleted: Bool = false
    // Deadline extracted from the thread ("I'll do it tomorrow", "by Friday").
    // Once this day arrives, the todo is treated as high priority.
    var dueDate: Date?

    // Clock for staleness: the last time real external activity touched this
    // todo (creation, new thread message, or a merge) — NOT our own periodic
    // reassessments. Nil on rows created before this field existed; falls back
    // to lastSlackActivity.
    var lastActivityAt: Date?

    enum SourceKind {
        case slackChannel
        case slackDM
        case granola
    }

    var sourceKind: SourceKind {
        if channelID.hasPrefix("granola:") { return .granola }
        if channelID.hasPrefix("D") || channelID.hasPrefix("G") { return .slackDM }
        // Group DMs can have C-prefixed IDs; detect by resolved name pattern
        // (no channel has a comma-separated name like "Alice, Bob").
        if channelName.contains(", ") && !channelName.hasPrefix("#") { return .slackDM }
        return .slackChannel
    }

    /// Display label for the source pill (no # for DMs/Granola).
    var sourceLabel: String {
        switch sourceKind {
        case .slackChannel: return "#\(channelName)"
        case .slackDM: return channelName
        case .granola: return channelName
        }
    }

    /// One pill per contributing source: the todo's own (primary) plus any
    /// merged-in extras.
    struct SourcePill: Identifiable {
        let id: String        // threadKey
        let kind: SourceKind
        let label: String
        let url: URL?
    }

    /// One pill per distinct source label. Several sources often share a
    /// channel (different threads in #foo), so we collapse by label — the
    /// individual threads remain available under "Merged sources".
    var sourcePills: [SourcePill] {
        var seen = Set<String>()
        var pills: [SourcePill] = []
        func add(_ p: SourcePill) {
            if seen.insert(p.label).inserted { pills.append(p) }
        }
        add(SourcePill(id: threadKey, kind: sourceKind, label: sourceLabel, url: sourceURL))
        for s in extraSources.sorted(by: { $0.lastActivity < $1.lastActivity }) {
            add(SourcePill(id: s.threadKey, kind: s.sourceKind, label: s.sourceLabel, url: s.sourceURL))
        }
        return pills
    }

    init(threadKey: String,
         title: String,
         summary: String,
         classification: String,
         status: String = "open",
         channelID: String,
         channelName: String,
         sourceURL: URL?,
         lastSlackActivity: Date,
         lastSeenTs: String,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.threadKey = threadKey
        self.title = title
        self.summary = summary
        self.classification = classification
        self.status = status
        self.channelID = channelID
        self.channelName = channelName
        self.sourceURL = sourceURL
        self.lastSlackActivity = lastSlackActivity
        self.lastSeenTs = lastSeenTs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivityAt = createdAt
    }
}

/// A source thread/meeting merged into a Todo by the consolidation pass.
/// Holds a full snapshot of the original todo so an unmerge can reconstitute
/// it as a standalone Todo.
@Model
final class TodoSource {
    var title: String
    var summary: String
    var classification: String
    var status: String
    var channelID: String
    var channelName: String
    @Attribute(.unique) var threadKey: String
    var sourceURL: URL?
    var lastActivity: Date
    var lastSeenTs: String
    var mergedAt: Date
    var todo: Todo?

    init(title: String,
         summary: String,
         classification: String,
         status: String,
         channelID: String,
         channelName: String,
         threadKey: String,
         sourceURL: URL?,
         lastActivity: Date,
         lastSeenTs: String,
         mergedAt: Date = Date()) {
        self.title = title
        self.summary = summary
        self.classification = classification
        self.status = status
        self.channelID = channelID
        self.channelName = channelName
        self.threadKey = threadKey
        self.sourceURL = sourceURL
        self.lastActivity = lastActivity
        self.lastSeenTs = lastSeenTs
        self.mergedAt = mergedAt
    }

    var sourceKind: Todo.SourceKind {
        if channelID.hasPrefix("granola:") { return .granola }
        if channelID.hasPrefix("D") || channelID.hasPrefix("G") { return .slackDM }
        if channelName.contains(", ") && !channelName.hasPrefix("#") { return .slackDM }
        return .slackChannel
    }

    var sourceLabel: String {
        switch sourceKind {
        case .slackChannel: return "#\(channelName)"
        case .slackDM, .granola: return channelName
        }
    }
}

/// Comment / update on a todo. The auto-triage notes the worker writes are
/// just comments with `isAutoTriage = true`.
@Model
final class TodoComment {
    var todo: Todo?
    var body: String
    var isAutoTriage: Bool
    var createdAt: Date

    init(todo: Todo? = nil,
         body: String,
         isAutoTriage: Bool = false,
         createdAt: Date = Date()) {
        self.todo = todo
        self.body = body
        self.isAutoTriage = isAutoTriage
        self.createdAt = createdAt
    }
}

/// User-configured Slack channel to watch (for messages where the user isn't
/// explicitly @mentioned but might still be the natural responder).
@Model
final class WatchedChannel {
    @Attribute(.unique) var channelID: String
    var name: String
    var addedAt: Date

    init(channelID: String, name: String, addedAt: Date = Date()) {
        self.channelID = channelID
        self.name = name
        self.addedAt = addedAt
    }
}

/// Channels to ignore when scanning for @mentions. Useful for aggregator
/// channels like `#support-triage` that re-post mentions from other channels
/// and would otherwise create duplicate todos.
@Model
final class IgnoredMentionChannel {
    @Attribute(.unique) var channelID: String
    var name: String
    var addedAt: Date

    init(channelID: String, name: String, addedAt: Date = Date()) {
        self.channelID = channelID
        self.name = name
        self.addedAt = addedAt
    }
}

/// Records a Granola meeting we've already extracted todos from. Granola
/// notes don't change after creation, so once a meeting is processed we skip
/// it on every future sync — no re-extraction, no duplicate todos.
@Model
final class ProcessedGranolaMeeting {
    @Attribute(.unique) var meetingID: String  // Granola note ID, e.g. "not_XXX"
    var processedAt: Date

    init(meetingID: String, processedAt: Date = Date()) {
        self.meetingID = meetingID
        self.processedAt = processedAt
    }
}

/// Sync cursor — last-known Slack timestamp per source (mention search,
/// per-channel scans). Updated atomically at the end of each successful run.
@Model
final class SyncCursor {
    @Attribute(.unique) var key: String  // "mentions" or "channel:<ID>"
    var cursor: String                   // Slack ts as string, e.g. "1779158834.607209"

    init(key: String, cursor: String) {
        self.key = key
        self.cursor = cursor
    }
}

enum TodoPriority: String, Comparable {
    case high
    case normal
    case low

    /// Sort rank — high first.
    private var rank: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

extension Todo {
    var statusEnum: TodoStatus {
        TodoStatus(rawValue: status) ?? .open
    }
    var reviewKindEnum: ReviewKind? {
        reviewKind.flatMap { ReviewKind(rawValue: $0) }
    }
    /// Has a pending suggestion to surface in the Review tab.
    var needsReview: Bool { reviewKindEnum != nil }
    var priorityEnum: TodoPriority {
        TodoPriority(rawValue: priority) ?? .normal
    }

    /// True once the stored deadline's day has arrived (or passed).
    var isDueNow: Bool {
        guard let dueDate, isOpen else { return false }
        return Calendar.current.startOfDay(for: dueDate)
            <= Calendar.current.startOfDay(for: Date())
    }

    /// Priority as it should act right now. A manual override wins outright;
    /// otherwise a reached deadline elevates to high.
    var effectivePriority: TodoPriority {
        if priorityOverridden { return priorityEnum }
        return isDueNow ? .high : priorityEnum
    }

    /// A live, relative phrase for a date — "today", "tomorrow", "yesterday",
    /// a weekday within the week, else "d MMM". Used to fill the {due} token.
    static func relativeDayPhrase(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: date)).day ?? 0
        let f = DateFormatter()
        f.dateFormat = abs(days) <= 6 ? "EEEE" : "d MMM"
        return f.string(from: date)
    }

    /// Replace the {due} token the assessor emits with the live relative date,
    /// computed fresh each render so "today" becomes "yesterday" as time passes.
    func fillingDates(_ text: String) -> String {
        guard text.contains("{due}") else { return text }
        let phrase = dueDate.map { Todo.relativeDayPhrase(for: $0) } ?? "soon"
        return text.replacingOccurrences(of: "{due}", with: phrase)
    }
    var displaySummary: String { fillingDates(summary) }
    var displayPriorityReason: String? { priorityReason.map { fillingDates($0) } }
    var classificationEnum: TodoClassification {
        TodoClassification(rawValue: classification) ?? .todo
    }
    var isInProgress: Bool {
        statusEnum == .inProgress || workingChannel != nil
    }
    var isOpen: Bool {
        statusEnum == .open || statusEnum == .inProgress
    }

    /// The next move is someone else's — parked but still tracked. A pure
    /// status, distinct from the snooze overlay.
    var isWaiting: Bool { statusEnum == .waiting }

    /// Everything still being tracked (not done/archived) — the set that can
    /// go stale, be swept, or be refreshed.
    var isActive: Bool { isOpen || isWaiting }

    /// Days of inactivity after which an active todo is flagged stale, and
    /// after which a stale todo is auto-archived.
    static let staleAfterDays: Double = 7
    static let archiveAfterDays: Double = 10  // 7 stale + 3 grace

    /// When real external activity last touched this todo. Falls back to Slack
    /// activity for rows created before the field existed.
    var activityClock: Date { lastActivityAt ?? lastSlackActivity }

    /// Active but quiet for a week — still tracked and revivable, just flagged.
    /// Applies to waiting items too: a parked item whose reply never came goes
    /// cold like any other.
    var isStale: Bool {
        guard isActive else { return false }
        return Date().timeIntervalSince(activityClock) > Self.staleAfterDays * 86400
    }

    /// Parked until a wake condition — hidden from Todos/Stale, shown in
    /// the Snoozed view. Only meaningful while open.
    var isSnoozed: Bool {
        isOpen && (snoozedUntil != nil || snoozeWatchKey != nil)
    }

    /// Human label for what the snooze is waiting on.
    var snoozeLabel: String? {
        guard isSnoozed else { return nil }
        if let until = snoozedUntil {
            return "Until \(Todo.relativeDayPhrase(for: until))"
        }
        return "Until a reply"
    }
}

enum TodoStatus: String {
    case open
    case inProgress = "in_progress"
    case waiting
    case done
    case archived
}

enum ReviewKind: String {
    case forYou = "for_you"
    case merge
    case done

    var sectionTitle: String {
        switch self {
        case .forYou: return "Might be for you"
        case .merge: return "Might be the same work"
        case .done: return "Might be done"
        }
    }
}

/// A single entry in the running activity log.
@Model
final class ActivityEvent {
    var kindRaw: String
    var title: String        // snapshot, so it survives the todo being deleted
    var detail: String?
    var createdAt: Date
    init(kind: ActivityKind, title: String, detail: String? = nil, createdAt: Date = Date()) {
        self.kindRaw = kind.rawValue
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
    }
    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .created }
}

enum ActivityKind: String {
    case created, review, merged, snoozed, woke, autoDone, manualDone, reopened, archived, accepted, declined, unmerged, parked

    var verb: String {
        switch self {
        case .created: return "New todo"
        case .review: return "Added to review"
        case .merged: return "Merged"
        case .snoozed: return "Snoozed"
        case .woke: return "Woke"
        case .autoDone: return "Auto-completed"
        case .manualDone: return "Completed"
        case .reopened: return "Reopened"
        case .archived: return "Archived"
        case .accepted: return "Accepted suggestion"
        case .declined: return "Declined suggestion"
        case .unmerged: return "Unmerged"
        case .parked: return "Waiting on others"
        }
    }

    var systemImage: String {
        switch self {
        case .created: return "plus.circle"
        case .review: return "questionmark.circle"
        case .merged: return "arrow.triangle.merge"
        case .snoozed: return "moon.zzz"
        case .woke: return "bell"
        case .autoDone, .manualDone: return "checkmark.circle"
        case .reopened: return "arrow.uturn.backward.circle"
        case .archived: return "archivebox"
        case .accepted: return "checkmark"
        case .declined: return "xmark"
        case .unmerged: return "arrow.uturn.backward"
        case .parked: return "hourglass"
        }
    }
}

/// Append-only activity log writer. Caps history so it can't grow unbounded.
enum Activity {
    static func log(_ kind: ActivityKind, _ title: String, detail: String? = nil, ctx: ModelContext) {
        ctx.insert(ActivityEvent(kind: kind, title: title, detail: detail))
        let count = (try? ctx.fetchCount(FetchDescriptor<ActivityEvent>())) ?? 0
        if count > 600 {
            let old = (try? ctx.fetch(FetchDescriptor<ActivityEvent>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]))) ?? []
            for e in old.prefix(count - 500) { ctx.delete(e) }
        }
    }
}

/// A Slack thread the user declined as "not for me" — so it isn't re-suggested.
@Model
final class IgnoredThread {
    @Attribute(.unique) var threadKey: String
    var ignoredAt: Date
    init(threadKey: String, ignoredAt: Date = Date()) {
        self.threadKey = threadKey
        self.ignoredAt = ignoredAt
    }
}

/// A learned background-context entry: a recurring person, organization,
/// project, or term in the user's work. Rebuilt periodically from recent
/// todos and fed into the LLM prompts so summaries and judgments are grounded.
/// Generic by design — nothing here is specific to any one workplace.
@Model
final class MemoryEntry {
    var kindRaw: String
    var name: String
    var detail: String
    var pinned: Bool      // user-added or kept; survives auto-rebuild and pruning
    var mentions: Int
    var lastSeen: Date
    var createdAt: Date
    // Only surfaced (in the Context tab + fed to prompts) once corroborated by
    // more than one todo or seen across more than one rebuild — so a single
    // point-in-time todo can't mint a shaky "fact". Defaults true so existing
    // entries and user-added ones stay visible.
    var confirmed: Bool = true

    init(kind: MemoryKind, name: String, detail: String,
         pinned: Bool = false, mentions: Int = 1, lastSeen: Date = Date(),
         confirmed: Bool = true) {
        self.kindRaw = kind.rawValue
        self.name = name
        self.detail = detail
        self.pinned = pinned
        self.mentions = mentions
        self.lastSeen = lastSeen
        self.createdAt = Date()
        self.confirmed = confirmed
    }

    var kind: MemoryKind { MemoryKind(rawValue: kindRaw) ?? .term }
}

enum MemoryKind: String, CaseIterable {
    case person
    case organization
    case project
    case term

    var label: String {
        switch self {
        case .person: return "People"
        case .organization: return "Organizations"
        case .project: return "Projects"
        case .term: return "Terms"
        }
    }

    var singular: String {
        switch self {
        case .person: return "Person"
        case .organization: return "Organization"
        case .project: return "Project"
        case .term: return "Term"
        }
    }
}

enum TodoClassification: String {
    case todo
    case update
}
