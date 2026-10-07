import CryptoKit
import Foundation
import GRDB

enum ICloudLocalCopyError: Error, Sendable, Equatable {
    case invalidSelection, unavailableTarget, targetRequiresReview, stalePlan, scanLimitExceeded, copyInProgress, reviewRequired
}

/// Internal transaction backend. The Provider verifies current cloud recovery
/// and system identity; the UI obtains review of the exact selection/privacy
/// scope. It is never invoked by ordinary/background sync paths.
struct ICloudLocalCopyRepository: Sendable {
    enum ArticleSelection: Sendable, Equatable { case none, reliableArticles }
    struct Selection: Sendable, Equatable {
        let sourceAccountID: String
        let targetAccountID: String
        let feedIDs: Set<String>
        let folderIDs: Set<String>
        let articles: ArticleSelection
        /// Query/fragment addresses require individual review; userinfo is always
        /// excluded. This cannot identify every secret in paths, GUIDs or RSS text.
        let reviewedLinkIDs: Set<String>
    }
    struct Context: Sendable, Equatable {
        let userFingerprint: String
        let generation: String
    }
    struct Counts: Sendable, Equatable {
        let feeds, folders, relationships, articles, rssBodies, omittedRSSBodies: Int
        let skippedFeeds, skippedFolders, skippedArticles: Int
    }
    struct Plan: Sendable {
        let counts: Counts
        fileprivate let selection: Selection
        let context: Context
        fileprivate let database: LibraryDatabase
        fileprivate let digest: Data
        let preparedAt: Date
    }
    /// Separate from preparing/inspecting a plan. This is not durable cloud
    /// approval and must never be constructed by a background sync path.
    struct ReviewedPlan: Sendable {
        fileprivate let plan: Plan
        init(_ plan: Plan) { self.plan = plan }
    }
    let database: LibraryDatabase

    func prepare(selection: Selection, context: Context, catalog: ICloudCopySourceCatalog? = nil, at date: Date = Date()) async throws -> Plan {
        try Task.checkCancellation()
        let cancellation = CopyCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await database.readAsync { db in
                try cancellation.check()
                _ = try self.validate(selection, context: context, in: db)
                if let catalog { try self.validateCatalog(catalog, selection: selection, in: db) }
                let digest = try self.snapshotDigest(selection, cancellation: cancellation, in: db)
                let candidates = try self.candidates(selection, context: context, cancellation: cancellation, in: db)
                try cancellation.check()
                return Plan(counts: candidates.counts, selection: selection, context: context,
                            database: self.database,
                            digest: digest, preparedAt: date)
            }
        }, onCancel: { cancellation.cancel() })
    }

    /// Every inserted graph row, journal revision and content intent commits in
    /// one transaction. A stale/cancelled/failing copy leaves both libraries as
    /// they were. No transport, baseline reset, GUID inference or AI work occurs.
    func execute(_ reviewed: ReviewedPlan, at date: Date = Date()) async throws -> Counts {
        let plan = reviewed.plan
        let age = date.timeIntervalSince(plan.preparedAt)
        guard plan.database === database,
              (0..<600).contains(age) else {
            throw ICloudLocalCopyError.stalePlan
        }
        try Task.checkCancellation()
        // Include time spent queued/scanning/copying, independent of wall clock
        // adjustment. Expiration before commit rolls back the entire copy.
        let cancellation = CopyCancellation(deadline: ContinuousClock.now.advanced(by: .seconds(600 - age)))
        return try await withTaskCancellationHandler(operation: {
            try await database.writeAsync { db in
                try cancellation.check()
                _ = try self.validate(plan.selection, context: plan.context, in: db)
                guard try self.snapshotDigest(plan.selection, cancellation: cancellation, in: db) == plan.digest else {
                    throw ICloudLocalCopyError.stalePlan
                }
                let candidates = try self.candidates(plan.selection, context: plan.context, cancellation: cancellation, in: db)
                guard candidates.counts == plan.counts else { throw ICloudLocalCopyError.stalePlan }
                let now = date.timeIntervalSince1970
                var feedIDs: [String: String] = [:], folderIDs: [String: String] = [:]
                for source in candidates.folders {
                    try cancellation.check()
                    let id = UUID().uuidString
                    try FolderRecord(id: id, accountID: plan.selection.targetAccountID, name: source.name,
                                     sortOrder: source.sortOrder, updatedAt: now).insert(db)
                    folderIDs[source.id] = id
                }
                for source in candidates.feeds {
                    try cancellation.check()
                    let id = UUID().uuidString
                    // ETag, last fetch, external IDs and derived icons stay in source.
                    try FeedRecord(id: id, accountID: plan.selection.targetAccountID, title: source.title,
                                   siteURL: source.siteURL, feedURL: source.feedURL,
                                   updatedAt: now, sortOrder: source.sortOrder).insert(db)
                    feedIDs[source.id] = id
                }
                for link in candidates.relationships {
                    try cancellation.check()
                    try FeedFolderRecord(feedID: feedIDs[link.feedID]!, folderID: folderIDs[link.folderID]!).insert(db)
                }
                for row in candidates.articles {
                    try cancellation.check()
                    let source: String = row["source_item_id"], sourceFeed: String = row["feed_id"]
                    let feedID = feedIDs[sourceFeed]!
                    // Matches RSS merge/CloudKit restoration. insert (not upsert)
                    // makes even an unlikely local hash collision roll back safely.
                    let itemID = "\(feedID)|\(source)".stableDigest
                    try ItemRecord(id: itemID, accountID: plan.selection.targetAccountID, externalID: itemID,
                                   feedID: feedID, createdAt: row["created_at"], updatedAt: now,
                                   sourceItemID: source).insert(db)
                    let bodyEligible = Self.bodyEligible(row, syncUnread: candidates.syncUnread)
                    try ArticleRecord(itemID: itemID, title: row["title"], author: row["author"], url: row["url"],
                        publishedAt: row["published_at"], summary: bodyEligible ? ((row["summary"] as String?) ?? "") : "",
                        contentHTML: bodyEligible ? row["content_html"] : nil, contentUpdatedAt: now).insert(db)
                    try ArticleStateRecord(itemID: itemID, isRead: row["is_read"], isStarred: row["is_starred"],
                                           dateArrived: row["date_arrived"], updatedAt: now).insert(db)
                }
                try cancellation.check()
                return candidates.counts
            }
        }, onCancel: { cancellation.cancel() })
    }

    private struct Candidates {
        let feeds: [FeedRecord], folders: [FolderRecord], relationships: [FeedFolderRecord]
        let articles: [Row]
        let syncUnread: Bool
        let counts: Counts
    }

    private func validate(_ selection: Selection, context: Context, in db: Database) throws -> Bool {
        guard !selection.feedIDs.isEmpty || !selection.folderIDs.isEmpty,
              selection.feedIDs.count + selection.folderIDs.count <= 500,
              selection.reviewedLinkIDs.isSubset(of: selection.feedIDs),
              selection.sourceAccountID != selection.targetAccountID,
              try Self.copySource(accountID: selection.sourceAccountID, in: db) != nil else { throw ICloudLocalCopyError.invalidSelection }
        guard let target = try AccountRecord.fetchOne(db, key: selection.targetAccountID),
              target.type == AccountType.iCloud.rawValue, target.isEnabled, !target.isArchived,
              let scope = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?",
                                          arguments: [target.id]),
              scope["capture_enabled"] as Bool, !(scope["suppress_capture"] as Bool),
              scope["pause_reason"] as String? == nil, scope["cloud_reset_operation"] as Data? == nil,
              !context.userFingerprint.isEmpty,
              scope["user_fingerprint"] as String? == context.userFingerprint,
              scope["cloud_generation"] as String? == context.generation,
              scope["initialized_zones"] as Int == 3,
              (try? ICloudCloudRoot(generation: context.generation, phase: .ready).validate()) != nil
        else { throw ICloudLocalCopyError.unavailableTarget }
        return scope["sync_unread_content"]
    }

    private func candidates(_ selection: Selection, context: Context, cancellation: CopyCancellation, in db: Database) throws -> Candidates {
        let syncUnread = try validate(selection, context: context, in: db)
        let allFeeds = try FeedRecord.filter(Column("account_id") == selection.sourceAccountID && Column("is_deleted") == false)
            .order(Column("id")).fetchAll(db)
        let allFolders = try FolderRecord.filter(Column("account_id") == selection.sourceAccountID && Column("is_deleted") == false)
            .order(Column("id")).fetchAll(db)
        guard selection.feedIDs.isSubset(of: Set(allFeeds.map(\.id))),
              selection.folderIDs.isSubset(of: Set(allFolders.map(\.id))) else {
            throw ICloudLocalCopyError.invalidSelection
        }
        let links = Dictionary(uniqueKeysWithValues: allFeeds.map { ($0.id, ICloudSyncIdentity.FeedLinkReview($0.feedURL)) })
        let feedGroups = Dictionary(grouping: links.values.compactMap(\.recordName), by: { $0 })
        let folderGroups = Dictionary(grouping: allFolders.map(\.name), by: { $0 })
        let occupied = try targetNames(accountID: selection.targetAccountID, cancellation: cancellation, in: db)
        let feeds = allFeeds.filter { feed in
            let link = links[feed.id]!
            let site = feed.siteURL.map(ICloudSyncIdentity.FeedLinkReview.init)
            guard selection.feedIDs.contains(feed.id), let identity = link.recordName,
                  feedGroups[identity]?.count == 1, !link.hasCredentials, site?.hasCredentials != true,
                  site?.isUnverifiable != true,
                  !occupied.feeds.contains(identity) else { return false }
            return (!link.needsReview && site?.needsReview != true) || selection.reviewedLinkIDs.contains(feed.id)
        }
        let folders = allFolders.filter {
            selection.folderIDs.contains($0.id) && folderGroups[$0.name]?.count == 1 && !occupied.folders.contains($0.name)
        }
        let feedIDs = Set(feeds.map(\.id)), folderIDs = Set(folders.map(\.id))
        let relationships = try FeedFolderRecord.filter(feedIDs.contains(Column("feed_id")) && folderIDs.contains(Column("folder_id")))
            .order(Column("feed_id"), Column("folder_id")).fetchAll(db)
        var articles: [Row] = [], totalArticles = 0
        if selection.articles == .reliableArticles && !selection.feedIDs.isEmpty {
            let rows = try articleRows(selection, cancellation: cancellation, in: db)
            totalArticles = rows.count
            var identities: [String: String] = [:], groups: [String: Int] = [:]
            for row in rows {
                try cancellation.check()
                guard let link = links[row["feed_id"] as String], link.recordName != nil, let url = link.url,
                      let identity = try ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: row["source_item_id"])
                else { continue }
                identities[row["id"]] = identity
                groups[identity, default: 0] += 1
            }
            articles = rows.filter { row in
                guard feedIDs.contains(row["feed_id"]), let identity = identities[row["id"]], groups[identity] == 1,
                      row["title"] as String? != nil, row["is_read"] as Bool? != nil, row["is_starred"] as Bool? != nil
                else { return false }
                return true
            }
        }
        return .init(feeds: feeds, folders: folders, relationships: relationships, articles: articles, syncUnread: syncUnread,
            counts: .init(feeds: feeds.count, folders: folders.count, relationships: relationships.count,
                articles: articles.count, rssBodies: articles.filter { Self.bodyEligible($0, syncUnread: syncUnread) &&
                    (($0["content_html"] as String?)?.isEmpty == false || ($0["summary"] as String?)?.isEmpty == false) }.count,
                omittedRSSBodies: articles.filter { $0["rss_body_omitted"] as Bool }.count,
                skippedFeeds: selection.feedIDs.count - feeds.count, skippedFolders: selection.folderIDs.count - folders.count,
                skippedArticles: totalArticles - articles.count))
    }

    private static func bodyEligible(_ row: Row, syncUnread: Bool) -> Bool {
        ICloudArticleSyncPolicy.shouldSyncContent(isRead: row["is_read"], isStarred: row["is_starred"], syncUnreadContent: syncUnread)
    }

    private func articleRows(_ selection: Selection, cancellation: CopyCancellation, in db: Database) throws -> [Row] {
        let ids = selection.feedIDs.sorted()
        guard !ids.isEmpty else { return [] }
        let eligible = "(st.is_starred = 1 OR (st.is_read = 0 AND (SELECT sync_unread_content FROM icloud_sync_scope WHERE account_id = ?) = 1))"
        let boundedBody = "(length(CAST(COALESCE(ar.summary, '') AS BLOB)) + length(CAST(COALESCE(ar.content_html, '') AS BLOB)) <= 8388608)"
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT i.id, i.feed_id, i.source_item_id, i.created_at, i.updated_at,
                ar.title, ar.author, ar.url, ar.published_at,
                CASE WHEN \(eligible) AND \(boundedBody) THEN ar.summary END AS summary,
                CASE WHEN \(eligible) AND \(boundedBody) THEN ar.content_html END AS content_html,
                (\(eligible) AND NOT \(boundedBody)) AS rss_body_omitted,
                st.is_read, st.is_starred, st.date_arrived, st.updated_at AS state_updated_at
            FROM items i JOIN feeds f ON f.id = i.feed_id AND f.account_id = i.account_id AND f.is_deleted = 0
            LEFT JOIN articles ar ON ar.item_id = i.id LEFT JOIN article_states st ON st.item_id = i.id
            WHERE i.account_id = ? AND i.feed_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            ORDER BY i.id LIMIT 50001;
            """, arguments: StatementArguments(Array(repeating: selection.targetAccountID, count: 3) + [selection.sourceAccountID] + ids))
        var rows: [Row] = [], bytes = 0
        while let row = try cursor.next() {
            try cancellation.check()
            for (_, value) in row {
                if case .string(let text) = value.storage { bytes += text.utf8.count }
            }
            guard rows.count < 50000, bytes <= 128 * 1024 * 1024 else { throw ICloudLocalCopyError.scanLimitExceeded }
            // Cursor rows borrow a reused statement buffer; retain an owned row
            // before advancing, otherwise all candidates become the last row.
            rows.append(row.copy())
        }
        return rows
    }

    /// Any observed target identity is protected, including orphan state caches,
    /// pending tombstones, physically purged mappings and deleted folder names.
    private func targetNames(accountID: String, cancellation: CopyCancellation, in db: Database) throws -> (feeds: Set<String>, folders: Set<String>) {
        var feeds: Set<String> = [], folders: Set<String> = []
        for row in try Row.fetchAll(db, sql: "SELECT feed_url FROM feeds WHERE account_id = ?", arguments: [accountID]) {
            guard let name = ICloudSyncIdentity.FeedLinkReview(row["feed_url"]).recordName else {
                throw ICloudLocalCopyError.targetRequiresReview
            }
            feeds.insert(name)
        }
        folders.formUnion(try String.fetchAll(db, sql: "SELECT name FROM folders WHERE account_id = ?", arguments: [accountID]))
        feeds.formUnion(try String.fetchAll(db, sql: "SELECT record_name FROM icloud_record_mappings WHERE account_id = ? AND kind = 'feed'",
                                          arguments: [accountID]))
        let cache = try Row.fetchCursor(db, sql: """
            SELECT zone, record_name, envelope_json FROM icloud_records WHERE account_id = ?
              AND (zone = ? OR (zone = ? AND (record_name LIKE 'read-v1:%' OR record_name LIKE 'starred-v1:%')));
            """, arguments: [accountID, ICloudRecordZone.library.rawValue, ICloudRecordZone.articles.rawValue])
        while let row = try cache.next() {
            try cancellation.check()
            let text: String = row["envelope_json"]
            guard let record = try? JSONDecoder().decode(ICloudRecordEnvelope.self, from: Data(text.utf8)),
                  (try? record.validate()) != nil, record.recordName == row["record_name"] as String,
                  record.zone.rawValue == row["zone"] as String else { throw ICloudLocalCopyError.targetRequiresReview }
            if let url = record.feedURL, let name = ICloudSyncIdentity.FeedLinkReview(url).recordName { feeds.insert(name) }
            if let name = record.feedRecordName { feeds.insert(name) }
            if case .text(let name) = record.fields["name"]?.value { folders.insert(name) }
        }
        let pending = try Row.fetchCursor(db, sql: """
            SELECT kind, json_extract(payload_json, '$.feed_url') AS url, json_extract(payload_json, '$.name') AS name
            FROM icloud_sync_changes WHERE account_id = ? AND is_pending = 1;
            """, arguments: [accountID])
        while let row = try pending.next() {
            try cancellation.check()
            let kind: String = row["kind"]
            if kind == "feed" || kind == "read" || kind == "starred" {
                guard let url: String = row["url"], let name = ICloudSyncIdentity.FeedLinkReview(url).recordName else {
                    throw ICloudLocalCopyError.targetRequiresReview
                }
                feeds.insert(name)
            } else if kind == "folder" {
                guard let name: String = row["name"] else { throw ICloudLocalCopyError.targetRequiresReview }
                folders.insert(name)
            }
        }
        return (feeds, folders)
    }

    /// Stream a length-framed digest of explicit fields. Neither the digest nor
    /// original values are logged/exported. No AI/config/derived cache is read.
    private func snapshotDigest(_ selection: Selection, cancellation: CopyCancellation, in db: Database) throws -> Data {
        var hash = SHA256(), rowCount = 0, byteCount = 0
        func append(_ bytes: Data) throws {
            byteCount += bytes.count
            guard byteCount <= 128 * 1024 * 1024 else { throw ICloudLocalCopyError.scanLimitExceeded }
            hash.update(data: Data("\(bytes.count):".utf8)); hash.update(data: bytes)
        }
        func rows(_ sql: String, _ arguments: StatementArguments) throws {
            try append(Data(sql.utf8))
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try cursor.next() {
                try cancellation.check()
                rowCount += 1
                guard rowCount <= 200000 else { throw ICloudLocalCopyError.scanLimitExceeded }
                try append(Data("row:\(row.count)".utf8))
                for (_, value) in row {
                    switch value.storage {
                    case .null: try append(Data("n".utf8))
                    case .int64(let v): try append(Data("i\(v)".utf8))
                    case .double(let v): try append(Data("d\(v.bitPattern)".utf8))
                    case .string(let v): try append(Data("s".utf8)); try append(Data(v.utf8))
                    case .blob(let v): try append(Data("b".utf8)); try append(v)
                    }
                }
            }
        }
        let accounts: StatementArguments = [selection.sourceAccountID, selection.targetAccountID]
        try rows("SELECT id, type, is_enabled, is_archived, updated_at FROM accounts WHERE id IN (?, ?) ORDER BY id", accounts)
        try rows("SELECT id, account_id, title, feed_url, site_url, sort_order, is_deleted, updated_at FROM feeds WHERE account_id IN (?, ?) ORDER BY id", accounts)
        try rows("SELECT id, account_id, name, sort_order, is_deleted, updated_at FROM folders WHERE account_id IN (?, ?) ORDER BY id", accounts)
        try rows("SELECT ff.feed_id, ff.folder_id FROM feed_folders ff JOIN feeds f ON f.id = ff.feed_id WHERE f.account_id IN (?, ?) ORDER BY ff.feed_id, ff.folder_id", accounts)
        let target: StatementArguments = [selection.targetAccountID]
        try rows("SELECT capture_enabled, suppress_capture, user_fingerprint, cloud_generation, cloud_protocol_version, pause_reason, cloud_reset_operation, initialized_zones, logical_clock, device_id, sync_unread_content, settings_revision FROM icloud_sync_scope WHERE account_id = ?", target)
        try rows("SELECT kind, entity_id, record_name FROM icloud_record_mappings WHERE account_id = ? ORDER BY kind, entity_id", target)
        try rows("SELECT kind, entity_id, revision, payload_json, is_tombstone, is_pending, field_versions_json FROM icloud_sync_changes WHERE account_id = ? ORDER BY kind, entity_id", target)
        try rows("SELECT zone, record_name, envelope_json, system_fields, origins_json, is_pending, needs_apply FROM icloud_records WHERE account_id = ? AND (zone = 'PaperRssLibrary-v1' OR record_name LIKE 'read-v1:%' OR record_name LIKE 'starred-v1:%' OR record_name LIKE 'retention-v1:%' OR record_name = 'retention-policy-v1:articles') ORDER BY zone, record_name", target)
        if selection.articles == .reliableArticles {
            for row in try articleRows(selection, cancellation: cancellation, in: db) {
                try cancellation.check()
                // Same fixed column order as the source query above.
                for (_, value) in row {
                    switch value.storage {
                    case .null: try append(Data("n".utf8))
                    case .int64(let v): try append(Data("i\(v)".utf8))
                    case .double(let v): try append(Data("d\(v.bitPattern)".utf8))
                    case .string(let v): try append(Data("s".utf8)); try append(Data(v.utf8))
                    case .blob(let v): try append(Data("b".utf8)); try append(v)
                    }
                }
            }
        }
        return Data(hash.finalize())
    }
}

/// GRDB executes synchronous closures on its queues. Task.isCancelled there
/// does not reliably describe the awaiting caller, so relay cancellation.
private final class CopyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: ContinuousClock.Instant?
    init(deadline: ContinuousClock.Instant? = nil) { self.deadline = deadline }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
        if let deadline, ContinuousClock.now >= deadline { throw ICloudLocalCopyError.stalePlan }
    }
}
