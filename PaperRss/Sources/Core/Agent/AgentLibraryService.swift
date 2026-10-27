import Foundation
import GRDB
#if SWIFT_PACKAGE
import PaperRssAgentProtocol
#endif

/// One app-owned authorization session. No database creation, refresh or network commands.
/// Production transport/pairing is deliberately not connected in this spike.
public actor AgentLibraryService: AgentBridge {
    private let database: LibraryDatabase
    private let provider: LocalAccountProvider
    private let engine: ArticlePreparationEngine
    private let clock: @Sendable () -> Date
    private var policy: AgentAccessPolicy
    private var remainingCharacters: Int
    private var requestTimes: [Date] = []
    private struct Selection {
        let account: String
        let ids: Set<String>
        let expires: Date
    }
    private struct PendingPlan {
        let dto: AgentStatePlan
        let before: [String: ArticleStateRecord]
        var approval: String?
        var receipt: AgentStateReceipt?
    }
    private struct Replay {
        let plan: String
        let approval: String
        let receipt: AgentStateReceipt
    }
    private struct Cursor {
        let arguments: [String: AgentJSON]
        let offset: Int
        let expires: Date
    }
    private var selections: [String: Selection] = [:]
    private var plans: [String: PendingPlan] = [:]
    private var receipts: [String: Replay] = [:]
    private var cursors: [String: Cursor] = [:]

    public init(database: LibraryDatabase, accountID: String = "local-default",
                policy: AgentAccessPolicy = AgentAccessPolicy(),
                engine: ArticlePreparationEngine = ArticlePreparationEngine(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.provider = LocalAccountProvider(accountID: accountID, database: database)
        self.policy = policy
        self.engine = engine
        self.clock = clock
        self.remainingCharacters = policy.outputCharacterBudget
    }

    /// App-only revocation: invalidates all grants immediately. Never exposed as an MCP tool.
    public func revoke() {
        policy.enabled = false
        selections.removeAll()
        plans.removeAll()
        cursors.removeAll()
    }

    /// Called only by the trusted App confirmation bridge, never by RPC arguments.
    public func authorizeContent(accountID: String, articleIDs: [String]) throws -> String {
        try authorize(accountID)
        guard !articleIDs.isEmpty, articleIDs.count <= 20, Set(articleIDs).count == articleIDs.count else {
            throw AgentFailure("INVALID_ARGUMENT", "Select 1–20 distinct articles.")
        }
        try database.read { db in
            for id in articleIDs { _ = try ownedEntry(id, account: accountID, in: db) }
        }
        guard selections.count < 20 else { throw AgentFailure("RATE_LIMITED", "Too many active selections.") }
        let id = UUID().uuidString
        selections[id] = Selection(account: accountID, ids: Set(articleIDs), expires: clock().addingTimeInterval(900))
        return id
    }

    /// App-only approval, bound to the immutable plan. Confirmation UI must show retention_notice.
    public func approve(planID: String) throws -> String {
        try requireEnabled()
        guard var plan = plans[planID], plan.dto.expires_at > clock(), plan.receipt == nil else {
            throw AgentFailure("CONFLICT", "Plan is missing, expired or already committed.")
        }
        try authorize(plan.dto.account_id, write: true)
        let approval = plan.approval ?? UUID().uuidString
        plan.approval = approval
        plans[planID] = plan
        return approval
    }

    public func call(tool: String, arguments a: [String: AgentJSON]) async throws -> AgentJSON {
        try Task.checkCancellation()
        if tool == "paperrss_status" { return try status(a) }
        try requireEnabled()
        let now = clock()
        requestTimes.removeAll { now.timeIntervalSince($0) >= 60 }
        guard requestTimes.count < 60 else { throw AgentFailure("RATE_LIMITED", "Retry after one minute.") }
        requestTimes.append(now)
        cursors = cursors.filter { $0.value.expires > now }
        selections = selections.filter { $0.value.expires > now }
        plans = plans.filter { $0.value.dto.expires_at > now || $0.value.receipt != nil }
        switch tool {
        case "paperrss_list_feeds": return try listFeeds(a)
        case "paperrss_list_articles": return try listArticles(a)
        case "paperrss_get_article":
            let account = try string(a, "account_id")
            try authorize(account)
            let metadata = try metadataForID(try string(a, "article_id"), account: account, requireScope: true)
            try charge(metadata)
            return try .encoding(metadata)
        case "paperrss_get_content": return try await content(a)
        case "paperrss_plan_state_change": return try plan(a)
        case "paperrss_apply_state_change": return try apply(a)
        case "paperrss_add_feed", "paperrss_rename_feed", "paperrss_remove_feed":
            try authorize(try string(a, "account_id"))
            // Do not claim an approvable operation when feed deletion/redirect policy is unfinished.
            throw AgentFailure("UNSUPPORTED", "Feed mutation contract only: App confirmation and provider integration are not implemented in this spike.")
        default: throw AgentFailure("INVALID_ARGUMENT", "Unknown tool.")
        }
    }

    private func status(_ a: [String: AgentJSON]) throws -> AgentJSON {
        guard policy.enabled else {
            return .object(["version": .string("agent-spike-1"), "enabled": .bool(false),
                            "paired": .bool(false), "accounts": .array([])])
        }
        var data: [String: AgentJSON] = [
            "version": .string("agent-spike-1"), "enabled": .bool(true), "paired": .bool(false),
            "transport": .string("in_process_spike"),
            "accounts": .array(policy.accountIDs.sorted().map { .object([
                "account_id": .string($0), "capabilities": .array(
                    (["metadata.read", "content.read.selection"] + (policy.allowStateChanges ? ["state.write"] : [])).map { .string($0) })]) }),
            "selection_ids": .array(selections.filter { $0.value.expires > clock() }.keys.sorted().map { .string($0) }),
            "remaining_characters": .number(Double(remainingCharacters))
        ]
        if let id = a["plan_id"]?.stringValue {
            guard let plan = plans[id] else { throw AgentFailure("NOT_FOUND", "Plan not found in this session.") }
            data["plan"] = try .encoding(plan.dto)
            data["plan_state"] = .string(plan.receipt != nil ? "committed" : plan.dto.expires_at <= clock() ? "expired" : plan.approval == nil ? "pending" : "approved")
            if plan.dto.expires_at > clock(), let approval = plan.approval { data["approval_id"] = .string(approval) }
            if let receipt = plan.receipt { data["receipt"] = try .encoding(receipt) }
        }
        if let id = a["operation_id"]?.stringValue {
            guard let receipt = receipts.values.first(where: { $0.receipt.operation_id == id })?.receipt else {
                throw AgentFailure("NOT_FOUND", "Operation not found in this session.")
            }
            data["receipt"] = try .encoding(receipt)
        }
        return .object(data)
    }

    private func requireEnabled() throws {
        guard policy.enabled else { throw AgentFailure("NOT_ENABLED", "Local agent access is off.") }
    }
    private func authorize(_ account: String, write: Bool = false) throws {
        try requireEnabled()
        guard policy.accountIDs.contains(account), account == provider.accountID else {
            throw AgentFailure("UNAUTHORIZED", "Account is outside this session.")
        }
        try database.read { db in try checkAccount(account, in: db) }
        if write && !policy.allowStateChanges { throw AgentFailure("UNAUTHORIZED", "State changes are not enabled.") }
    }
    private func checkAccount(_ account: String, in db: Database) throws {
        guard let record = try AccountRecord.fetchOne(db, key: account), record.isEnabled,
              record.type == AccountType.local.rawValue else {
            throw AgentFailure("UNSUPPORTED", "This spike supports enabled local accounts only; synced accounts are blocked.")
        }
    }
    private func string(_ a: [String: AgentJSON], _ key: String) throws -> String {
        guard let value = a[key]?.stringValue, !value.isEmpty, value.count <= 512 else {
            throw AgentFailure("INVALID_ARGUMENT", "Missing or invalid \(key).")
        }
        return value
    }
    private func integer(_ a: [String: AgentJSON], _ key: String, default fallback: Int, max: Int) throws -> Int {
        guard let raw = a[key] else { return fallback }
        guard let n = raw.intValue, (1...max).contains(n) else { throw AgentFailure("INVALID_ARGUMENT", "Invalid \(key).") }
        return n
    }
    private func ownedEntry(_ id: String, account: String, in db: Database) throws -> (Entry, Feed) {
        guard let item = try provider.articleRepository.fetchItem(id: id, in: db), item.accountID == account,
              let feedRecord = try provider.feedRepository.fetchFeed(id: item.feedID, in: db),
              feedRecord.accountID == account, !feedRecord.isDeleted,
              let feed = try provider.feedRepository.fetchFeedModel(id: item.feedID, in: db),
              let entry = try provider.articleRepository.fetchEntry(id: id, in: db) else {
            throw AgentFailure("NOT_FOUND", "Article not found in the allowed account.")
        }
        return (entry, feed)
    }
    private func inMetadataScope(_ entry: Entry, account: String) -> Bool {
        !entry.isRead || (policy.allowStarred && entry.isStarred) || selections.values.contains {
            $0.account == account && $0.expires > clock() && $0.ids.contains(entry.id)
        }
    }
    private func metadataForID(_ id: String, account: String, requireScope: Bool) throws -> AgentArticleMetadata {
        try database.read { db in
            let (entry, feed) = try ownedEntry(id, account: account, in: db)
            if requireScope && !inMetadataScope(entry, account: account) {
                throw AgentFailure("UNAUTHORIZED", "Article is outside the granted metadata scope.")
            }
            let cached = try provider.cacheRepository.fetchCacheModel(itemID: id, in: db)
            // Never return raw URLs with userinfo, query tokens or fragments. Path-secret detection remains a production gap.
            let safeURL = Self.safeSourceURL(entry.url)
            let excerpt = String(entry.summary.plainText.unicodeScalars.prefix(500))
            return AgentArticleMetadata(id: id, account_id: account, feed_id: feed.id.uuidString,
                title: String(entry.title.plainText.unicodeScalars.prefix(500)),
                authors: entry.author.map { [String($0.plainText.unicodeScalars.prefix(200))] } ?? [],
                source_url: safeURL, source_url_unavailable_reason: safeURL == nil ? "missing_or_sensitive_url" : nil,
                feed_title: String(feed.title.plainText.unicodeScalars.prefix(500)), published_at: entry.publishedAt,
                read: entry.isRead, starred: entry.isStarred,
                state_token: "\(entry.updatedAt.timeIntervalSince1970.bitPattern)-\(entry.isRead)-\(entry.isStarred)",
                excerpt: excerpt, content_available: cached != nil || !entry.sourceText.isEmpty,
                content_source: "feed_summary", retrieved_at: clock(),
                truncated: entry.summary.plainText.unicodeScalars.count > 500, untrusted: true)
        }
    }
    private static func safeSourceURL(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.absoluteString.count <= 2048 else { return nil }
        return url.absoluteString
    }
    private func outputCost(_ metadata: AgentArticleMetadata) -> Int {
        metadata.excerpt.unicodeScalars.count + metadata.title.unicodeScalars.count
            + metadata.feed_title.unicodeScalars.count + metadata.authors.joined().unicodeScalars.count
    }
    private func charge(_ metadata: AgentArticleMetadata) throws { try charge(outputCost(metadata)) }
    private func charge(_ characters: Int) throws {
        guard characters <= remainingCharacters else { throw AgentFailure("CONTENT_BUDGET_EXCEEDED", "Session output budget exhausted; App authorization is required.") }
        remainingCharacters -= characters
    }

    private func offset(_ a: [String: AgentJSON]) throws -> Int {
        guard let value = a["cursor"] else { return 0 }
        guard let key = value.stringValue, let cursor = cursors[key], cursor.expires > clock() else {
            throw AgentFailure("CONFLICT", "Cursor expired or is unknown.")
        }
        var query = a; query.removeValue(forKey: "cursor")
        guard cursor.arguments == query else { throw AgentFailure("UNAUTHORIZED", "Cursor belongs to a different query.") }
        return cursor.offset
    }
    private func nextCursor(_ a: [String: AgentJSON], offset: Int) throws -> AgentJSON {
        guard cursors.count < 60 else { throw AgentFailure("RATE_LIMITED", "Too many pagination cursors.") }
        var query = a; query.removeValue(forKey: "cursor")
        let id = UUID().uuidString
        cursors[id] = Cursor(arguments: query, offset: offset, expires: clock().addingTimeInterval(900))
        return .string(id)
    }
    private func listFeeds(_ a: [String: AgentJSON]) throws -> AgentJSON {
        try authorize(try string(a, "account_id"))
        let limit = try integer(a, "limit", default: 20, max: 50)
        let start = try offset(a)
        let feeds = try provider.fetchFeeds().sorted { $0.id.uuidString < $1.id.uuidString }
        let counts = try provider.timelineQueryService.fetchSidebarCounts(accountID: provider.accountID, startOfDayTimestamp: 0)
        let page = Array(feeds.dropFirst(start).prefix(limit))
        let titles = page.map { String($0.title.plainText.unicodeScalars.prefix(500)) }
        try charge(titles.reduce(0) { $0 + $1.unicodeScalars.count })
        return .object(["feeds": .array(zip(page, titles).map { feed, title in .object([
            "id": .string(feed.id.uuidString), "account_id": .string(provider.accountID), "title": .string(title),
            "unread_count": .number(Double(counts.unreadByFeed[feed.id] ?? 0)), "untrusted": .bool(true)
        ]) }), "next_cursor": start + page.count < feeds.count ? try nextCursor(a, offset: start + page.count) : .null])
    }
    private func listArticles(_ a: [String: AgentJSON]) throws -> AgentJSON {
        let account = try string(a, "account_id")
        try authorize(account)
        let scope = try string(a, "scope")
        guard ["unread", "starred", "selection"].contains(scope),
              (scope == "selection") == (a["selection_id"] != nil) else {
            throw AgentFailure("INVALID_ARGUMENT", "Use unread, starred or an explicit selection.")
        }
        if scope == "starred" && !policy.allowStarred { throw AgentFailure("UNAUTHORIZED", "Starred scope is not granted.") }
        let ids = scope == "selection" ? try selection(a, account: account).ids : nil
        let limit = try integer(a, "limit", default: 20, max: 50)
        let query = a["query"]?.stringValue ?? ""
        guard query.count <= 200 else { throw AgentFailure("INVALID_ARGUMENT", "Query is too long.") }
        let since: Date?
        if let raw = a["since"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractionalDate = raw.stringValue.flatMap { formatter.date(from: $0) }
            formatter.formatOptions = [.withInternetDateTime]
            guard let text = raw.stringValue, let date = fractionalDate ?? formatter.date(from: text) else {
                throw AgentFailure("INVALID_ARGUMENT", "since must be an ISO8601 timestamp.")
            }
            since = date
        } else { since = nil }
        var position = try offset(a)
        // Reuse the existing bounded timeline projection. Cap work per call and continue scanning via cursor.
        let rows = try provider.timelineQueryService.fetchListItems(accountID: account,
            scope: scope == "unread" ? .unread : scope == "starred" ? .starred : .all, limit: 500, offset: position)
        var result: [AgentArticleMetadata] = []
        for row in rows {
            position += 1
            guard ids == nil || ids!.contains(row.id),
                  a["feed_id"] == nil || a["feed_id"]?.stringValue == row.feedID.uuidString,
                  since == nil || (row.publishedAt.map { $0 >= since! } ?? false) else { continue }
            // Search only the same bounded metadata exposed to the caller, never content_html/cache.
            let metadata = try metadataForID(row.id, account: account, requireScope: true)
            guard query.isEmpty || metadata.title.localizedCaseInsensitiveContains(query) || metadata.excerpt.localizedCaseInsensitiveContains(query) else { continue }
            result.append(metadata)
            if result.count == limit { break }
        }
        let hasMore = position < (try offset(a)) + rows.count || rows.count == 500
        let response: AgentJSON = .object(["articles": try .encoding(result), "next_cursor": hasMore ? try nextCursor(a, offset: position) : .null,
                        "pagination": .string("live_offset"), "snapshot_at": try .encoding(clock())])
        try charge(result.reduce(0) { $0 + outputCost($1) })
        return response
    }
    private func selection(_ a: [String: AgentJSON], account: String) throws -> Selection {
        let id = try string(a, "selection_id")
        guard let selection = selections[id], selection.account == account, selection.expires > clock() else {
            throw AgentFailure("UNAUTHORIZED", "Selection is missing or expired.")
        }
        return selection
    }
    private func content(_ a: [String: AgentJSON]) async throws -> AgentJSON {
        let account = try string(a, "account_id")
        let id = try string(a, "article_id")
        try authorize(account)
        guard try selection(a, account: account).ids.contains(id) else { throw AgentFailure("UNAUTHORIZED", "Article is not in the approved selection.") }
        let limit = try integer(a, "max_chars", default: 8000, max: 20_000)
        let (entry, feed, cache) = try database.read { db in
            let (entry, feed) = try ownedEntry(id, account: account, in: db)
            return (entry, feed, try provider.cacheRepository.fetchCacheModel(itemID: id, in: db))
        }
        let result = await engine.prepare(entry: entry, cached: cache, feed: feed, policy: .storedContent)
        try Task.checkCancellation()
        try authorize(account) // Revalidate after suspension: revoke/expiry must win over in-flight reads.
        guard try selection(a, account: account).ids.contains(id) else { throw AgentFailure("UNAUTHORIZED", "Selection was revoked.") }
        let metadata = try metadataForID(id, account: account, requireScope: true)
        let text = String(result.prepared.text.unicodeScalars.prefix(limit))
        try charge(outputCost(metadata) + text.unicodeScalars.count)
        return .object(["article": try .encoding(metadata), "text": .string(text), "untrusted": .bool(true),
            "content_source": .string(result.prepared.source == .cache ? "web_cache" : result.prepared.source == .fallback ? "unavailable" : "feed"),
            "truncated": .bool(result.prepared.text.unicodeScalars.count > limit), "remaining_characters": .number(Double(remainingCharacters))])
    }
    private func plan(_ a: [String: AgentJSON]) throws -> AgentJSON {
        let account = try string(a, "account_id")
        try authorize(account, write: true)
        guard let raw = a["article_ids"]?.arrayValue, (1...50).contains(raw.count),
              raw.allSatisfy({ $0.stringValue != nil }),
              let field = AgentStateField(rawValue: try string(a, "field")), let value = a["value"]?.boolValue else {
            throw AgentFailure("INVALID_ARGUMENT", "Use 1–50 article IDs and an explicit read/starred value.")
        }
        let ids = raw.compactMap(\.stringValue)
        guard Set(ids).count == ids.count, plans.count < 100 else { throw AgentFailure("INVALID_ARGUMENT", "Duplicate IDs or too many pending plans.") }
        let before = try database.read { db in
            try checkAccount(account, in: db)
            return try Dictionary(uniqueKeysWithValues: ids.map { id in
                let (entry, _) = try ownedEntry(id, account: account, in: db)
                guard inMetadataScope(entry, account: account) else { throw AgentFailure("UNAUTHORIZED", "Article is outside the granted scope.") }
                guard let state = try provider.stateRepository.fetchState(itemID: id, in: db) else { throw AgentFailure("CONFLICT", "Article state is missing.") }
                return (id, state)
            })
        }
        let dto = AgentStatePlan(plan_id: UUID().uuidString, account_id: account, article_ids: ids,
            field: field, value: value, expires_at: clock().addingTimeInterval(900),
            retention_notice: "Marking read or removing a star may make articles eligible for existing retention cleanup. This spike provides no undo.")
        plans[dto.plan_id] = PendingPlan(dto: dto, before: before)
        return try .encoding(dto)
    }
    private func apply(_ a: [String: AgentJSON]) throws -> AgentJSON {
        let id = try string(a, "plan_id"), approval = try string(a, "approval_id"), key = try string(a, "idempotency_key")
        guard key.count <= 128 else { throw AgentFailure("INVALID_ARGUMENT", "Idempotency key is too long.") }
        if let replay = receipts[key] {
            guard replay.plan == id, replay.approval == approval else { throw AgentFailure("CONFLICT", "Idempotency key was used for another command.") }
            guard let plan = plans[id] else { throw AgentFailure("CONFLICT", "Session plan is unavailable.") }
            try authorize(plan.dto.account_id, write: true)
            return try .encoding(replay.receipt)
        }
        guard var pending = plans[id], pending.dto.expires_at > clock() else { throw AgentFailure("CONFLICT", "Plan is unknown or expired.") }
        try authorize(pending.dto.account_id, write: true)
        guard pending.approval == approval else { throw AgentFailure("CONFIRMATION_REQUIRED", "Approve this exact plan in PaperRss first.") }
        guard pending.receipt == nil else { throw AgentFailure("CONFLICT", "Plan already committed; retry with the original idempotency key.") }
        guard receipts.count < 256 else { throw AgentFailure("RATE_LIMITED", "Session receipt capacity reached.") }
        try Task.checkCancellation()
        let dto = pending.dto
        let expected = pending.before
        // Validation + all writes in one existing writer transaction. No await between check and commit.
        try database.write { db in
            // The writer queue can be busy longer than the approval lifetime.
            try Task.checkCancellation()
            guard dto.expires_at > clock() else { throw AgentFailure("CONFLICT", "Plan expired while waiting for the writer transaction.") }
            try checkAccount(dto.account_id, in: db)
            for articleID in dto.article_ids {
                _ = try ownedEntry(articleID, account: dto.account_id, in: db)
                guard let current = try provider.stateRepository.fetchState(itemID: articleID, in: db), current == expected[articleID] else {
                    throw AgentFailure("CONFLICT", "Article state changed after preview; no articles were modified.")
                }
            }
            for articleID in dto.article_ids {
                switch dto.field {
                case .read: try provider.stateRepository.markRead(itemID: articleID, isRead: dto.value, in: db)
                case .starred: try provider.stateRepository.markStarred(itemID: articleID, isStarred: dto.value, in: db)
                }
            }
        }
        let receipt = AgentStateReceipt(operation_id: UUID().uuidString, applied_count: dto.article_ids.count,
                                        local_commit: "committed", sync: "not_applicable")
        pending.receipt = receipt
        plans[id] = pending
        receipts[key] = Replay(plan: id, approval: approval, receipt: receipt)
        return try .encoding(receipt)
    }
}
