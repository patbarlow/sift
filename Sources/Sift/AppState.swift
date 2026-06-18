import Foundation
import SwiftUI
import SwiftData
import AppKit

@MainActor
final class AppState: ObservableObject {
    let container: ModelContainer
    let settings: AppSettings

    @Published var lastReport: SyncWorker.Report?
    @Published var lastRefresh: Date?
    @Published var isSyncing: Bool = false
    @Published var activeTask: ActiveTask?
    enum ActiveTask: String { case sync, reevaluate, consolidate, memory }
    @Published var lastError: String?
    @Published var hasConfigured: Bool
    @Published var expandedTodoID: PersistentIdentifier?
    @Published var mainTab: MainTab = .todos
    // The confirm/input modal shown over the main window (nil = hidden).
    @Published var modal: SiftModalConfig?

    private var syncTimer: Timer?
    private var wakeObserver: Any?
    /// Don't run two scheduled syncs within this window (avoids a catch-up and
    /// an aligned tick firing back-to-back when you open the lid near a tick).
    private let minSyncGap: TimeInterval = 5 * 60

    /// When the scheduler will next fire (nil when not scheduled).
    var nextSyncDate: Date? { syncTimer?.fireDate }

    /// Last completed sync, persisted so catch-up survives quit/relaunch.
    private static let lastSyncKey = "sift.lastSyncAt"
    var lastSyncAt: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastSyncKey) }
    }

    init(container: ModelContainer, settings: AppSettings) {
        self.container = container
        self.settings = settings
        self.hasConfigured = Self.checkConfigured(settings: settings)
    }

    static func checkConfigured(settings: AppSettings) -> Bool {
        // Both task tiers' providers must be connected.
        let llmReady = settings.fastProvider.isConnected() && settings.smartProvider.isConnected()
        return llmReady
            && Keychain.read(SecretKey.slack) != nil
            && !settings.slackUserID.isEmpty
            && !settings.slackHandle.isEmpty
    }

    /// Re-evaluate configured state, e.g. after onboarding.
    func refreshConfigured() {
        hasConfigured = Self.checkConfigured(settings: settings)
    }

    /// Trigger a sync. Safe to call any time; debounced by isSyncing.
    func runSync() {
        guard !isSyncing else { return }
        guard let worker = SyncWorker(container: container, settings: settings) else {
            lastError = "Not configured yet — finish onboarding."
            return
        }
        isSyncing = true
        activeTask = .sync
        Task { [weak self] in
            let report = await worker.runOnce()
            await MainActor.run { [weak self] in
                self?.lastReport = report
                self?.activeTask = nil
                self?.lastRefresh = Date()
                self?.lastSyncAt = Date()
                self?.isSyncing = false
                if !report.errors.isEmpty {
                    self?.lastError = report.errors.joined(separator: "\n")
                }
            }
        }
    }

    /// Force-reassess every tracked todo now, bypassing the 12h gate.
    func reevaluateAll() {
        guard !isSyncing else { return }
        guard let worker = SyncWorker(container: container, settings: settings) else {
            lastError = "Not configured yet — finish onboarding."
            return
        }
        isSyncing = true
        activeTask = .reevaluate
        Task { [weak self] in
            let report = await worker.reevaluateAll()
            await MainActor.run { [weak self] in
                self?.lastReport = report
                self?.activeTask = nil
                self?.isSyncing = false
                if !report.errors.isEmpty {
                    self?.lastError = report.errors.joined(separator: "\n")
                }
            }
        }
    }

    /// Run the work-item consolidation pass on demand, independent of a sync.
    func runConsolidation() {
        guard !isSyncing else { return }
        guard let worker = SyncWorker(container: container, settings: settings) else {
            lastError = "Not configured yet — finish onboarding."
            return
        }
        isSyncing = true
        activeTask = .consolidate
        Task { [weak self] in
            let report = await worker.consolidateOnly()
            await MainActor.run { [weak self] in
                self?.lastReport = report
                self?.activeTask = nil
                self?.isSyncing = false
                if !report.errors.isEmpty {
                    self?.lastError = report.errors.joined(separator: "\n")
                }
            }
        }
    }

    /// Rebuild the background-context glossary on demand.
    func rebuildMemory() {
        guard !isSyncing else { return }
        guard let worker = SyncWorker(container: container, settings: settings) else {
            lastError = "Not configured yet — finish onboarding."
            return
        }
        isSyncing = true
        activeTask = .memory
        Task { [weak self] in
            let report = await worker.rebuildMemoryOnly()
            await MainActor.run { [weak self] in
                self?.lastReport = report
                self?.activeTask = nil
                self?.isSyncing = false
                if !report.errors.isEmpty {
                    self?.lastError = report.errors.joined(separator: "\n")
                }
            }
        }
    }

    /// Start the schedule: runs on aligned wall-clock boundaries (every N min on
    /// tidy times like :00/:30), and catches up on launch/wake if a run was
    /// missed while quit or asleep. `kickNow` forces an immediate sync (first
    /// connect). Cron-like, but local — it only fires while the app runs awake.
    func startScheduler(kickNow: Bool = false) {
        stopScheduler()
        armNextTick()
        observeWake()
        if kickNow { runSync() } else { catchUpIfNeeded() }
    }

    func stopScheduler() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    func restartSchedulerIfRunning() {
        if syncTimer != nil { armNextTick() }
    }

    private func intervalSeconds() -> TimeInterval {
        TimeInterval(max(5, settings.syncIntervalMinutes) * 60)
    }

    /// Next wall-clock boundary aligned to the interval, measured from midnight
    /// so runs land on tidy times (30 min → :00 / :30).
    private func nextAlignedDate(after date: Date = Date()) -> Date {
        let i = intervalSeconds()
        let midnight = Calendar.current.startOfDay(for: date)
        let elapsed = date.timeIntervalSince(midnight)
        return midnight.addingTimeInterval((floor(elapsed / i) + 1) * i)
    }

    /// One-shot timer for the next aligned boundary; re-arms itself each fire.
    private func armNextTick() {
        syncTimer?.invalidate()
        let timer = Timer(fire: nextAlignedDate(), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.scheduledSync()
                self?.armNextTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    /// A scheduled (non-manual) sync — skipped if one ran within `minSyncGap`,
    /// so a catch-up and an aligned tick can't fire two syncs back-to-back.
    private func scheduledSync() {
        guard !isSyncing else { return }
        if let last = lastSyncAt, Date().timeIntervalSince(last) < minSyncGap { return }
        runSync()
    }

    /// On launch / wake: if a full interval has elapsed since the last run (we
    /// were quit or asleep through a scheduled tick), sync now to backfill.
    private func catchUpIfNeeded() {
        if let last = lastSyncAt, Date().timeIntervalSince(last) < intervalSeconds() { return }
        scheduledSync()
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.armNextTick()       // re-align after sleep
                self?.catchUpIfNeeded()   // backfill the missed run
            }
        }
    }

    // MARK: - Todo actions

    func markDone(_ todo: Todo) {
        let id = todo.persistentModelID
        Task { @MainActor in
            let ctx = ModelContext(container)
            if let t = ctx.model(for: id) as? Todo {
                t.status = TodoStatus.done.rawValue
                t.completedAt = Date()
                t.updatedAt = Date()
                t.completionReason = "Manually marked as done"
                Activity.log(.manualDone, t.title, ctx: ctx)
                try? ctx.save()
            }
        }
    }

    /// Manually set a todo's priority. `nil` clears the override and hands it
    /// back to the assessor on the next sync.
    func setPriority(_ todo: Todo, _ priority: TodoPriority?) {
        let id = todo.persistentModelID
        Task { @MainActor in
            let ctx = ModelContext(container)
            guard let t = ctx.model(for: id) as? Todo else { return }
            if let priority {
                t.priority = priority.rawValue
                t.priorityOverridden = true
                t.priorityReason = "Priority set by you."
            } else {
                t.priorityOverridden = false
            }
            t.updatedAt = Date()
            try? ctx.save()
        }
    }

    /// Snooze until a date — the todo leaves the active lists until then.
    func snooze(_ todo: Todo, until date: Date) {
        applySnooze(todo, activity: .snoozed) { t in
            t.snoozedUntil = date
            t.snoozeWatchKey = nil
            t.snoozeBaselineTs = nil
        }
    }

    /// Snooze until new activity in a thread. `threadKey` nil watches the
    /// todo's own primary thread (the common "I asked in this thread" case).
    func snooze(_ todo: Todo, watching threadKey: String?) {
        applySnooze(todo, activity: .snoozed) { t in
            let key = threadKey ?? t.threadKey
            t.snoozeWatchKey = key
            t.snoozedUntil = nil
            // Baseline = what we've already seen in that thread, so only newer
            // messages wake it. For the todo's own thread that's lastSeenTs;
            // for a pasted thread we have no baseline, so any future message wakes it.
            t.snoozeBaselineTs = (key == t.threadKey) ? t.lastSeenTs : nil
        }
    }

    /// Parse a Slack message/thread URL into a "channelID:parentTs" key.
    func threadKey(fromSlackURL url: String) -> String? {
        guard let comps = URLComponents(string: url) else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard let archivesIdx = parts.firstIndex(of: "archives"), archivesIdx + 1 < parts.count else { return nil }
        let channel = parts[archivesIdx + 1]
        // Prefer thread_ts (the parent) when present; else the p<digits> message ts.
        if let threadTs = comps.queryItems?.first(where: { $0.name == "thread_ts" })?.value {
            return "\(channel):\(threadTs)"
        }
        guard let p = parts.last, p.hasPrefix("p"), p.count > 7 else { return nil }
        let digits = String(p.dropFirst())
        let secs = digits.prefix(digits.count - 6)
        let micros = digits.suffix(6)
        return "\(channel):\(secs).\(micros)"
    }

    private func applySnooze(_ todo: Todo, activity: ActivityKind? = nil, _ mutate: @escaping (Todo) -> Void) {
        let id = todo.persistentModelID
        Task { @MainActor in
            let ctx = ModelContext(container)
            guard let t = ctx.model(for: id) as? Todo else { return }
            mutate(t)
            t.updatedAt = Date()
            if let activity { Activity.log(activity, t.title, ctx: ctx) }
            try? ctx.save()
        }
    }

    /// Wake a snoozed todo back into the active lists.
    func unsnooze(_ todo: Todo) {
        applySnooze(todo, activity: .woke) { t in
            t.snoozedUntil = nil
            t.snoozeWatchKey = nil
            t.snoozeBaselineTs = nil
            t.lastActivityAt = Date()   // fresh, so it doesn't read as stale immediately
        }
    }

    /// Accept a review suggestion: promote a "for you" todo, perform a
    /// suggested merge, or mark a "maybe done" item done.
    func acceptReview(_ todo: Todo) {
        let id = todo.persistentModelID
        let kind = todo.reviewKindEnum
        let mergeKey = todo.reviewMergeIntoKey
        Task { @MainActor in
            let ctx = ModelContext(container)
            guard let t = ctx.model(for: id) as? Todo else { return }
            let title = t.title
            switch kind {
            case .forYou:
                t.pendingReview = false
                clearReview(t)
                Activity.log(.accepted, title, detail: "kept as todo", ctx: ctx)
            case .done:
                t.status = TodoStatus.done.rawValue
                t.completedAt = Date()
                t.completionReason = t.reviewReason ?? "Marked done from review"
                clearReview(t)
                Activity.log(.manualDone, title, detail: "from review", ctx: ctx)
            case .merge:
                if let key = mergeKey, let primary = todoByKey(key, ctx: ctx) {
                    fold(t, into: primary, ctx: ctx)
                    Activity.log(.merged, primary.title, detail: "from review", ctx: ctx)
                } else {
                    clearReview(t)   // primary vanished; just keep the todo
                }
            case .none:
                break
            }
            try? ctx.save()
        }
    }

    /// Decline a review suggestion: drop a "for you" item (and never re-suggest
    /// that thread), keep a "maybe done" item open, or keep a "merge" separate.
    func declineReview(_ todo: Todo) {
        let id = todo.persistentModelID
        let kind = todo.reviewKindEnum
        let key = todo.threadKey
        Task { @MainActor in
            let ctx = ModelContext(container)
            guard let t = ctx.model(for: id) as? Todo else { return }
            let title = t.title
            switch kind {
            case .forYou:
                if ((try? ctx.fetch(FetchDescriptor<IgnoredThread>(
                    predicate: #Predicate { $0.threadKey == key }))) ?? []).isEmpty {
                    ctx.insert(IgnoredThread(threadKey: key))
                }
                ctx.delete(t)
                Activity.log(.declined, title, detail: "not for you", ctx: ctx)
            case .done:
                t.reviewDismissedAt = Date()
                clearReview(t)
                Activity.log(.declined, title, detail: "kept open", ctx: ctx)
            case .merge:
                t.excludeFromAutoMerge = true
                clearReview(t)
                Activity.log(.declined, title, detail: "kept separate", ctx: ctx)
            case .none:
                break
            }
            try? ctx.save()
        }
    }

    private func clearReview(_ t: Todo) {
        t.reviewKind = nil
        t.reviewReason = nil
        t.reviewConfidence = 0
        t.reviewMergeIntoKey = nil
        t.updatedAt = Date()
    }

    private func todoByKey(_ key: String, ctx: ModelContext) -> Todo? {
        try? ctx.fetch(FetchDescriptor<Todo>(predicate: #Predicate { $0.threadKey == key })).first
    }

    /// Fold one todo into another as a merged source (mirrors consolidation).
    private func fold(_ todo: Todo, into primary: Todo, ctx: ModelContext) {
        let source = TodoSource(
            title: todo.title, summary: todo.summary, classification: todo.classification,
            status: todo.status, channelID: todo.channelID, channelName: todo.channelName,
            threadKey: todo.threadKey, sourceURL: todo.sourceURL,
            lastActivity: todo.lastSlackActivity, lastSeenTs: todo.lastSeenTs
        )
        source.todo = primary
        ctx.insert(source)
        for s in todo.extraSources { s.todo = primary }
        for c in todo.comments { c.todo = primary }
        ctx.delete(todo)
        if todo.priorityEnum < primary.priorityEnum { primary.priority = todo.priority }
        primary.updatedAt = Date()
        primary.lastActivityAt = Date()
    }

    /// Permanently removes a todo from the database (along with its comments).
    func delete(_ todo: Todo) {
        let id = todo.persistentModelID
        Task { @MainActor in
            let ctx = ModelContext(container)
            guard let t = ctx.model(for: id) as? Todo else { return }
            // Delete means "this isn't a todo" — ignore its thread(s) so the next
            // sync doesn't just recreate it. A merged todo covers several threads.
            let keys = Set(([t.threadKey] + t.extraSources.map(\.threadKey)).filter { !$0.isEmpty })
            for key in keys where ((try? ctx.fetch(FetchDescriptor<IgnoredThread>(
                predicate: #Predicate { $0.threadKey == key }))) ?? []).isEmpty {
                ctx.insert(IgnoredThread(threadKey: key))
            }
            ctx.delete(t)
            try? ctx.save()
        }
    }

    /// Split a merged source back out into its own standalone todo. The
    /// reconstituted todo is flagged so the consolidation pass won't
    /// immediately re-merge it.
    func unmerge(_ source: TodoSource) {
        let id = source.persistentModelID
        Task { @MainActor in
            let ctx = ModelContext(container)
            guard let s = ctx.model(for: id) as? TodoSource else { return }
            let restored = Todo(
                threadKey: s.threadKey,
                title: s.title,
                summary: s.summary,
                classification: s.classification,
                status: s.status,
                channelID: s.channelID,
                channelName: s.channelName,
                sourceURL: s.sourceURL,
                lastSlackActivity: s.lastActivity,
                lastSeenTs: s.lastSeenTs
            )
            restored.excludeFromAutoMerge = true
            ctx.insert(restored)
            ctx.delete(s)
            Activity.log(.unmerged, restored.title, ctx: ctx)
            try? ctx.save()
        }
    }

    func toggleExpanded(_ todo: Todo) {
        if expandedTodoID == todo.persistentModelID {
            expandedTodoID = nil
        } else {
            expandedTodoID = todo.persistentModelID
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private static let prefix = "Sift."

    @Published var slackUserID: String {
        didSet { UserDefaults.standard.set(slackUserID, forKey: Self.prefix + "slackUserID") }
    }
    @Published var slackHandle: String {
        didSet { UserDefaults.standard.set(slackHandle, forKey: Self.prefix + "slackHandle") }
    }
    @Published var slackTeamID: String {
        didSet { UserDefaults.standard.set(slackTeamID, forKey: Self.prefix + "slackTeamID") }
    }
    /// How Slack was connected: "oauth", "manual", or "" if not connected.
    @Published var slackAuthMethod: String {
        didSet { UserDefaults.standard.set(slackAuthMethod, forKey: Self.prefix + "slackAuthMethod") }
    }
    @Published var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: Self.prefix + "displayName") }
    }
    @Published var email: String {
        didSet { UserDefaults.standard.set(email, forKey: Self.prefix + "email") }
    }
    @Published var aliases: String {
        didSet { UserDefaults.standard.set(aliases, forKey: Self.prefix + "aliases") }
    }
    @Published var granolaConfigured: Bool {
        didSet { UserDefaults.standard.set(granolaConfigured, forKey: Self.prefix + "granolaConfigured") }
    }

    /// Newline-separated list of names the assistant should treat as the user.
    /// Used in prompts for "is this assigned to me?" detection.
    var identityNames: [String] {
        var names: [String] = []
        let dn = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dn.isEmpty { names.append(dn) }
        let handle = slackHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !handle.isEmpty { names.append("@\(handle)") }
        let em = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !em.isEmpty { names.append(em) }
        for alias in aliases.split(separator: ",") {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names.append(trimmed) }
        }
        return names
    }
    @Published var syncIntervalMinutes: Int {
        didSet { UserDefaults.standard.set(syncIntervalMinutes, forKey: Self.prefix + "syncIntervalMinutes") }
    }
    @Published var redactionEnabled: Bool {
        didSet { UserDefaults.standard.set(redactionEnabled, forKey: Self.prefix + "redactionEnabled") }
    }
    @Published var userContext: String {
        didSet { UserDefaults.standard.set(userContext, forKey: Self.prefix + "userContext") }
    }
    @Published var fontChoice: FontChoice {
        didSet { UserDefaults.standard.set(fontChoice.rawValue, forKey: Self.prefix + "fontChoice") }
    }
    @Published var themeID: String {
        didSet {
            UserDefaults.standard.set(themeID, forKey: Self.prefix + "themeID")
            ThemeBox.current = SiftTheme.theme(id: themeID)
        }
    }
    @Published var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.prefix + "appearanceMode") }
    }

    var theme: SiftTheme { SiftTheme.theme(id: themeID) }
    @Published var groupingMode: TodoGrouping {
        didSet { UserDefaults.standard.set(groupingMode.rawValue, forKey: Self.prefix + "groupingMode") }
    }
    // Each Sift task tier maps to a provider + model, which can differ across
    // providers (e.g. Groq for fast classification, Anthropic for smart summaries).
    @Published var fastProvider: LLMProviderKind {
        didSet { UserDefaults.standard.set(fastProvider.rawValue, forKey: Self.prefix + "fastProvider") }
    }
    @Published var fastModel: String {
        didSet { UserDefaults.standard.set(fastModel, forKey: Self.prefix + "fastModel") }
    }
    @Published var smartProvider: LLMProviderKind {
        didSet { UserDefaults.standard.set(smartProvider.rawValue, forKey: Self.prefix + "smartProvider") }
    }
    @Published var smartModel: String {
        didSet { UserDefaults.standard.set(smartModel, forKey: Self.prefix + "smartModel") }
    }

    init() {
        let d = UserDefaults.standard
        self.slackUserID = d.string(forKey: Self.prefix + "slackUserID") ?? ""
        self.slackHandle = d.string(forKey: Self.prefix + "slackHandle") ?? ""
        self.slackTeamID = d.string(forKey: Self.prefix + "slackTeamID") ?? ""
        self.slackAuthMethod = d.string(forKey: Self.prefix + "slackAuthMethod") ?? ""
        self.displayName = d.string(forKey: Self.prefix + "displayName") ?? ""
        self.email = d.string(forKey: Self.prefix + "email") ?? ""
        self.aliases = d.string(forKey: Self.prefix + "aliases") ?? ""
        self.granolaConfigured = d.bool(forKey: Self.prefix + "granolaConfigured")
        // Default to 60 minute syncs
        let stored = d.integer(forKey: Self.prefix + "syncIntervalMinutes")
        self.syncIntervalMinutes = stored == 0 ? 60 : stored
        self.redactionEnabled = d.bool(forKey: Self.prefix + "redactionEnabled")
        self.userContext = d.string(forKey: Self.prefix + "userContext") ?? ""
        let raw = d.string(forKey: Self.prefix + "fontChoice") ?? FontChoice.system.rawValue
        self.fontChoice = FontChoice(rawValue: raw) ?? .system
        self.themeID = d.string(forKey: Self.prefix + "themeID") ?? "default"
        self.appearanceMode = AppearanceMode(rawValue: d.string(forKey: Self.prefix + "appearanceMode") ?? "") ?? .system
        ThemeBox.current = SiftTheme.theme(id: d.string(forKey: Self.prefix + "themeID") ?? "default")
        let groupRaw = d.string(forKey: Self.prefix + "groupingMode") ?? TodoGrouping.none.rawValue
        self.groupingMode = TodoGrouping(rawValue: groupRaw) ?? .none
        // Migrate from the old single-provider settings if present.
        let legacyProvider = LLMProviderKind(rawValue: d.string(forKey: Self.prefix + "llmProvider") ?? "") ?? .anthropic
        let fp = LLMProviderKind(rawValue: d.string(forKey: Self.prefix + "fastProvider") ?? "") ?? legacyProvider
        let sp = LLMProviderKind(rawValue: d.string(forKey: Self.prefix + "smartProvider") ?? "") ?? legacyProvider
        self.fastProvider = fp
        self.smartProvider = sp
        self.fastModel = d.string(forKey: Self.prefix + "fastModel")
            ?? d.string(forKey: Self.prefix + "llmFastModel") ?? fp.defaultFastModel
        self.smartModel = d.string(forKey: Self.prefix + "smartModel")
            ?? d.string(forKey: Self.prefix + "llmSmartModel") ?? sp.defaultSmartModel
    }
}

enum TodoGrouping: String, CaseIterable, Identifiable {
    case none
    case channel
    case status
    case createdDate
    case updatedDate

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "No grouping"
        case .channel: return "Channel"
        case .status: return "Status"
        case .createdDate: return "Created"
        case .updatedDate: return "Last updated"
        }
    }
}

/// Buckets a date into a friendly label for grouping by date.
enum DateBucket {
    static func label(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start
        // Earlier this week: same ISO week as today, before yesterday.
        if let weekStart, date >= weekStart {
            return "Earlier this week"
        }
        // Last week: the seven days before this week's start.
        if let weekStart, let lastWeekStart = cal.date(byAdding: .day, value: -7, to: weekStart),
           date >= lastWeekStart {
            return "Last week"
        }
        if let monthStart = cal.dateInterval(of: .month, for: now)?.start, date >= monthStart {
            return "Earlier this month"
        }
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    /// Sort order for date buckets — most recent first.
    static func sortKey(for label: String) -> Int {
        switch label {
        case "Today": return 0
        case "Yesterday": return 1
        case "Earlier this week": return 2
        case "Last week": return 3
        case "Earlier this month": return 4
        default:
            // Month-year strings sort after the fixed buckets (>3), most
            // recent month first. Larger timeInterval (more recent) → smaller
            // key, and the whole range stays positive and above the buckets.
            let f = DateFormatter()
            f.dateFormat = "MMMM yyyy"
            if let d = f.date(from: label) {
                return Int.max - Int(d.timeIntervalSince1970)
            }
            return Int.max
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum FontChoice: String, CaseIterable, Identifiable {
    case system
    case sfMonoTerminal

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "System"
        case .sfMonoTerminal: return "SF Mono Terminal"
        }
    }
}
