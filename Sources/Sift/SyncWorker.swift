import Foundation
import SwiftData
import CryptoKit

/// Orchestrates a single sync pass. Designed for low LLM cost but correct
/// status judgement:
/// - Every candidate gets its full thread fetched once, so the model sees
///   any prior user responses + teammate replies.
/// - `<@U…>` mentions are resolved to display names before they hit any LLM.
/// - Haiku assesses each thread (skip / open / in_progress / done) using the
///   full context; Sonnet only fires when we're keeping an item.
/// - The same Haiku assessor is used for the refresh pass — a single source
///   of truth for "what's the current state of this thread?"
@MainActor
final class SyncWorker {
    struct Report: Sendable {
        var newMentions: Int = 0
        var newFromWatchedChannels: Int = 0
        var newFromDMs: Int = 0
        var refreshed: Int = 0
        var autoClosed: Int = 0
        var movedInProgress: Int = 0
        var mergedSources: Int = 0
        var archived: Int = 0
        var memoryEntries: Int = 0
        var errors: [String] = []
        var durationSeconds: Double = 0
    }

    private let container: ModelContainer
    private let settings: AppSettings
    private let slack: SlackClient
    private let llm: LLMProvider
    private let granola: GranolaClient?

    /// Process-wide caches for the duration of a single run.
    private var userNameCache: [String: String] = [:]
    private var threadCache: [String: [SlackClient.Message]] = [:]
    private var channelNameCache: [String: String] = [:]
    /// Per-user company: "" = internal colleague, otherwise the company name
    /// from their email domain. Cached per run.
    private var companyCache: [String: String] = [:]
    /// Rendered background-context glossary, loaded once per run and appended to
    /// every assessment/summary prompt via `systemPrompt`.
    private var memoryContext: String = ""
    /// Upcoming meetings (next ~36h), loaded once per run — lets the assessor
    /// raise priority on todos a meeting depends on.

    init?(container: ModelContainer, settings: AppSettings) {
        guard let slackToken = Keychain.read(SecretKey.slack),
              !settings.slackUserID.isEmpty,
              !settings.slackHandle.isEmpty else {
            return nil
        }

        // Each task tier maps to a provider+model (possibly different providers).
        func build(_ provider: LLMProviderKind, _ model: String) -> LLMProvider? {
            if !provider.needsAPIKey { return provider.makeProvider(apiKey: "", model: model) }
            guard let key = Keychain.read(provider.keychainKey), !key.isEmpty else { return nil }
            return provider.makeProvider(apiKey: key, model: model)
        }
        guard let fastLLM = build(settings.fastProvider, settings.fastModel),
              let smartLLM = build(settings.smartProvider, settings.smartModel) else {
            return nil
        }

        self.container = container
        self.settings = settings
        self.slack = SlackClient(token: slackToken)
        self.llm = RoutingLLM(fast: fastLLM, smart: smartLLM)
        if settings.granolaConfigured, let key = Keychain.read(SecretKey.granola), !key.isEmpty {
            self.granola = GranolaClient(apiKey: key)
        } else {
            self.granola = nil
        }
    }

    func runOnce() async -> Report {
        let start = Date()
        var report = Report()
        let ctx = ModelContext(container)
        loadMemoryContext(ctx: ctx)

        do {
            try await scanMentions(ctx: ctx, report: &report)
            try await scanWatchedChannels(ctx: ctx, report: &report)
            try await scanDMs(ctx: ctx, report: &report)
            try await scanParticipantThreads(ctx: ctx, report: &report)
            if granola != nil {
                try await scanGranolaMeetings(ctx: ctx, report: &report)
            }
            try await refreshTracked(ctx: ctx, report: &report)
            // Free timestamp-only pass: retire todos quiet for too long.
            archiveStaleTodos(ctx: ctx, report: &report)
            // Only cluster when this run actually added todos — avoids
            // re-running an expensive LLM pass over an unchanged list.
            let addedThisRun = report.newMentions + report.newFromWatchedChannels + report.newFromDMs
            if addedThisRun > 0 {
                await consolidateOpenTodos(ctx: ctx, report: &report)
            }
            // Refresh the background-context glossary roughly daily.
            if memoryRebuildDue(ctx: ctx) {
                await rebuildMemory(ctx: ctx, report: &report)
            }
            try ctx.save()
        } catch {
            report.errors.append("\(error.localizedDescription)")
        }

        report.durationSeconds = Date().timeIntervalSince(start)
        return report
    }

    /// Run only the work-item consolidation pass (no Slack/Granola scan).
    /// Used by the "Consolidate now" action.
    func consolidateOnly() async -> Report {
        var report = Report()
        let ctx = ModelContext(container)
        loadMemoryContext(ctx: ctx)
        await consolidateOpenTodos(ctx: ctx, report: &report)
        try? ctx.save()
        return report
    }

    /// Rebuild the background-context glossary on demand (the "Rebuild" button),
    /// ignoring the daily cadence.
    func rebuildMemoryOnly() async -> Report {
        var report = Report()
        let ctx = ModelContext(container)
        await rebuildMemory(ctx: ctx, report: &report)
        try? ctx.save()
        return report
    }

    // MARK: - Background-context memory

    private static let memoryCursorKey = "memoryRebuild"

    /// True if the glossary hasn't been rebuilt in ~20h (so a daily-ish sync
    /// refreshes it without re-running on every sync).
    private func memoryRebuildDue(ctx: ModelContext) -> Bool {
        guard let last = readCursor(key: Self.memoryCursorKey, ctx: ctx),
              let date = Self.parseDate(last) else { return true }
        return Date().timeIntervalSince(date) > 20 * 3600
    }

    private static let memoryExtractSystem = """
    You maintain a compact, durable glossary of the recurring entities in
    someone's work, to give an assistant reliable background context for
    triaging their todos.

    Each todo is numbered and may carry hard facts pulled from Slack:
      · "about: X" — the customer/org the thread concerns.
      · "people: Name (Company), Name (colleague)" — who is in the thread, from
        their Slack profile. "(colleague)" means the same workspace as the user;
        a company name means an external contact at that company.

    Extract the people, organizations, projects, and domain terms that genuinely
    recur and carry lasting context. For each, write a ONE-LINE description of
    what the entity IS in general.

    - person: a colleague, contact, or counterpart — say colleague vs external + company.
    - organization: a company, client, customer, team, or vendor.
    - project: an initiative, product, workstream, or effort.
    - term: domain jargon, an acronym, or a product name worth knowing.

    Rules:
    - Treat the "about:" and "people:" facts as ground truth; don't guess a
      relationship the facts contradict.
    - Describe each entity durably. Do NOT bake one todo's transient detail into
      a standing fact (e.g. don't claim a feature "is for Customer Y", or a
      person "is working on Z", off a single todo). Only state a relationship
      when several todos support it.
    - Prefer entities grounded in MULTIPLE todos. Include a single-todo entity
      only if it is clearly significant and recurring.
    - List the todo NUMBERS that mention each entity in "todos".
    - If existing entries are given, refine them and merge duplicates rather
      than inventing near-copies. Skip one-off names with no lasting relevance.

    Return ONLY JSON:
      { "entries": [ { "kind": "person|organization|project|term", "name": "...", "detail": "one line", "todos": [1, 4] } ] }
    """

    /// Newest-first, capped — keeps the prompt corpus and stored set bounded.
    private static let memoryMaxEntries = 60

    private func rebuildMemory(ctx: ModelContext, report: inout Report) async {
        // Corpus: recently active or open todos (last 30 days), with their
        // sources and a little of their detail.
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let todos = ((try? ctx.fetch(FetchDescriptor<Todo>())) ?? [])
            .filter { $0.isOpen || ($0.activityClock >= cutoff) }
            .sorted { $0.activityClock > $1.activityClock }
            .prefix(80)
        guard !todos.isEmpty else { return }

        let corpus = todos.enumerated().map { i, t in
            let src = t.sourcePills.map(\.label).joined(separator: ", ")
            var line = "[\(i + 1)] \(t.title) [\(src)]"
            if let c = t.customer, !c.isEmpty { line += " · about: \(c)" }
            if let p = t.participantsNote, !p.isEmpty { line += " · people: \(p)" }
            line += "\n    \(t.summary.prefix(200))"
            return line
        }.joined(separator: "\n")

        let existing = ((try? ctx.fetch(FetchDescriptor<MemoryEntry>())) ?? [])
            .sorted { $0.lastSeen > $1.lastSeen }
        let existingText = existing.isEmpty ? "(none yet)" :
            existing.prefix(Self.memoryMaxEntries)
                .map { "- [\($0.kind.rawValue)] \($0.name): \($0.detail)" }
                .joined(separator: "\n")

        let user = """
        Existing glossary:
        \(existingText)

        Recent todos and notes:
        \(corpus)
        """

        let json: [String: Any]
        do {
            json = try await llm.sendForJSON(
                tier: .fast,
                system: Self.memoryExtractSystem,
                userMessage: user,
                maxTokens: 6000,
                temperature: 0.2
            )
        } catch {
            report.errors.append("memory: \(error.localizedDescription)")
            return
        }
        guard let entries = json["entries"] as? [[String: Any]] else { return }

        let now = Date()
        var byKey: [String: MemoryEntry] = [:]
        for e in existing { byKey["\(e.kindRaw)|\(e.name.lowercased())"] = e }

        for raw in entries {
            guard let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let kind = (raw["kind"] as? String).flatMap({ MemoryKind(rawValue: $0) }) else { continue }
            let detail = (raw["detail"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            // How many distinct todos the model cites for this entity.
            let support = Set((raw["todos"] as? [Any] ?? []).compactMap { $0 as? Int ?? Int("\($0)") }).count
            let key = "\(kind.rawValue)|\(name.lowercased())"
            if let hit = byKey[key] {
                hit.lastSeen = now
                hit.mentions += 1
                if !hit.pinned, !detail.isEmpty { hit.detail = detail }  // don't clobber user edits
                // Promote a tentative entry once corroborated — by several todos
                // at once, or by recurring across more than one rebuild.
                if !hit.confirmed && (support >= 2 || hit.mentions >= 2) { hit.confirmed = true }
            } else {
                // New entity: trust it outright only when more than one todo
                // grounds it. A lone todo makes a quiet candidate that stays
                // hidden until a later todo corroborates it.
                let entry = MemoryEntry(kind: kind, name: name, detail: detail,
                                        lastSeen: now, confirmed: support >= 2)
                ctx.insert(entry)
                byKey[key] = entry
            }
        }

        // Prune: candidates that never corroborated expire fast; confirmed
        // entries get the usual quiet window. Then cap, keeping confirmed first.
        let all = (try? ctx.fetch(FetchDescriptor<MemoryEntry>())) ?? []
        for e in all where !e.pinned {
            let age = now.timeIntervalSince(e.lastSeen)
            if (!e.confirmed && age > 14 * 24 * 3600) || age > 30 * 24 * 3600 {
                ctx.delete(e)
            }
        }
        let remaining = ((try? ctx.fetch(FetchDescriptor<MemoryEntry>())) ?? [])
            .filter { !$0.pinned }
            .sorted { ($0.confirmed ? 1 : 0, $0.lastSeen) > ($1.confirmed ? 1 : 0, $1.lastSeen) }
        for e in remaining.dropFirst(Self.memoryMaxEntries) {
            ctx.delete(e)
        }

        writeCursor(key: Self.memoryCursorKey, value: ISO8601DateFormatter().string(from: now), ctx: ctx)
        report.memoryEntries = (try? ctx.fetchCount(FetchDescriptor<MemoryEntry>())) ?? 0
    }

    /// Force a fresh assessment of every tracked todo, bypassing the 12h gate.
    /// Used by "Re-evaluate now" — e.g. after the assessment logic changes.
    func reevaluateAll() async -> Report {
        var report = Report()
        let ctx = ModelContext(container)
        loadMemoryContext(ctx: ctx)
        do {
            try await refreshTracked(ctx: ctx, report: &report, force: true)
            try ctx.save()
        } catch {
            report.errors.append("\(error.localizedDescription)")
        }
        return report
    }

    /// Retire todos that have had no real activity for the archive window.
    /// Pure timestamp math (no API). Archived todos are terminal — excluded
    /// from refresh and consolidation, and won't auto-reopen.
    private func archiveStaleTodos(ctx: ModelContext, report: inout Report) {
        let all = (try? ctx.fetch(FetchDescriptor<Todo>())) ?? []
        let now = Date()
        for todo in all where todo.isActive && !todo.pendingReview {
            let inactiveDays = now.timeIntervalSince(todo.activityClock) / 86400
            guard inactiveDays >= Todo.archiveAfterDays else { continue }
            todo.status = TodoStatus.archived.rawValue
            todo.completedAt = now
            todo.completionReason = "Archived — no activity for \(Int(Todo.archiveAfterDays)) days"
            todo.updatedAt = now
            report.archived += 1; Activity.log(.archived, todo.title, ctx: ctx)
        }
    }

    /// When no cursor exists, don't scan all of history — just the last 7 days.
    private func defaultSlackTs() -> String {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        return String(format: "%.6f", weekAgo.timeIntervalSince1970)
    }

    // MARK: - Ingest: mentions

    private func scanMentions(ctx: ModelContext, report: inout Report) async throws {
        let cursorKey = "mentions"
        let cursor = readCursor(key: cursorKey, ctx: ctx) ?? defaultSlackTs()
        let matches: [SlackClient.SearchMatch]
        do {
            matches = try await slack.searchMentions(handle: settings.slackHandle, after: cursor)
        } catch {
            report.errors.append("search.messages: \(error.localizedDescription)")
            return
        }

        let ignoredIDs: Set<String> = {
            let rows = (try? ctx.fetch(FetchDescriptor<IgnoredMentionChannel>())) ?? []
            return Set(rows.map { $0.channelID })
        }()

        var latestTs: String = cursor
        var seenDMChannels: Set<String> = []
        for match in matches {
            if match.user == settings.slackUserID { continue }
            if (match.text ?? "").isEmpty { continue }
            if ignoredIDs.contains(match.channel.id) { continue }
            if compareTs(match.ts, latestTs) > 0 { latestTs = match.ts }

            // A DM is one conversation, not one-todo-per-message.
            let isDM = Self.isDMChannel(match.channel.id)
            if isDM {
                if seenDMChannels.contains(match.channel.id) { continue }
                if openTodoExists(channelID: match.channel.id, ctx: ctx) { continue }
            }

            let parentTs = match.threadParentTs
            let threadKey = "\(match.channel.id):\(parentTs)"
            if existingTodo(threadKey: threadKey, ctx: ctx) != nil { continue }
            if routeToMergedWorkItem(threadKey: threadKey, ctx: ctx, report: &report) { continue }

            do {
                let resolved = await resolveChannelName(
                    channelID: match.channel.id,
                    fallback: match.channel.name
                )
                guard let outcome = try await ingestCandidate(
                    threadKey: threadKey,
                    channelID: match.channel.id,
                    channelName: resolved,
                    parentTs: parentTs,
                    fallbackPermalink: match.permalink,
                    ctx: ctx
                ) else { continue }
                if outcome.mergedInto == nil {
                    ctx.insert(outcome.todo); Activity.log(outcome.todo.pendingReview ? .review : .created, outcome.todo.title, ctx: ctx)
                    if isDM { seenDMChannels.insert(match.channel.id) }
                    report.newMentions += 1
                    if outcome.todo.statusEnum == .inProgress {
                        report.movedInProgress += 1
                    }
                }
            } catch {
                // Same benign case as DMs: search-indexed channel the token
                // can't fetch directly. Skip rather than surface as an error.
                if !"\(error.localizedDescription)".contains("channel_not_found") {
                    report.errors.append("ingest mention: \(error.localizedDescription)")
                }
            }
        }

        writeCursor(key: cursorKey, value: latestTs, ctx: ctx)
    }

    // MARK: - Ingest: watched channels

    private func scanWatchedChannels(ctx: ModelContext, report: inout Report) async throws {
        let watched: [WatchedChannel] = (try? ctx.fetch(FetchDescriptor<WatchedChannel>())) ?? []
        for channel in watched {
            let cursorKey = "channel:\(channel.channelID)"
            let cursor = readCursor(key: cursorKey, ctx: ctx)
            let messages: [SlackClient.Message]
            do {
                messages = try await slack.conversationHistory(
                    channelID: channel.channelID,
                    after: cursor
                )
            } catch {
                report.errors.append("history(\(channel.name)): \(error.localizedDescription)")
                continue
            }

            var latestTs = cursor
            for msg in messages where !msg.isFromBot {
                if compareTs(msg.ts, latestTs) > 0 { latestTs = msg.ts }
                if msg.user == settings.slackUserID { continue }
                // Top-level messages only for watched-channel scanning.
                if let tts = msg.thread_ts, tts != msg.ts { continue }

                let threadKey = "\(channel.channelID):\(msg.ts)"
                if existingTodo(threadKey: threadKey, ctx: ctx) != nil { continue }
                if routeToMergedWorkItem(threadKey: threadKey, ctx: ctx, report: &report) { continue }

                do {
                    guard let outcome = try await ingestCandidate(
                        threadKey: threadKey,
                        channelID: channel.channelID,
                        channelName: channel.name,
                        parentTs: msg.ts,
                        fallbackPermalink: nil,
                        ctx: ctx
                    ) else { continue }
                    if outcome.mergedInto == nil {
                        ctx.insert(outcome.todo); Activity.log(outcome.todo.pendingReview ? .review : .created, outcome.todo.title, ctx: ctx)
                        report.newFromWatchedChannels += 1
                        if outcome.todo.statusEnum == .inProgress {
                            report.movedInProgress += 1
                        }
                    }
                } catch {
                    report.errors.append("ingest watched: \(error.localizedDescription)")
                }
            }
            if let latest = latestTs { writeCursor(key: cursorKey, value: latest, ctx: ctx) }
        }
    }

    // MARK: - Ingest: direct messages

    /// Scan 1:1 and group DMs for incoming asks. The mention search and
    /// participant search don't surface DMs, so without this an inbound DM
    /// (where the user is neither @mentioned nor has replied yet) is never tracked.
    /// Requires `im:read` / `mpim:read` to list conversations.
    private func scanDMs(ctx: ModelContext, report: inout Report) async throws {
        let dms: [SlackClient.DMChannel]
        do {
            dms = try await slack.listDMs()
        } catch {
            report.errors.append("dm list: \(error.localizedDescription)")
            return
        }
        for dm in dms {
            let cursorKey = "dm:\(dm.id)"
            let cursor = readCursor(key: cursorKey, ctx: ctx) ?? defaultSlackTs()
            let messages: [SlackClient.Message]
            do {
                messages = try await slack.conversationHistory(channelID: dm.id, after: cursor)
            } catch {
                // Closed / inaccessible DMs report channel_not_found — benign,
                // just skip them rather than surfacing a scary error.
                if !"\(error.localizedDescription)".contains("channel_not_found") {
                    report.errors.append("dm history: \(error.localizedDescription)")
                }
                continue
            }

            // A DM is one flat conversation — model it as a single todo rather
            // than one per message. Advance the cursor past everything seen,
            // and only ingest if there's a new inbound message AND no open todo
            // already tracks this DM (its refresh handles ongoing updates).
            let inbound = messages
                .filter { !$0.isFromBot && $0.user != settings.slackUserID }
                .filter { ($0.thread_ts == nil || $0.thread_ts == $0.ts) }
                .sorted { compareTs($0.ts, $1.ts) < 0 }
            if let latest = messages.map(\.ts).max(by: { compareTs($0, $1) < 0 }) {
                writeCursor(key: cursorKey, value: latest, ctx: ctx)
            }
            guard let firstAsk = inbound.first else { continue }
            if openTodoExists(channelID: dm.id, ctx: ctx) { continue }

            let threadKey = "\(dm.id):\(firstAsk.ts)"
            if existingTodo(threadKey: threadKey, ctx: ctx) != nil { continue }
            if routeToMergedWorkItem(threadKey: threadKey, ctx: ctx, report: &report) { continue }
            do {
                let resolved = await resolveChannelName(channelID: dm.id, fallback: nil)
                guard let outcome = try await ingestCandidate(
                    threadKey: threadKey,
                    channelID: dm.id,
                    channelName: resolved,
                    parentTs: firstAsk.ts,
                    fallbackPermalink: nil,
                    ctx: ctx
                ) else { continue }
                if outcome.mergedInto == nil {
                    ctx.insert(outcome.todo); Activity.log(outcome.todo.pendingReview ? .review : .created, outcome.todo.title, ctx: ctx)
                    report.newFromDMs += 1
                    if outcome.todo.statusEnum == .inProgress {
                        report.movedInProgress += 1
                    }
                }
            } catch {
                report.errors.append("ingest dm: \(error.localizedDescription)")
            }
        }
    }

    /// Shared ingest pipeline. Fetches the full thread, resolves names,
    /// assesses status, and either creates a todo (open / in_progress) or
    /// returns nil (skip / already done).
    private struct IngestOutcome {
        let todo: Todo
        let mergedInto: Todo?  // non-nil when this was consolidated
    }

    private func ingestCandidate(threadKey: String,
                                 channelID: String,
                                 channelName: String,
                                 parentTs: String,
                                 fallbackPermalink: URL?,
                                 ctx: ModelContext) async throws -> IngestOutcome? {
        let replies = try await fetchThread(channelID: channelID, parentTs: parentTs)

        // Slack search often omits thread_ts on reply matches, so the caller's
        // key can point at a reply rather than the thread root — which once
        // produced one duplicate todo per reply. fetchThread has resolved the
        // real root; re-key to it and dedup again on the canonical key.
        let rootTs = replies.first?.ts ?? parentTs
        let canonicalKey = "\(channelID):\(rootTs)"
        if canonicalKey != threadKey {
            if existingTodo(threadKey: canonicalKey, ctx: ctx) != nil { return nil }
            if mergedSourceExists(threadKey: canonicalKey, ctx: ctx) { return nil }
        }

        let resolved = await resolveAllUserMentions(in: replies)

        // Previously declined as "not for me" — don't keep resurfacing it.
        if isThreadIgnored(canonicalKey, ctx: ctx) || isThreadIgnored(threadKey, ctx: ctx) { return nil }

        let assessment = try await assessThread(
            replies: resolved,
            channelName: channelName,
            existingTitle: nil
        )
        switch assessment.status {
        case .skip, .done:
            return nil
        case .open, .inProgress, .waiting:
            // Too unsure it's the user's → don't even surface it.
            if assessment.forYouConfidence < 0.45 { return nil }
            let summary = try await summariseThread(
                replies: resolved,
                channelName: channelName,
                classification: assessment.classification,
                due: assessment.due
            )

            // Note: cross-thread consolidation is intentionally disabled. The
            // LLM matched on "same customer" rather than "same work item",
            // collapsing every new thread for an active customer into one
            // existing todo and suppressing new todos entirely. The threadKey
            // dedup below already prevents true same-thread duplicates. Proper
            // same-work-item / cross-source merging will return as a dedicated
            // feature with a much stricter matcher.

            let permalink = (try? await slack.chatPermalink(channelID: channelID, messageTs: rootTs))
                ?? fallbackPermalink

            let lastTs = resolved.last?.ts ?? rootTs
            let storedStatus: TodoStatus = assessment.status == .inProgress ? .inProgress
                : assessment.status == .waiting ? .waiting : .open
            let todo = Todo(
                threadKey: canonicalKey,
                title: summary.title,
                summary: summary.summary,
                classification: assessment.classification.rawValue,
                status: storedStatus.rawValue,
                channelID: channelID,
                channelName: channelName,
                sourceURL: permalink,
                lastSlackActivity: SlackClient.dateFromTs(lastTs) ?? Date(),
                lastSeenTs: lastTs
            )
            todo.priority = assessment.priority.rawValue
            todo.priorityReason = assessment.priorityReason
            todo.dueDate = assessment.due
            todo.customer = await deriveCustomer(channelName: channelName, replies: resolved)
            todo.participantsNote = await participantsNote(resolved)
            // Middling confidence it's yours → hold it in the review queue
            // rather than dropping it straight into the list.
            if assessment.forYouConfidence < 0.75 {
                todo.pendingReview = true
                todo.reviewKind = ReviewKind.forYou.rawValue
                todo.reviewConfidence = assessment.forYouConfidence
                todo.reviewReason = assessment.forYouReason ?? assessment.note
                    ?? "Not sure this is yours to action."
            }
            // Waiting on someone else is now a first-class status (parked but
            // visible in Snoozed → "Waiting on others"), not an auto-snooze.
            if storedStatus == .waiting {
                Activity.log(.parked, todo.title, detail: "waiting on someone else", ctx: ctx)
            }
            return IngestOutcome(todo: todo, mergedInto: nil)
        }
    }

    // MARK: - Consolidation

    /// Largest group the clustering pass will merge in one go. A genuine work
    /// item rarely spans more than 2–3 threads; a bigger group almost always
    /// means the model fell back to grouping by customer/people (the failure
    /// mode that previously suppressed all new todos), so we skip it.
    private static let maxMergeGroupSize = 3

    private static let clusterSystem = """
    You group a person's todos into distinct WORK ITEMS so duplicates collapse
    into one.

    Merge two todos ONLY if finishing one would essentially finish the other —
    they are the SAME deliverable, bug, or ask, just seen from different threads
    or sources. Examples that MERGE:
    - Two threads both debugging the same specific failure.
    - A Slack ask and a Granola action item describing the same task.
    - Two messages chasing the same single decision or document.

    Keep todos SEPARATE when they are merely RELATED. Related is not the same:
    - Same customer or project, different task → SEPARATE.
    - Same people/contacts involved (the same teammate, the same customer
      contact) → SEPARATE unless the deliverable is identical. Shared people are
      NOT evidence of the same work item.
    - Different bugs, features, or asks → SEPARATE, even within one thread.
    - One follows from or depends on the other but is its own piece of work →
      SEPARATE.
    - DIFFERENT customers or different external people/companies → SEPARATE,
      always. Use the BACKGROUND CONTEXT and channel names (e.g. a
      "#ext-subscriber-<customer>" channel names the customer) to tell them
      apart. A DM or ticket from one customer's contact is never the same work
      item as another customer's thread, even if the topic looks similar.

    Worked example — these are THREE separate work items, NOT one, even though
    every thread is the same customer (Halter) with the same people:
    - "Fix numbered-list rendering in the Halter workflow"
    - "Confirm the assignee / how to hand off to the Lorikeet agent"
    - "Re-enable the FAQ workflow after safety checks"
    Same customer + same people + adjacent topics is NOT one deliverable.

    The test is strict: only merge if you can name the ONE concrete artifact,
    bug, or decision both todos are about. If the most specific thing they share
    is a customer, a channel, a person, or a theme, keep them SEPARATE.

    When unsure, keep them separate. Over-merging is worse than missing a merge:
    merged todos share one open/closed state, so a wrong merge makes finished
    work reopen on unrelated activity.

    Return ONLY a JSON object:
      "groups": [ { "work_item": "short label", "ids": [int, ...], "why": "one line" } ]
    Only include groups of 2+ ids that are the SAME work item. Omit singletons.
    Each id appears in at most one group.
    """

    /// Adversarial second opinion: a proposed group only merges if this strict
    /// reviewer confirms the todos are genuinely the same deliverable. Catches
    /// the common failure where the clusterer groups by shared customer/theme.
    private static let verifyMergeSystem = """
    You are a strict reviewer deciding whether several todos are truly the SAME
    work item — the same deliverable, bug, or ask — such that finishing one
    finishes them all.

    Sharing a customer, project, channel, theme, or the same people is NOT
    enough; that is "related", which must stay separate. Tasks that merely
    depend on or follow from each other are also separate. If they involve
    DIFFERENT customers or different external people/companies, they are NOT the
    same — score near 0.

    Your "reason" MUST name the single concrete artifact, bug, or decision all
    the todos are about (e.g. "all fix the same numbered-list rendering bug"). If
    you cannot name one specific shared deliverable — if the most specific thing
    they share is a customer, channel, person, or theme — they are NOT the same;
    score below 0.5.

    Return ONLY JSON: { "confidence": 0.0-1.0, "reason": "one line" }
    "confidence" = how sure they're the SAME work item: ~1 = certainly the same,
    ~0.6 = probably but worth a human glance, <0.5 = not the same.
    """

    /// Cluster open todos into work items and merge each multi-todo group into
    /// a single todo carrying every contributing source. Runs after ingest,
    /// reports merges, and is reversible (see unmerge in the UI).
    private func consolidateOpenTodos(ctx: ModelContext, report: inout Report) async {
        let open = ((try? ctx.fetch(FetchDescriptor<Todo>())) ?? [])
            .filter { $0.isOpen && !$0.excludeFromAutoMerge && !$0.isSnoozed && !$0.pendingReview }
        guard open.count >= 2 else { return }

        let listing = open.enumerated().map { i, t in
            let src = t.sourcePills.map(\.label).joined(separator: ", ")
            let reason = (t.priorityReason?.isEmpty == false) ? "\n    why it matters: \(t.priorityReason!)" : ""
            return "[\(i)] deliverable: \(t.title)\n    customer: \(t.customer ?? "internal")\n    source: \(src)\(reason)\n    detail: \(t.summary)"
        }.joined(separator: "\n\n")

        let json: [String: Any]
        do {
            json = try await llm.sendForJSON(
                tier: .smart,
                system: systemPrompt(Self.clusterSystem),
                userMessage: "Todos:\n\(listing)",
                maxTokens: 1500,
                temperature: 0.1
            )
        } catch {
            report.errors.append("consolidate: \(error.localizedDescription)")
            return
        }

        guard let groups = json["groups"] as? [[String: Any]] else { return }
        for group in groups {
            let rawIDs = (group["ids"] as? [Any])?.compactMap {
                ($0 as? Int) ?? ($0 as? NSNumber)?.intValue
            } ?? []
            let ids = rawIDs.filter { $0 >= 0 && $0 < open.count }
            guard ids.count >= 2 else { continue }
            if ids.count > Self.maxMergeGroupSize {
                report.errors.append("consolidate: skipped oversized group (\(ids.count)) \"\(group["work_item"] as? String ?? "?")\"")
                continue
            }

            let members = ids.map { open[$0] }

            // Adversarial gate: only collapse if a strict reviewer agrees these
            // are the same deliverable. Skip the merge on doubt or error.
            let label = (group["work_item"] as? String) ?? ""
            let memberDesc = members.map { t in
                let src = t.sourcePills.map(\.label).joined(separator: ", ")
                return "- deliverable: \(t.title) (customer: \(t.customer ?? "internal")) [\(src)]\n  detail: \(t.summary)"
            }.joined(separator: "\n")
            let verdict: [String: Any]
            do {
                verdict = try await llm.sendForJSON(
                    tier: .smart,
                    system: systemPrompt(Self.verifyMergeSystem),
                    userMessage: "Proposed work item: \(label)\nTodos:\n\(memberDesc)",
                    maxTokens: 300,
                    temperature: 0.0
                )
            } catch {
                report.errors.append("consolidate verify: \(error.localizedDescription)")
                continue
            }
            let mergeConfidence = (verdict["confidence"] as? Double)
                ?? (verdict["confidence"] as? NSNumber)?.doubleValue ?? 0
            if mergeConfidence < 0.6 { continue }   // not the same work

            // Prefer an already-established work item (one that has absorbed
            // sources) as the anchor, then the earliest-created. This keeps the
            // same primary stable across runs instead of re-parenting.
            let primary = members.sorted {
                if $0.extraSources.count != $1.extraSources.count {
                    return $0.extraSources.count > $1.extraSources.count
                }
                return $0.createdAt < $1.createdAt
            }.first!

            // Middling confidence → suggest the merge for review instead of
            // doing it. Flag each other member pointing at the primary.
            if mergeConfidence < 0.9 {
                let reason = (verdict["reason"] as? String) ?? "Looks like the same work as \"\(primary.title)\"."
                for todo in members where todo !== primary
                    && todo.reviewKindEnum == nil && !todo.excludeFromAutoMerge {
                    todo.reviewKind = ReviewKind.merge.rawValue; Activity.log(.review, todo.title, detail: "possible duplicate", ctx: ctx)
                    todo.reviewMergeIntoKey = primary.threadKey
                    todo.reviewConfidence = mergeConfidence
                    todo.reviewReason = reason
                }
                continue
            }

            for todo in members where todo !== primary {
                let source = TodoSource(
                    title: todo.title,
                    summary: todo.summary,
                    classification: todo.classification,
                    status: todo.status,
                    channelID: todo.channelID,
                    channelName: todo.channelName,
                    threadKey: todo.threadKey,
                    sourceURL: todo.sourceURL,
                    lastActivity: todo.lastSlackActivity,
                    lastSeenTs: todo.lastSeenTs
                )
                source.todo = primary
                ctx.insert(source)
                // Move anything already folded into this todo onto the primary,
                // otherwise the cascade delete below would destroy those
                // snapshots (and their reversibility).
                for s in todo.extraSources { s.todo = primary }
                for c in todo.comments { c.todo = primary }
                ctx.delete(todo)
                report.mergedSources += 1
            }
            // Re-title the work item to describe the combined scope rather than
            // inheriting whichever thread happened to anchor it. The cluster's
            // label is purpose-built for this.
            if !label.trimmingCharacters(in: .whitespaces).isEmpty {
                primary.title = label
            }
            // The combined item is as urgent as its most urgent member.
            if let top = members.map(\.priorityEnum).min() {
                primary.priority = top.rawValue
            }
            primary.updatedAt = Date()
            primary.lastActivityAt = Date()  // a merge counts as activity
            Activity.log(.merged, primary.title, detail: "merged \(members.count - 1) item\(members.count - 1 == 1 ? "" : "s")", ctx: ctx)
        }
    }

    // MARK: - Granola meetings

    private func scanGranolaMeetings(ctx: ModelContext, report: inout Report) async throws {
        guard let granola = granola else { return }

        let cursorKey = "granola"
        let cursor = readCursor(key: cursorKey, ctx: ctx)
        // Default to last 7 days on first sync, same as Slack.
        let since = cursor.flatMap(Self.parseDate)
            ?? Date().addingTimeInterval(-7 * 24 * 3600)

        // Backfill processed-markers for any meeting we already have todos
        // from, so older builds' meetings are skipped from here on.
        backfillProcessedGranolaMeetings(ctx: ctx)

        let meetings: [GranolaClient.Meeting]
        do {
            meetings = try await granola.listMeetings(since: since)
        } catch {
            report.errors.append("granola list: \(error.localizedDescription)")
            return
        }

        var latestEnd: Date = since
        for meeting in meetings {
            if let updated = meeting.updatedAt, updated > latestEnd {
                latestEnd = updated
            }
            // Granola notes are immutable once written, so a meeting only
            // needs processing once. Skipping avoids re-extracting the same
            // action items (and the duplicate todos that caused).
            if processedMeeting(id: meeting.id, ctx: ctx) { continue }
            do {
                let detail = try await granola.meetingDetail(id: meeting.id)
                guard let summaryText = detail.summary, !summaryText.isEmpty else { continue }

                // Use LLM to extract action items — more reliable than regex
                // since Granola's summary format varies.
                let items = try await extractGranolaActionItems(
                    meeting: detail
                )

                for item in items {
                    let hash = Self.shortHash(item.text.lowercased())
                    let threadKey = "granola:\(meeting.id):\(hash)"
                    if existingTodo(threadKey: threadKey, ctx: ctx) != nil { continue }

                    let assignment = try await assessGranolaItem(
                        item: item,
                        meeting: detail
                    )
                    guard assignment.assignedToMe else { continue }

                    let summary = try await summariseGranolaItem(
                        item: item,
                        meeting: detail
                    )

                    let permalink = detail.url
                    let lastActivity = detail.endedAt ?? meeting.updatedAt ?? Date()
                    let todo = Todo(
                        threadKey: threadKey,
                        title: summary.title,
                        summary: summary.summary,
                        classification: TodoClassification.todo.rawValue,
                        status: TodoStatus.open.rawValue,
                        channelID: "granola:\(meeting.id)",
                        channelName: detail.title,
                        sourceURL: permalink,
                        lastSlackActivity: lastActivity,
                        lastSeenTs: String(format: "%.6f", lastActivity.timeIntervalSince1970)
                    )
                    ctx.insert(todo)
                    report.newMentions += 1
                }
                ctx.insert(ProcessedGranolaMeeting(meetingID: meeting.id))
            } catch {
                report.errors.append("granola meeting \(meeting.id): \(error.localizedDescription)")
            }
        }

        writeCursor(
            key: cursorKey,
            value: ISO8601DateFormatter().string(from: latestEnd),
            ctx: ctx
        )
    }

    // MARK: - Granola: LLM-based action item extraction

    private static let granolaExtractSystem = """
    Extract action items from a meeting summary and transcript.

    Return ONLY a JSON object:
      "items": [ { "text": "...", "assignee": "name" or null }, ... ]

    Rules:
    * Only include concrete, actionable tasks with a clear owner.
    * "We could do X" or "we'd need to do X" is NOT an action item — that's
      speculative. Only extract when someone says "I will", "I'll", "let me",
      or explicitly takes ownership.
    * If someone was directly asked to do something and accepted, include it.
    * Decisions already made are NOT action items.
    * General capabilities, product features, or architecture being discussed
      are NOT action items — they're conversation topics.
    * Sales/POC/exploratory meetings: be extra conservative. A demo of what
      your product can do is not a commitment to build it.
    * If no clear action items, return {"items": []}.
    * Do NOT invent items that aren't clearly in the summary or transcript.
    * The transcript is the ground truth — use it to confirm who actually
      committed to what, in their own words.
    * CONSOLIDATE related items. If multiple items are about the same piece
      of work (e.g. "build X integration", "set up X credentials", "share X
      docs" are all sub-steps of one project), combine them into ONE item
      that captures the overall commitment. Prefer fewer, broader items
      over many granular sub-tasks.
    """

    private func extractGranolaActionItems(
        meeting: GranolaClient.MeetingDetail
    ) async throws -> [GranolaClient.ActionItem] {
        var payload = """
        Meeting: \(meeting.title)
        Participants: \(meeting.participantNames.joined(separator: ", "))

        Summary:
        \(meeting.summary ?? "")
        """
        if let transcript = meeting.transcript, !transcript.isEmpty {
            // Cap transcript to ~4k chars so we stay within token budget
            let trimmed = transcript.prefix(4000)
            payload += "\n\nTranscript (condensed):\n\(trimmed)"
        }
        let json = try await llm.sendForJSON(
            tier: .fast,
            system: systemPrompt(Self.granolaExtractSystem),
            userMessage: payload,
            maxTokens: 500,
            temperature: 0.1
        )
        // Response might be a top-level array or wrapped in {"items": [...]}
        let items: [[String: Any]]
        if let arr = json["items"] as? [[String: Any]] {
            items = arr
        } else if let arr = json["action_items"] as? [[String: Any]] {
            items = arr
        } else {
            // sendForJSON returns a dict; if the model returned an array,
            // it will be under some key. Fall back to empty.
            items = []
        }
        return items.compactMap { dict -> GranolaClient.ActionItem? in
            guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
            let assignee = dict["assignee"] as? String
            return GranolaClient.ActionItem(
                text: text,
                assignee: assignee?.isEmpty == false ? assignee : nil,
                completed: false
            )
        }
    }

    private struct GranolaAssignment {
        let assignedToMe: Bool
        let reason: String?
    }

    private static let granolaAssessSystem = """
    You decide whether a meeting action item is personally assigned to a
    specific user — meaning THEY need to do it, not their company or team.

    Return ONLY a JSON object:
      "assigned_to_me": true | false
      "reason": one-sentence explanation (max 15 words)

    Mark true ONLY when ALL of these hold:
      1. The assignee matches one of the user's known names / aliases / email,
         OR the action item text explicitly names the user as the actor.
      2. The commitment is personal ("I will", "<name> to send"), not collective
         ("we'll build", "our team will handle").
      3. It's a concrete next step, not a capability being discussed.

    Mark false when:
      * Assignee is empty / "we" / a generic group / the company name.
      * Assignee is someone else (a colleague, the external party).
      * The user is mentioned only as a reference, not the doer.
      * The "action" is really a product capability or feature being demoed
        or discussed — not a personal task.
      * The user was describing what their product/company can do, not
        committing to personally doing it.

    When in doubt, mark false. False positives are worse than misses.
    """

    private func assessGranolaItem(item: GranolaClient.ActionItem,
                                   meeting: GranolaClient.MeetingDetail) async throws -> GranolaAssignment {
        let identity = settings.identityNames.joined(separator: ", ")
        var payload = """
        User's known identifiers: \(identity.isEmpty ? "(none)" : identity)

        Meeting: \(meeting.title)
        Participants: \(meeting.participantNames.joined(separator: ", "))

        Action item:
          assignee: \(item.assignee ?? "(unspecified)")
          text: \(item.text)
        """
        if let transcript = meeting.transcript, !transcript.isEmpty {
            let trimmed = transcript.prefix(3000)
            payload += "\n\nTranscript excerpt:\n\(trimmed)"
        }
        let json = try await llm.sendForJSON(
            tier: .fast,
            system: systemPrompt(Self.granolaAssessSystem),
            userMessage: payload,
            maxTokens: 200,
            temperature: 0.1
        )
        return GranolaAssignment(
            assignedToMe: (json["assigned_to_me"] as? Bool) ?? false,
            reason: json["reason"] as? String
        )
    }

    private static let granolaSummariseSystem = """
    You write very short todo entries from meeting action items.

    Return ONLY a JSON object:
      "title": short headline, verb-first, ≤ 8 words
      "summary": 2 sentences max. Sentence 1: what the task is and where it
                  stands. Sentence 2: why it matters or what's expected next.
                  Use ONLY facts from the action item + meeting context.

    Voice:
    - Second person ("you", "your").
    - Name specific people by their display name.
    - Lead with the task itself. Do NOT open with a stock phrase — never start
      with "You committed to", "You agreed to", "You need to", etc. Vary the
      opening and get straight to the substance.
    - No corporate hedging.

    Critical: do not invent details that aren't in the action item or
    meeting context.
    """

    private func summariseGranolaItem(item: GranolaClient.ActionItem,
                                      meeting: GranolaClient.MeetingDetail) async throws -> SummariseResult {
        var payload = """
        Meeting: \(meeting.title)
        Participants: \(meeting.participantNames.joined(separator: ", "))
        Meeting summary: \(meeting.summary ?? "(none)")

        Action item:
          \(item.text)
        """
        if let transcript = meeting.transcript, !transcript.isEmpty {
            let trimmed = transcript.prefix(3000)
            payload += "\n\nTranscript excerpt:\n\(trimmed)"
        }
        let json = try await llm.sendForJSON(
            tier: .smart,
            system: systemPrompt(Self.granolaSummariseSystem),
            userMessage: payload,
            maxTokens: 220,
            temperature: 0.1
        )
        return SummariseResult(
            title: (json["title"] as? String) ?? item.text.prefix(60).description,
            summary: (json["summary"] as? String) ?? item.text
        )
    }

    /// Short-hash for Granola item dedup. First 8 hex chars of SHA-256 over
    /// the lowercase trimmed action text. Stable across launches so we
    /// reliably dedup the same item if a meeting is re-processed.
    private static func shortHash(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// DM-type channels (1:1 "D…" and group "G…") have no real threading — every
    /// message is its own "thread root", so they must be deduped by channel, not
    /// by per-message thread key, to avoid one todo per message.
    private static func isDMChannel(_ id: String) -> Bool {
        id.hasPrefix("D") || id.hasPrefix("G")
    }

    /// A message's text for a thread excerpt. Generous cap so long messages
    /// aren't cut; when we do truncate, the explicit marker stops the model
    /// from reading the hard cut as the message genuinely ending mid-sentence.
    private static func excerptText(_ text: String?, limit: Int = 1500) -> String {
        guard let text, !text.isEmpty else { return "" }
        if text.count <= limit { return text }
        return text.prefix(limit) + " …(excerpt truncated by Sift)"
    }

    private static func parseDate(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
    }

    // MARK: - User-participated threads

    /// Surface threads where the user has posted but might not have a fresh
    /// @mention. Covers the case where the user was mentioned earlier in a thread
    /// (so he's "subscribed"), the todo was closed, and a new reply lands.
    private func scanParticipantThreads(ctx: ModelContext, report: inout Report) async throws {
        let cursorKey = "participant"
        let cursor = readCursor(key: cursorKey, ctx: ctx) ?? defaultSlackTs()
        let matches: [SlackClient.SearchMatch]
        do {
            matches = try await slack.searchMessagesFromUser(
                handle: settings.slackHandle,
                after: cursor
            )
        } catch {
            report.errors.append("participant search: \(error.localizedDescription)")
            return
        }

        // Dedup by thread parent.
        var seenThreads: Set<String> = []
        var seenDMChannels: Set<String> = []
        var latestTs: String = cursor
        for match in matches {
            if compareTs(match.ts, latestTs) > 0 { latestTs = match.ts }
            let parentTs = match.threadParentTs
            let threadKey = "\(match.channel.id):\(parentTs)"
            if !seenThreads.insert(threadKey).inserted { continue }

            // A DM is one conversation, not one-todo-per-message.
            let isDM = Self.isDMChannel(match.channel.id)
            if isDM {
                if seenDMChannels.contains(match.channel.id) { continue }
                if openTodoExists(channelID: match.channel.id, ctx: ctx) { continue }
            }

            // If a todo already exists, refresh pass will handle it.
            if existingTodo(threadKey: threadKey, ctx: ctx) != nil { continue }
            if routeToMergedWorkItem(threadKey: threadKey, ctx: ctx, report: &report) { continue }

            do {
                let resolved = await resolveChannelName(
                    channelID: match.channel.id,
                    fallback: match.channel.name
                )
                guard let outcome = try await ingestCandidate(
                    threadKey: threadKey,
                    channelID: match.channel.id,
                    channelName: resolved,
                    parentTs: parentTs,
                    fallbackPermalink: match.permalink,
                    ctx: ctx
                ) else { continue }
                if outcome.mergedInto == nil {
                    ctx.insert(outcome.todo); Activity.log(outcome.todo.pendingReview ? .review : .created, outcome.todo.title, ctx: ctx)
                    if isDM { seenDMChannels.insert(match.channel.id) }
                    report.newMentions += 1
                    if outcome.todo.statusEnum == .inProgress {
                        report.movedInProgress += 1
                    }
                }
            } catch {
                // Search can surface channels the token can't fetch (left,
                // archived, private/external) — benign, skip rather than report.
                if !"\(error.localizedDescription)".contains("channel_not_found") {
                    report.errors.append("ingest participant: \(error.localizedDescription)")
                }
            }
        }

        writeCursor(key: cursorKey, value: latestTs, ctx: ctx)
    }

    // MARK: - Refresh tracked

    private func refreshTracked(ctx: ModelContext, report: inout Report, force: Bool = false) async throws {
        // Include OPEN/in_progress todos plus recently-completed ones (7 days)
        // so we can reopen if there's new activity. Filter in Swift — a
        // #Predicate with a force-unwrapped optional throws at fetch time,
        // which would silently yield an empty list and skip all refreshing.
        // Active todos, plus recently-completed ones (7 days) so we can reopen
        // on new activity. Archived todos are terminal — never refreshed.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let open = ((try? ctx.fetch(FetchDescriptor<Todo>())) ?? []).filter { todo in
            if todo.statusEnum == .archived { return false }
            return todo.statusEnum != .done || (todo.completedAt.map { $0 >= cutoff } ?? false)
        }

        for todo in open {
            // Pending-review "for you" suggestions stay static until the user
            // accepts or declines them.
            if todo.pendingReview { continue }

            // Snoozed: parked until a wake condition. Don't assess until then.
            if todo.isSnoozed {
                if await wakeSnoozed(todo) {
                    todo.snoozedUntil = nil
                    todo.snoozeWatchKey = nil
                    todo.snoozeBaselineTs = nil
                    todo.lastActivityAt = Date()
                } else {
                    continue
                }
            }

            // Assess the work item on its FRESHEST thread, not just the primary.
            // A merged work item's live state may be in a merged source thread;
            // judging only the (possibly resolved) primary would close it, and
            // the merged-thread reopen path would fight back — an oscillation.
            struct ThreadRef {
                let channelID: String, parentTs: String, channelName: String, lastSeen: String
                let activity: Date
                let source: TodoSource?
            }
            var refs: [ThreadRef] = []
            func add(_ key: String, _ name: String, _ lastSeen: String, _ activity: Date, _ src: TodoSource?) {
                guard !key.hasPrefix("granola:") else { return }
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                refs.append(ThreadRef(channelID: parts[0], parentTs: parts[1], channelName: name,
                                      lastSeen: lastSeen, activity: activity, source: src))
            }
            add(todo.threadKey, todo.channelName, todo.lastSeenTs, todo.lastSlackActivity, nil)
            for s in todo.extraSources { add(s.threadKey, s.channelName, s.lastSeenTs, s.lastActivity, s) }
            guard let active = refs.max(by: { $0.activity < $1.activity }) else { continue }
            let channelID = active.channelID
            let parentTs = active.parentTs
            let channelName = active.channelName

            let replies: [SlackClient.Message]
            do {
                replies = try await fetchThread(channelID: channelID, parentTs: parentTs)
            } catch {
                report.errors.append("replies(\(todo.title.prefix(40))): \(error.localizedDescription)")
                continue
            }

            let lastTs = replies.last?.ts ?? active.lastSeen
            let hasNewMessages = compareTs(lastTs, active.lastSeen) > 0

            // Waiting items are parked on someone else's move — only re-assess
            // when the thread actually advances (or a forced sync). Skipping the
            // periodic 12h re-check keeps quiet parked items from burning LLM
            // calls; the archive sweep retires them if they go truly cold.
            if todo.statusEnum == .waiting && !hasNewMessages && !force { continue }

            // Re-assess if: (a) new messages in thread, or (b) todo has been
            // open/in_progress for 12+ hours since last assessment. This
            // ensures stale todos eventually close even without new activity.
            let hoursSinceUpdate = Date().timeIntervalSince(todo.updatedAt) / 3600
            let shouldReassess = force || hasNewMessages || (todo.statusEnum != .done && hoursSinceUpdate >= 12)
            guard shouldReassess else { continue }

            let resolved = await resolveAllUserMentions(in: replies)

            let assessment: ThreadAssessment
            do {
                assessment = try await assessThread(
                    replies: resolved,
                    channelName: channelName,
                    existingTitle: todo.title
                )
            } catch {
                report.errors.append("status check: \(error.localizedDescription)")
                continue
            }

            let wasDone = todo.statusEnum == .done
            let oldStatus = todo.statusEnum
            switch assessment.status {
            case .skip:
                // Re-assessed as not actually trackable for the user (incidental
                // mention, someone else's thread). Close it out rather than
                // leaving it lingering open.
                if !wasDone {
                    todo.status = TodoStatus.done.rawValue
                    todo.completedAt = Date()
                    let reason = assessment.note?.isEmpty == false
                        ? assessment.note! : "Closed — not an action for you"
                    todo.completionReason = reason
                    ctx.insert(TodoComment(todo: todo, body: reason, isAutoTriage: true))
                    report.autoClosed += 1; Activity.log(.autoDone, todo.title, ctx: ctx)
                }
                todo.updatedAt = Date()
            case .done:
                if !wasDone {
                    let reason = assessment.note?.isEmpty == false
                        ? assessment.note! : "Auto-resolved by sync"
                    // Confident it's resolved → close. Unsure → surface in
                    // Review instead of silently closing (unless recently
                    // declined). Too unsure → leave it alone.
                    let recentlyDeclined = todo.reviewDismissedAt.map {
                        Date().timeIntervalSince($0) < 7 * 86400
                    } ?? false
                    if assessment.doneConfidence >= 0.75 || recentlyDeclined {
                        todo.status = TodoStatus.done.rawValue
                        todo.completedAt = Date()
                        todo.completionReason = reason
                        ctx.insert(TodoComment(todo: todo, body: reason, isAutoTriage: true))
                        report.autoClosed += 1; Activity.log(.autoDone, todo.title, ctx: ctx)
                    } else if assessment.doneConfidence >= 0.45, todo.reviewKindEnum != .done {
                        todo.reviewKind = ReviewKind.done.rawValue; Activity.log(.review, todo.title, detail: "might be done", ctx: ctx)
                        todo.reviewConfidence = assessment.doneConfidence
                        todo.reviewReason = reason
                    }
                }
                todo.updatedAt = Date()
            case .inProgress:
                if wasDone {
                    todo.completedAt = nil
                    todo.completionReason = nil
                    let note = assessment.note ?? "Re-opened — new activity in thread"
                    ctx.insert(TodoComment(todo: todo, body: note, isAutoTriage: true))
                }
                if todo.statusEnum != .inProgress {
                    todo.status = TodoStatus.inProgress.rawValue
                    report.movedInProgress += 1
                }
                if let n = assessment.note, !n.isEmpty {
                    todo.workingChannel = todo.sourceLabel
                    todo.workingQuote = String(n.prefix(80))
                    todo.workingDetectedAt = Date()
                    todo.workingThreadURL = todo.sourceURL
                }
                if !todo.priorityOverridden {
                    todo.priority = assessment.priority.rawValue
                    todo.priorityReason = assessment.priorityReason
                }
                // Trust each fresh assessment: a real commitment stays in the
                // thread text and re-derives every time, while a bad
                // extraction clears itself instead of sticking forever.
                todo.dueDate = assessment.due
                todo.updatedAt = Date()
                report.refreshed += 1
            case .open:
                if wasDone {
                    todo.completedAt = nil
                    todo.completionReason = nil
                    let note = assessment.note ?? "Re-opened — new activity in thread"
                    ctx.insert(TodoComment(todo: todo, body: note, isAutoTriage: true))
                }
                todo.status = TodoStatus.open.rawValue
                todo.workingQuote = nil
                todo.workingChannel = nil
                if !todo.priorityOverridden {
                    todo.priority = assessment.priority.rawValue
                    todo.priorityReason = assessment.priorityReason
                }
                todo.dueDate = assessment.due
                todo.updatedAt = Date()
                report.refreshed += 1
            case .waiting:
                if wasDone {
                    todo.completedAt = nil
                    todo.completionReason = nil
                    ctx.insert(TodoComment(todo: todo, body: assessment.note ?? "Re-opened — waiting on someone else", isAutoTriage: true))
                }
                // First-class status: parked but visible (Snoozed → "Waiting on
                // others"), woken by new thread activity rather than a watch key.
                if oldStatus != .waiting {
                    Activity.log(.parked, todo.title, detail: "waiting on someone else", ctx: ctx)
                }
                todo.status = TodoStatus.waiting.rawValue
                todo.workingQuote = nil
                todo.workingChannel = nil
                if !todo.priorityOverridden {
                    todo.priority = assessment.priority.rawValue
                    todo.priorityReason = assessment.priorityReason
                }
                todo.dueDate = assessment.due
                todo.updatedAt = Date()
                report.refreshed += 1
            }

            // Backfill the customer for todos created before this existed.
            if todo.customer == nil {
                todo.customer = await deriveCustomer(channelName: channelName, replies: resolved)
            }
            todo.participantsNote = await participantsNote(resolved)

            // Keep the title/summary current as the thread evolves — re-write
            // them when there's genuinely new content and the item is still
            // live. (No point re-summarising something we just closed.)
            if (hasNewMessages || force),
               todo.statusEnum == .open || todo.statusEnum == .inProgress || todo.statusEnum == .waiting {
                if let s = try? await summariseThread(
                    replies: resolved,
                    channelName: channelName,
                    classification: todo.classificationEnum,
                    due: assessment.due
                ) {
                    todo.title = s.title
                    todo.summary = s.summary
                }
            }

            // Note: we no longer log a comment for every reassessment. The
            // summary above now tracks the current state, so per-activity notes
            // were just noise. Status transitions (done / reopen / parked) still
            // leave a note or activity via the cases above — the meaningful events.

            if hasNewMessages {
                // Mark seen on whichever thread we actually assessed.
                if let src = active.source {
                    src.lastSeenTs = lastTs
                    src.lastActivity = SlackClient.dateFromTs(lastTs) ?? src.lastActivity
                } else {
                    todo.lastSeenTs = lastTs
                }
                todo.lastSlackActivity = SlackClient.dateFromTs(lastTs) ?? todo.lastSlackActivity
                todo.lastActivityAt = Date()  // resets the staleness clock
            }
        }
    }

    /// Whether a snoozed todo should wake: its date arrived, the watched thread
    /// got a new message, or it's gone quiet a week (so it surfaces in Stale).
    private func wakeSnoozed(_ todo: Todo) async -> Bool {
        if Date().timeIntervalSince(todo.activityClock) > Todo.staleAfterDays * 86400 { return true }
        if let until = todo.snoozedUntil { return Date() >= until }
        guard let key = todo.snoozeWatchKey else { return true }
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !key.hasPrefix("granola:") else { return true }
        guard let replies = try? await fetchThread(channelID: parts[0], parentTs: parts[1]) else { return false }
        let latest = replies.last?.ts ?? "0"
        let baseline = todo.snoozeBaselineTs ?? String(format: "%.6f", todo.updatedAt.timeIntervalSince1970)
        return compareTs(latest, baseline) > 0
    }

    // MARK: - Company / customer resolution

    /// The company a user belongs to: "" for internal colleagues (same Slack
    /// workspace), otherwise the label from their email domain. Cached per run.
    private func company(forUser uid: String?) async -> String {
        guard let uid, uid != settings.slackUserID else { return "" }
        if let c = companyCache[uid] { return c }
        var company = ""
        if let id = try? await slack.userIdentity(userID: uid) {
            let external = id.isGuest
                || (id.teamID != nil && !settings.slackTeamID.isEmpty && id.teamID != settings.slackTeamID)
            if external { company = Self.companyLabel(fromEmail: id.email) }
        }
        companyCache[uid] = company
        return company
    }

    /// "tom@amber.com" → "Amber". Empty for missing/uninformative domains.
    private static func companyLabel(fromEmail email: String?) -> String {
        guard let email, let at = email.firstIndex(of: "@") else { return "" }
        let domain = email[email.index(after: at)...]
        guard let first = domain.split(separator: ".").first else { return "" }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// Customer this thread is about: the "#ext-subscriber-<name>" channel if
    /// present, else the first external participant's company, else nil.
    private func deriveCustomer(channelName: String, replies: [SlackClient.Message]) async -> String? {
        if let fromChannel = Self.customerFromChannel(channelName) { return fromChannel }
        for msg in replies {
            let c = await company(forUser: msg.user)
            if !c.isEmpty { return c }
        }
        return nil
    }

    /// Pull the customer token out of an "ext-subscriber-<name>-lorikeet" style
    /// channel name.
    private static func customerFromChannel(_ name: String) -> String? {
        let n = name.hasPrefix("#") ? String(name.dropFirst()) : name
        guard let range = n.range(of: "ext-subscriber-") else { return nil }
        var rest = String(n[range.upperBound...])
        for suffix in ["-lorikeet", "-lorikeet-", "-loikeet"] {
            if let r = rest.range(of: suffix) { rest = String(rest[..<r.lowerBound]); break }
        }
        let token = rest.split(separator: "-").first.map(String.init) ?? rest
        guard !token.isEmpty else { return nil }
        return token.prefix(1).uppercased() + token.dropFirst()
    }

    /// "People in this thread" block for the assessment prompt — labels each
    /// non-user participant as a colleague or an external contact + company.
    private func participantsBlock(_ replies: [SlackClient.Message]) async -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for msg in replies {
            guard let uid = msg.user, uid != settings.slackUserID, seen.insert(uid).inserted else { continue }
            let name = userNameCache[uid] ?? uid
            let c = await company(forUser: uid)
            lines.append("- \(name): \(c.isEmpty ? "your colleague (internal)" : "external — \(c)")")
        }
        return lines.isEmpty ? "" : "People in this thread:\n" + lines.joined(separator: "\n")
    }

    /// Compact, durable "who's here" snapshot stored on the todo: "Tom (Amber),
    /// Bella (colleague)". Lets the memory rebuild ground people + orgs in the
    /// Slack facts instead of guessing from prose.
    private func participantsNote(_ replies: [SlackClient.Message]) async -> String? {
        var seen = Set<String>()
        var parts: [String] = []
        for msg in replies {
            guard let uid = msg.user, uid != settings.slackUserID, seen.insert(uid).inserted else { continue }
            let name = userNameCache[uid] ?? uid
            let c = await company(forUser: uid)
            parts.append(c.isEmpty ? "\(name) (colleague)" : "\(name) (\(c))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Thread / user / channel resolution

    /// Resolves a Slack channel ID into a friendly name.
    /// - Channels → channel name
    /// - 1:1 DMs → other person's first name
    /// - Group DMs → "Alice, Bob, Carol" (up to 3, then "+ N others")
    private func resolveChannelName(channelID: String,
                                    fallback: String? = nil) async -> String {
        if let cached = channelNameCache[channelID] { return cached }
        do {
            let info = try await slack.conversationInfo(channelID: channelID)
            var name: String

            if info.isDM, let partnerID = info.dmPartnerUserID {
                let full = (try? await slack.userDisplayName(userID: partnerID)) ?? "DM"
                name = Self.firstName(full)

            } else if info.isGroupDM {
                name = await resolveGroupDMName(channelID: channelID)

            } else if info.isDM, let fb = fallback, fb.hasPrefix("U") {
                let full = (try? await slack.userDisplayName(userID: fb)) ?? "DM"
                name = Self.firstName(full)

            } else if info.isDM {
                name = "DM"
            } else if info.name.hasPrefix("mpdm-") {
                // Fallback: conversations.info sometimes doesn't set is_mpim
                // but the name pattern is unmistakable.
                name = await resolveGroupDMName(channelID: channelID)

            } else if !info.name.isEmpty, info.name != "(direct message)" {
                name = info.name
            } else if let fb = fallback, !fb.isEmpty, fb != channelID {
                name = fb
            } else {
                name = channelID
            }
            channelNameCache[channelID] = name
            return name
        } catch {
            if let fb = fallback, fb.hasPrefix("U"), fb.count > 5 {
                let full = (try? await slack.userDisplayName(userID: fb)) ?? fb
                let name = Self.firstName(full)
                channelNameCache[channelID] = name
                return name
            }
            // Catch mpdm- pattern even when the API call fails entirely
            if let fb = fallback, fb.hasPrefix("mpdm-") {
                let name = await resolveGroupDMName(channelID: channelID)
                channelNameCache[channelID] = name
                return name
            }
            let name = (fallback?.isEmpty == false && fallback != channelID) ? fallback! : channelID
            channelNameCache[channelID] = name
            return name
        }
    }

    /// Resolve a group DM to "Alice, Bob, Carol" or "Alice, Bob + 3 others".
    private func resolveGroupDMName(channelID: String) async -> String {
        guard let members = try? await slack.conversationMembers(channelID: channelID) else {
            return "Group DM"
        }
        // Exclude the user from the list
        let others = members.filter { $0 != settings.slackUserID }
        var names: [String] = []
        for id in others.prefix(3) {
            let full = (try? await slack.userDisplayName(userID: id)) ?? id
            names.append(Self.firstName(full))
        }
        let remaining = others.count - names.count
        if remaining > 0 {
            return names.joined(separator: ", ") + " + \(remaining) others"
        }
        return names.joined(separator: ", ")
    }

    private static func firstName(_ displayName: String) -> String {
        let first = displayName.split(separator: " ").first.map(String.init)
        return first ?? displayName
    }

    private func fetchThread(channelID: String, parentTs: String) async throws -> [SlackClient.Message] {
        let cacheKey = "\(channelID):\(parentTs)"
        if let cached = threadCache[cacheKey] { return cached }

        // DMs are flat conversations — replies come as new messages, not thread
        // replies. So for a DM, read the conversation from the ask onward (via
        // history) rather than conversations.replies, otherwise we'd only ever
        // see the first message and never notice a reply / resolution.
        if channelID.hasPrefix("D") {
            let oldest = String(format: "%.6f", (Double(parentTs) ?? 0) - 1)
            let history = try await slack.conversationHistory(channelID: channelID, after: oldest)
            // history is newest-first; present oldest-first like a thread.
            let ordered = history.sorted { compareTs($0.ts, $1.ts) < 0 }
            threadCache[cacheKey] = ordered
            return ordered
        }

        var replies = try await slack.conversationReplies(channelID: channelID, threadTs: parentTs)
        // The stored ts can be a reply rather than the thread root — Slack
        // search doesn't always return thread_ts, so ingest sometimes keys off
        // a reply. conversations.replies on a reply ts returns only that one
        // message, leaving us blind to the rest of the thread (including any
        // resolution). Detect that and re-fetch from the real root.
        if let root = replies.first?.thread_ts, root != parentTs {
            replies = try await slack.conversationReplies(channelID: channelID, threadTs: root)
        }
        threadCache[cacheKey] = replies
        return replies
    }

    /// Fetch + cache the display name of every message author so thread lines
    /// can be attributed. Without this the model can't tell who is speaking and
    /// mistakes the most active participant for the user.
    private func primeAuthorNames(_ messages: [SlackClient.Message]) async {
        let ids = Set(messages.compactMap { $0.user }).subtracting([settings.slackUserID])
        for id in ids where userNameCache[id] == nil {
            if let name = try? await slack.userDisplayName(userID: id) {
                userNameCache[id] = name
            }
        }
    }

    /// Author label for a thread line: "[ME]" for the user, otherwise the
    /// resolved display name (prime the cache first via `primeAuthorNames`).
    private func authorLabel(for msg: SlackClient.Message) -> String {
        if msg.user == settings.slackUserID { return "[ME]" }
        if let uid = msg.user { return userNameCache[uid] ?? uid }
        return "unknown"
    }

    /// Resolves `<@U…>` references in every message to `@DisplayName`, using
    /// the worker's user-name cache to avoid re-fetching the same user.
    private func resolveAllUserMentions(in messages: [SlackClient.Message]) async -> [SlackClient.Message] {
        // Collect unique user IDs to look up.
        var ids = Set<String>()
        let regex = try? NSRegularExpression(pattern: "<@([A-Z0-9]+)>")
        for msg in messages {
            guard let text = msg.text else { continue }
            let ns = NSRange(text.startIndex..., in: text)
            regex?.enumerateMatches(in: text, range: ns) { match, _, _ in
                guard let m = match,
                      let r = Range(m.range(at: 1), in: text) else { return }
                ids.insert(String(text[r]))
            }
        }

        // Prime the cache.
        for id in ids where userNameCache[id] == nil {
            if let name = try? await slack.userDisplayName(userID: id) {
                userNameCache[id] = name
            }
        }

        // Rewrite messages with resolved mentions.
        return messages.map { msg in
            guard let text = msg.text, let regex else { return msg }
            let ns = NSRange(text.startIndex..., in: text)
            var rewritten = text
            // Reverse iterate so ranges stay valid.
            let matches = regex.matches(in: text, range: ns).reversed()
            for m in matches {
                guard let outer = Range(m.range, in: rewritten),
                      let inner = Range(m.range(at: 1), in: rewritten) else { continue }
                let id = String(rewritten[inner])
                let name = userNameCache[id] ?? id
                rewritten.replaceSubrange(outer, with: "@\(name)")
            }
            return SlackClient.Message(
                ts: msg.ts,
                user: msg.user,
                text: rewritten,
                thread_ts: msg.thread_ts,
                parent_user_id: msg.parent_user_id,
                subtype: msg.subtype,
                bot_id: msg.bot_id,
                username: msg.username,
                reactions: msg.reactions,
                files: msg.files
            )
        }
    }

    // MARK: - LLM: thread assessment (Haiku)

    private struct ThreadAssessment {
        enum Status { case skip, open, inProgress, waiting, done }
        let status: Status
        let classification: TodoClassification
        let priority: TodoPriority
        let priorityReason: String?
        let due: Date?
        let note: String?
        let forYouConfidence: Double   // 1 = unmistakably the user's action
        let doneConfidence: Double     // 1 = clearly resolved (when status done)
        let forYouReason: String?
    }

    private static let assessSystemBase = """
    You assess Slack threads to decide whether they're an actionable item for
    THE USER (the person these todos belong to) — and what the current state is,
    based on the FULL thread context (including any responses the user or their
    teammates have already made). The user's name and aliases are given in the
    IDENTITY section below; their own messages are marked "[ME]".

    ALWAYS return the JSON object, even when you cannot assess the thread. If the
    thread is empty, fragmentary, or you lack the context to judge it, return
    {"status": "skip"} with low confidences. NEVER reply with prose, a question,
    or an apology — only the JSON.

    Return ONLY a JSON object:
      "status": "skip" | "open" | "in_progress" | "waiting" | "done"
      "classification": "todo" | "update"  (only meaningful when status != "skip")
      "priority": "high" | "normal" | "low"  (only meaningful when open/in_progress)
      "priority_reason": one sentence (≤ 15 words) in SECOND PERSON — address
                         the user as "you"/"your", never "the user" or "User".
                         For any deadline timing, write the literal token {due}
                         instead of a day word ("today"/"Friday"); the app fills
                         in the live date. E.g. "You committed to finishing {due};
                         blocks the launch."
      "due": "YYYY-MM-DD" or null — deadline from the thread (see DUE DATE)
      "for_you_confidence": 0.0–1.0 — how sure this is genuinely an action YOU
                            must take (vs someone else's, an FYI, or only loosely
                            yours). 1 = unmistakably yours; ~0.5 = plausibly but
                            unsure; low = probably not.
      "done_confidence": 0.0–1.0 — only when status is "done": how sure it's
                         truly resolved. 1 = clearly handled; ~0.5 = looks done
                         but you're inferring; low = a guess.
      "for_you_reason": one short second-person sentence — why this might (not) be
                        yours. Only needed when for_you_confidence is below ~0.75.
      "note": optional ≤ 80-char description of the current state

    --- DECISIVE TEST (apply before everything else) ---
    For a todo to be "open" or "in_progress", there must be a SPECIFIC,
    currently-outstanding action that THE USER PERSONALLY must take — e.g. a
    question directed at the user they haven't answered, or a task the user
    committed to ([ME] said they'd do X) that isn't finished yet.
      * No personal action outstanding RIGHT NOW, but the user is waiting on
        someone else to reply or deliver something the user will then act on
        (including a step the user handed to a teammate) → "waiting".
      * No such personal action outstanding and nothing is expected back to the
        user → "done" (or "skip" if it was never really theirs). This holds EVEN
        IF the thread is active and in the user's domain (their customer, their
        project). Other people working a thread the user cares about is not a
        task for the user.
      * "Monitoring", "staying across it", "keeping an eye on it", or being
        looped in for awareness are NOT actionable — they do not justify
        "open"/"in_progress". If that's all that's left for the user, it's "done".

    --- STATUS ---

    "skip" — don't track this at all:
      * The user's name appears incidentally (mention is "FYI @user" or "ask
        @user about it" but no actual ask of them)
      * Casual chat / off-topic
      * An invitation or request to JOIN / ATTEND / HOP ON a scheduled call,
        huddle, meeting, or sync ("jump on the call", "join the huddle", "can
        you hop on", "join my call to look at X"). Attending a meeting is not a
        todo — the user's calendar handles that. Only track it if there's a
        concrete deliverable the user must produce OUTSIDE the meeting itself
        (e.g. "send the deck before the call", "write up X by Friday") — mere
        attendance, or "give feedback on the call", never counts.

    "done" — track it but it's complete:
      * The user's reply addresses the original ask (question answered, info
        provided, task committed to, fix shipped, etc.). Does NOT need to
        have "quieted" — a reply that resolves the ask is enough.
      * Someone else in the thread resolved the ask on the user's behalf
        (e.g. a teammate fixed/rolled back/shipped it). The work being done
        by anyone closes it for the user.
      * The user reacted ✅ / ☑️ / ✔️ / 👍 on the parent
      * The thread's original ask is resolved and the conversation has moved
        on to RELATED-BUT-SEPARATE work whose current owner is clearly someone
        else (a teammate or the customer) — the user has nothing they need to
        do right now. Closing is correct even if the thread is still active.
      * There's a follow-up question AFTER the user's reply that is still
        directed at the user and unanswered → NOT done; use "open"/"in_progress"
        instead. But a follow-up aimed at someone else does not keep it open
        for the user.

    "in_progress" — actively being worked:
      * The user has replied in the thread (a [ME] message appears), but their
        reply doesn't fully resolve the ask — partial answer, "looking
        into it", or back-and-forth still going
      * Someone is actively working on it and the user is looped in

    "open" — outstanding ask for the user:
      * Clear question or request with no reply from the user yet
      * Someone is waiting on the user to respond / act
      * A follow-up question was posted AFTER the user's earlier reply and
        the user hasn't responded to it yet

    "waiting" — the next move is someone ELSE'S, and the user is waiting on it
    before they can act (it's expected to come back to them):
      * The user DELEGATED the next step to a teammate — [ME] asked or told a
        colleague to do X ("can you grab X", "you get the list from <client>,
        then we'll do Y"). The action is now THEIRS; the user is waiting on them
        to deliver before the user's own part can continue.
      * The user is BLOCKED on someone's reply, input, decision, deliverable, or
        approval to CONTINUE THEIR OWN WORK — once it lands, the user has a
        concrete thing they will then do. Parking it lets them get on with other
        work meanwhile.
      Asking a question is "waiting" ONLY if the user's own work depends on the
      answer. A bare clarifying or FYI question — where the reply would just
      inform the user, with no task of theirs hanging on it — is NOT a todo: use
      "skip". Especially in a thread the user isn't otherwise part of, a one-off
      question they dropped in is "skip" unless a concrete action of theirs
      hinges on the reply.
      Use the people context to tell colleagues from clients — delegating to a
      teammate, or waiting on a client/partner, both count. This is DIFFERENT
      from "done": "done" means nothing comes back to the user; "waiting" means
      they expect a reply or result they'll then act on. When the only thing
      left is someone else's move that loops back to the user, prefer "waiting"
      over both "open" (it isn't the user's move yet) and "done" (it isn't over).
      BALL-BACK RULE (decides waiting vs open): the LATEST message decides who
      owes the next move, and that OVERRIDES how the thread opened. If the most
      recent message asks the user a question, requests a decision, or hands
      something back for the user to answer or approve, the ball is now the
      USER'S → "open" (or "in_progress" if a [ME] reply is already underway) —
      EVEN IF the user opened the thread asking others for help. Stay "waiting"
      only when the latest message genuinely leaves the next move with someone
      else. Worked example: the user asks a teammate to help unblock something
      (opens like waiting); the teammate replies with a question back at the user
      ("what's the generic shape here — does this come up a lot?"). That question
      is aimed at the user, so the ball has returned to them: "open", NOT
      "waiting".

    --- WHO IS THE USER ---
    Each thread line is prefixed with its author: "[ME]" for the user, otherwise
    the person's name (e.g. "- Anna (2h ago): ..."). ONLY lines prefixed "[ME]"
    are from the user. If you do not see "[ME]" at the start of a line, that
    message is NOT the user's.
      * Do NOT assume any participant is the user. Other teammates, colleagues,
        and engineers are NOT the user. The customer is NOT the user. Never
        re-label the most active person as the user.
      * If NO line is prefixed "[ME]", then the user has sent zero messages in
        this thread — state nothing to the contrary. Asks exchanged BETWEEN
        OTHER PEOPLE (a teammate and a customer, two colleagues) do NOT create
        work for the user. In that case answer "skip" (the user was only cc'd /
        looped in for visibility) or "done" (others are handling or have
        handled it).
      * A teammate (not the user) handling or resolving the work = resolved by
        someone else = "done" for the user, never "in_progress".

    KEY RULE: if a [ME] message exists in the thread, the status is NEVER
    "open" unless there is a newer unanswered follow-up question directed
    at the user after their reply. The user having replied means at minimum
    "in_progress", or "done" if their reply resolves the ask.

    --- CLASSIFICATION (be biased toward "todo") ---

    "todo": the user could plausibly need to do something — respond, decide,
            follow up, investigate, fix, dig into something, or close a loop.
            Default to "todo" if it's not clearly informational-only.

    "update": ONLY when the thread is purely informational with zero expected
              response from the user. E.g., "Andrew is WFH today", "We shipped X
              to prod" — the user reads it and there's nothing to do.

    Anything that could plausibly require the user's input or action is "todo".

    --- PRIORITY (default to "normal"; "high" must be earned) ---

    "high" — ONLY when at least one clearly holds:
      * Someone is blocked and waiting on the user — they cannot proceed
        without the user's reply or action.
      * An external party (customer, client, partner) is waiting on the user
        and the delay has real consequences (escalation, churn risk, them
        seeking alternatives, an explicit complaint about waiting).
      * A deadline or meeting within ~the next day depends on the user doing
        this first.
      * The message itself is explicitly urgent ("ASAP", "today", "blocking").
      * The user committed to doing it TODAY ("I'll do this today", "on it
        this arvo"), or someone asked for it today — a same-day commitment or
        ask is high until done.

    "normal" — everything else. This is the default; the vast majority of
    todos are "normal".

    "low" — pure housekeeping with no one waiting: routine submissions,
    optional reviews, FYIs flagged for action, anything that could slip a week
    with zero consequence.

    Do NOT mark "high" just because a thread is busy, a customer is involved,
    or the topic is important in general. High means: delay is actively
    hurting someone right now. When torn between high and normal, choose
    normal.

    --- DUE DATE ---

    "due": the specific day the user committed to, or was asked, to do this by.
    Resolve relative phrases against WHEN THAT MESSAGE WAS SENT (each line has
    a timestamp; today's date is in the payload): "tomorrow" in a message sent
    Monday = Tuesday. "by Friday" = that Friday. "next week" = Monday of the
    following week. "end of week" = that Friday.
      * ONLY when a timeframe is EXPLICITLY stated in the thread text. Never
        infer one — an initiative "kicking off next week", a launch coming up,
        or context suggesting it'd be good to do soon is NOT a due date.
        No stated timeframe → null.
      * "I'll look at it at some point" or vague intentions → null.
      * Never invent weekend dates; a deadline lands on a weekend only if the
        thread literally says so.
      * A future due date does NOT make the priority "high" today — priority
        stays as judged; the deadline elevates it automatically when the day
        arrives.
      * If the commitment was already fulfilled, null.

    --- TIE-BREAKERS ---

    * Skip vs track: track when uncertain. Better to surface than miss.
    * Todo vs update: prefer "todo". A missed action item is worse than an
      action-flagged FYI.
    * Open vs in_progress: if the user has replied, prefer "in_progress".
    * In_progress vs done: if the user's reply fully answers the ask and no one
      has asked a follow-up, prefer "done".

    --- FORWARDED / SHARED MESSAGES ---

    If a thread message looks like a Slack share/forward of someone else's
    message (e.g. a [ME] message that re-quotes someone else's text from another
    channel, or attaches another message), do NOT treat the quoted/shared
    content as a fresh ask of the user. The act of forwarding means the user is
    the one seeking input, not the one being asked. In DMs especially, forwards
    are common and the DM partner is being consulted, not assigning work to the
    user.

    The user's own messages start with "[ME]" in the thread excerpt below.
    """

    /// Combines the static system prompt with the user's own "about me" text and
    /// the learned background-context glossary.
    private func systemPrompt(_ base: String) -> String {
        var out = base
        // Identity: who "[ME]" / "the user" actually is, so the model can match
        // their name when others address them by name in a thread.
        var idLines: [String] = []
        let name = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { idLines.append("Name: \(name)") }
        let aliases = settings.aliases.trimmingCharacters(in: .whitespacesAndNewlines)
        if !aliases.isEmpty { idLines.append("Also goes by: \(aliases)") }
        if !idLines.isEmpty {
            out += "\n\n--- IDENTITY (who \"[ME]\" / \"the user\" is) ---\n" + idLines.joined(separator: "\n")
        }
        let ctx = settings.userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            out += "\n\n--- ABOUT THE USER (their own words) ---\n\(ctx)"
        }
        if !memoryContext.isEmpty {
            out += """


            --- BACKGROUND CONTEXT (recurring people, organizations, projects, terms) ---
            \(memoryContext)
            This glossary is for interpreting the thread only. Never present it
            as fact from the thread, and never derive deadlines or urgency from
            it — only the thread text itself can set those.
            """
        }
        return out
    }

    /// Render the stored glossary into a compact, grouped block for prompts.
    private func loadMemoryContext(ctx: ModelContext) {
        let entries = ((try? ctx.fetch(FetchDescriptor<MemoryEntry>())) ?? [])
            .filter { $0.confirmed || $0.pinned }   // candidates stay out of prompts until corroborated
            .sorted { ($0.mentions, $0.lastSeen) > ($1.mentions, $1.lastSeen) }
        guard !entries.isEmpty else { memoryContext = ""; return }
        var blocks: [String] = []
        for kind in MemoryKind.allCases {
            let group = entries.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            let lines = group.map { "  - \($0.name): \($0.detail)" }.joined(separator: "\n")
            blocks.append("\(kind.label):\n\(lines)")
        }
        memoryContext = blocks.joined(separator: "\n")
    }

    private func assessThread(replies: [SlackClient.Message],
                              channelName: String,
                              existingTitle: String?) async throws -> ThreadAssessment {
        // Nothing to assess — a textless thread (e.g. a file-only post the
        // participant search matched). Skip without spending an LLM call.
        guard replies.contains(where: { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            return ThreadAssessment(status: .skip, classification: .todo, priority: .normal,
                                    priorityReason: nil, due: nil, note: nil,
                                    forYouConfidence: 0, doneConfidence: 0, forYouReason: nil)
        }
        let parent = replies.first
        let reactionList = (parent?.reactions ?? [])
            .map { r in
                let userTag = (r.users?.contains(settings.slackUserID) == true) ? " [by me]" : ""
                return "\(r.name)\(userTag)"
            }
            .joined(separator: ", ")

        await primeAuthorNames(replies)
        let lines = replies.prefix(40).map { msg -> String in
            let who = authorLabel(for: msg)
            let date = SlackClient.dateFromTs(msg.ts).map { Self.relative($0) } ?? ""
            return "- \(who) (\(date)): \(Self.excerptText(msg.text))"
        }.joined(separator: "\n")
        let people = await participantsBlock(replies)

        let titleHint = existingTitle.map { "Existing tracked title: \($0)\n" } ?? ""
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE d MMMM yyyy"
        let payload = """
        Today is \(dayFormatter.string(from: Date())).
        Channel: #\(channelName)
        The user's Slack user ID: \(settings.slackUserID)
        Parent reactions: \(reactionList.isEmpty ? "(none)" : reactionList)
        \(people.isEmpty ? "" : people + "\n")\(titleHint)
        Thread (oldest → newest):
        \(lines)
        """

        // When the user hasn't spoken in the thread, deciding whether it's even theirs
        // is the hard case Haiku gets wrong (it mistakes the active participant
        // for the user). Use the stronger model there; keep the fast model when the user is active.
        let patPresent = replies.contains { $0.user == settings.slackUserID }
        let json = try await llm.sendForJSON(
            tier: patPresent ? .fast : .smart,
            system: systemPrompt(Self.assessSystemBase),
            userMessage: payload,
            maxTokens: 250,
            temperature: 0.1
        )
        let status: ThreadAssessment.Status = {
            switch (json["status"] as? String) ?? "open" {
            case "skip": return .skip
            case "done": return .done
            case "in_progress": return .inProgress
            case "waiting": return .waiting
            default: return .open
            }
        }()
        let cls = TodoClassification(rawValue: (json["classification"] as? String) ?? "todo") ?? .todo
        let priority = TodoPriority(rawValue: (json["priority"] as? String) ?? "normal") ?? .normal
        let due = (json["due"] as? String).flatMap { s -> Date? in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: s)
        }
        // Default confidences to 1 — absence means "no doubt expressed", which
        // preserves the silent-action behaviour; review only triggers when the
        // model actively flags uncertainty.
        func conf(_ key: String) -> Double {
            (json[key] as? Double) ?? (json[key] as? NSNumber)?.doubleValue ?? 1.0
        }
        return ThreadAssessment(
            status: status,
            classification: cls,
            priority: priority,
            priorityReason: json["priority_reason"] as? String,
            due: due,
            note: json["note"] as? String,
            forYouConfidence: conf("for_you_confidence"),
            doneConfidence: conf("done_confidence"),
            forYouReason: json["for_you_reason"] as? String
        )
    }

    // MARK: - LLM: thread summary (Sonnet)

    private struct SummariseResult {
        let title: String
        let summary: String
    }

    private static let summariseSystemBase = """
    You write very short todo entries for the user, based on a Slack thread.
    The user's own messages are marked "[ME]"; their name is in the IDENTITY
    section below.

    Return ONLY a JSON object:
      "title": short headline, verb-first if it's a todo, ≤ 8 words
      "summary": 2 sentences max. Sentence 1: who, what, where it stands.
                  Sentence 2: why it matters or what's expected of the user next.

    --- SCOPE: right-sized, actionable ---
    * A todo is one reasonably-sized actionable item — the concrete next step
      the user owns. Not a sprawling project ("Complete 4 priorities"), not a
      trivial fragment ("reply to Bob").
    * If the thread bundles several distinct asks, title the SINGLE most
      important outstanding one for the user; don't roll them into a vague
      umbrella.
    * Reflect the CURRENT state of the thread, not where it started. If the
      original ask was resolved and the conversation moved on, the title should
      describe what's outstanding now (or nothing, if the user is done).

    --- CRITICAL: NO HALLUCINATION ---
    * Use ONLY facts that appear verbatim in the thread below.
    * NEVER invent or guess people's names. If a person's name doesn't appear
      literally in the thread text (as an @mention or in their message), refer
      to them generically ("they", "the other person") instead.
    * Do NOT invent product features, technical details, customer names, or
      domain terms that aren't in the thread.
    * If you'd need a detail you don't have, write a vaguer summary rather
      than guess.

    --- VOICE ---
    - Second person ("you", "your"), addressing the user directly. Never "the
      user" or "User".
    - Name specific people by their @display name (already resolved in the
      thread). NEVER use "your teammate" or "someone" — if the name is in the
      thread, use it.
    - For any deadline timing, write the literal token {due} (not "today",
      "tomorrow", a weekday, or a date) ONLY when the payload says a deadline
      is set — the app fills in the live relative date.
    - Capture commitments concretely.
    - No corporate hedging, no "please review and respond at your convenience".

    The user's own messages in the thread start with "[ME]".
    """

    private func summariseThread(replies: [SlackClient.Message],
                                 channelName: String,
                                 classification: TodoClassification,
                                 due: Date? = nil) async throws -> SummariseResult {
        await primeAuthorNames(replies)
        let lines = replies.prefix(30).map { msg -> String in
            return "- \(authorLabel(for: msg)): \(Self.excerptText(msg.text))"
        }.joined(separator: "\n")

        let dueLine = due != nil
            ? "A deadline is set — use the {due} token when referring to its timing.\n"
            : "No deadline is set — do not use the {due} token.\n"
        let payload = """
        \(dueLine)Channel: #\(channelName)
        Classification: \(classification.rawValue)
        Thread:
        \(lines)
        """
        let json = try await llm.sendForJSON(
            tier: .smart,
            system: systemPrompt(Self.summariseSystemBase),
            userMessage: payload,
            maxTokens: 250,
            temperature: 0.1
        )
        return SummariseResult(
            title: (json["title"] as? String) ?? "Untitled",
            summary: (json["summary"] as? String) ?? ""
        )
    }

    // MARK: - Diagnostic mode

    struct DiagnosticItem: Identifiable {
        let id = UUID()
        let source: String          // "@mention" / "watched-channel" / "participant"
        let channel: String
        let channelID: String
        let parentTs: String
        let permalink: URL?
        let triggerText: String     // the matched message snippet
        let resolvedThreadLines: [String]
        let assessmentInput: String
        let assessmentRaw: String
        let assessmentStatus: String
        let assessmentClassification: String
        let assessmentNote: String?
        let summariseInput: String?
        let summariseRaw: String?
        let title: String?
        let summary: String?
    }

    struct DiagnosticReport {
        var items: [DiagnosticItem] = []
        var errors: [String] = []
        var durationSeconds: Double = 0
    }

    /// Pull up to `limit` candidates and pass each through the full pipeline,
    /// but don't write anything to the DB. Captures every LLM input/output
    /// so the user can inspect why each item was kept / skipped / classified.
    func runDiagnostic(limit: Int = 5) async -> DiagnosticReport {
        let start = Date()
        var report = DiagnosticReport()
        let ctx = ModelContext(container)

        // Pull recent mention candidates without using the cursor — fresh look.
        let mentions: [SlackClient.SearchMatch]
        do {
            mentions = try await slack.searchMentions(handle: settings.slackHandle, after: nil)
        } catch {
            report.errors.append("mentions: \(error.localizedDescription)")
            report.durationSeconds = Date().timeIntervalSince(start)
            return report
        }

        let ignoredIDs: Set<String> = {
            let rows = (try? ctx.fetch(FetchDescriptor<IgnoredMentionChannel>())) ?? []
            return Set(rows.map { $0.channelID })
        }()

        var items: [DiagnosticItem] = []
        for match in mentions where items.count < limit {
            if match.user == settings.slackUserID { continue }
            if (match.text ?? "").isEmpty { continue }
            if ignoredIDs.contains(match.channel.id) { continue }

            let parentTs = match.threadParentTs
            let channel = await resolveChannelName(
                channelID: match.channel.id,
                fallback: match.channel.name
            )

            do {
                if let item = try await buildDiagnostic(
                    source: "@mention",
                    channelID: match.channel.id,
                    channelName: channel,
                    parentTs: parentTs,
                    triggerText: match.text ?? "",
                    permalink: match.permalink
                ) {
                    items.append(item)
                }
            } catch {
                report.errors.append("diag: \(error.localizedDescription)")
            }
        }

        report.items = items
        report.durationSeconds = Date().timeIntervalSince(start)
        return report
    }

    private func buildDiagnostic(source: String,
                                 channelID: String,
                                 channelName: String,
                                 parentTs: String,
                                 triggerText: String,
                                 permalink: URL?) async throws -> DiagnosticItem? {
        let replies = try await fetchThread(channelID: channelID, parentTs: parentTs)
        let resolved = await resolveAllUserMentions(in: replies)

        // Recreate the same payload the worker would send to the assessor.
        let parent = resolved.first
        let reactionList = (parent?.reactions ?? [])
            .map { r in
                let userTag = (r.users?.contains(settings.slackUserID) == true) ? " [by me]" : ""
                return "\(r.name)\(userTag)"
            }
            .joined(separator: ", ")
        let lines = resolved.prefix(40).map { msg -> String in
            let prefix = msg.user == settings.slackUserID ? "[ME] " : ""
            let date = SlackClient.dateFromTs(msg.ts).map { Self.relative($0) } ?? ""
            return "- \(prefix)(\(date)) \(msg.text?.prefix(300) ?? "")"
        }.joined(separator: "\n")
        let payload = """
        Channel: #\(channelName)
        The user's Slack user ID: \(settings.slackUserID)
        Parent reactions: \(reactionList.isEmpty ? "(none)" : reactionList)

        Thread (oldest → newest):
        \(lines)
        """

        let raw = try await llm.send(
            tier: .fast,
            system: systemPrompt(Self.assessSystemBase),
            userMessage: payload,
            maxTokens: 150,
            temperature: 0.1
        )
        let parsed = (try? llm.extractJSON(from: raw)) ?? [:]
        let status = (parsed["status"] as? String) ?? "open"
        let cls = (parsed["classification"] as? String) ?? "todo"
        let note = parsed["note"] as? String

        // Optionally summarise if we'd have kept it.
        var summariseInput: String? = nil
        var summariseRaw: String? = nil
        var title: String? = nil
        var summary: String? = nil
        if status == "open" || status == "in_progress" {
            let sLines = resolved.prefix(30).map { msg -> String in
                let prefix = msg.user == settings.slackUserID ? "[ME] " : ""
                return "- \(prefix)\(msg.text?.prefix(400) ?? "")"
            }.joined(separator: "\n")
            let sPayload = """
            Channel: #\(channelName)
            Classification: \(cls)
            Thread:
            \(sLines)
            """
            summariseInput = sPayload
            let sRaw = try await llm.send(
                tier: .smart,
                system: systemPrompt(Self.summariseSystemBase),
                userMessage: sPayload,
                maxTokens: 250,
                temperature: 0.1
            )
            summariseRaw = sRaw
            let sJson = (try? llm.extractJSON(from: sRaw)) ?? [:]
            title = sJson["title"] as? String
            summary = sJson["summary"] as? String
        }

        return DiagnosticItem(
            source: source,
            channel: channelName,
            channelID: channelID,
            parentTs: parentTs,
            permalink: permalink,
            triggerText: triggerText,
            resolvedThreadLines: resolved.prefix(40).map { msg -> String in
                let prefix = msg.user == settings.slackUserID ? "[ME] " : ""
                let date = SlackClient.dateFromTs(msg.ts).map { Self.relative($0) } ?? ""
                return "\(prefix)(\(date)) \(msg.text ?? "")"
            },
            assessmentInput: payload,
            assessmentRaw: raw,
            assessmentStatus: status,
            assessmentClassification: cls,
            assessmentNote: note,
            summariseInput: summariseInput,
            summariseRaw: summariseRaw,
            title: title,
            summary: summary
        )
    }

    // MARK: - Helpers

    private func existingTodo(threadKey: String, ctx: ModelContext) -> Todo? {
        let pred = #Predicate<Todo> { $0.threadKey == threadKey }
        return try? ctx.fetch(FetchDescriptor<Todo>(predicate: pred)).first
    }

    /// True if the user previously declined this thread as "not for me".
    private func isThreadIgnored(_ threadKey: String, ctx: ModelContext) -> Bool {
        let pred = #Predicate<IgnoredThread> { $0.threadKey == threadKey }
        return (try? ctx.fetch(FetchDescriptor<IgnoredThread>(predicate: pred)).first) != nil
    }

    /// Whether this thread was already folded into a work item as a merged
    /// source (cheap existence check; the route/reopen logic stays in
    /// `routeToMergedWorkItem`).
    private func mergedSourceExists(threadKey: String, ctx: ModelContext) -> Bool {
        let pred = #Predicate<TodoSource> { $0.threadKey == threadKey }
        return (try? ctx.fetch(FetchDescriptor<TodoSource>(predicate: pred)).first) != nil
    }

    /// Whether an open/in-progress todo already tracks this channel (used to
    /// keep a DM to a single active todo rather than one per message).
    private func openTodoExists(channelID: String, ctx: ModelContext) -> Bool {
        let pred = #Predicate<Todo> { $0.channelID == channelID && $0.status != "done" && $0.status != "archived" }
        return (try? ctx.fetch(FetchDescriptor<Todo>(predicate: pred)).first) != nil
    }

    /// If this thread was previously merged into a work item, route the new
    /// activity to that work item instead of spawning a duplicate todo:
    /// refresh its activity clock and reopen it if it had been closed.
    /// Returns true if the thread belonged to a merged source (handled).
    private func routeToMergedWorkItem(threadKey: String, ctx: ModelContext, report: inout Report) -> Bool {
        let pred = #Predicate<TodoSource> { $0.threadKey == threadKey }
        guard let source = try? ctx.fetch(FetchDescriptor<TodoSource>(predicate: pred)).first,
              let parent = source.todo else { return false }
        let now = Date()
        source.lastActivity = now
        parent.lastActivityAt = now
        parent.updatedAt = now
        if parent.statusEnum == .done || parent.statusEnum == .archived {
            parent.status = TodoStatus.open.rawValue
            parent.completedAt = nil
            parent.completionReason = nil
            ctx.insert(TodoComment(
                todo: parent,
                body: "Reopened — new activity in merged thread (\(source.sourceLabel))",
                isAutoTriage: true
            ))
            report.refreshed += 1
        }
        return true
    }

    private func processedMeeting(id: String, ctx: ModelContext) -> Bool {
        let pred = #Predicate<ProcessedGranolaMeeting> { $0.meetingID == id }
        return (try? ctx.fetch(FetchDescriptor<ProcessedGranolaMeeting>(predicate: pred)).first) != nil
    }

    /// One-time-ish migration: derive processed meeting IDs from existing
    /// Granola todos so meetings created before process-once tracking aren't
    /// re-scraped. Idempotent — safe to run every sync.
    private func backfillProcessedGranolaMeetings(ctx: ModelContext) {
        guard let todos = try? ctx.fetch(FetchDescriptor<Todo>()) else { return }
        let prefix = "granola:"
        let meetingIDs = Set(
            todos.compactMap { todo -> String? in
                guard todo.channelID.hasPrefix(prefix) else { return nil }
                return String(todo.channelID.dropFirst(prefix.count))
            }
        )
        for id in meetingIDs where !processedMeeting(id: id, ctx: ctx) {
            ctx.insert(ProcessedGranolaMeeting(meetingID: id))
        }
    }

    private func readCursor(key: String, ctx: ModelContext) -> String? {
        let pred = #Predicate<SyncCursor> { $0.key == key }
        return try? ctx.fetch(FetchDescriptor<SyncCursor>(predicate: pred)).first?.cursor
    }

    private func writeCursor(key: String, value: String, ctx: ModelContext) {
        let pred = #Predicate<SyncCursor> { $0.key == key }
        if let existing = try? ctx.fetch(FetchDescriptor<SyncCursor>(predicate: pred)).first {
            existing.cursor = value
        } else {
            ctx.insert(SyncCursor(key: key, cursor: value))
        }
    }

    private func compareTs(_ a: String, _ b: String?) -> Int {
        guard let b else { return 1 }
        if a == b { return 0 }
        return a > b ? 1 : -1
    }

    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}
