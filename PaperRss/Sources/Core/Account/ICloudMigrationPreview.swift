import Foundation
import GRDB

/// Local observations only. This is not copy approval or evidence that cloud
/// recovery is complete. No source/target identities, URLs or article text escape.
public struct ICloudMigrationPreview: Sendable, Equatable {
    public enum TargetStatus: Sendable, Equatable {
        case notCreated, disabled, requiresReview, notInitialized, locallyBound
    }
    public let scannedAt: Date
    public let sourceIsEnabled: Bool
    public let feeds: Int
    public let folders: Int
    public let folderRelationships: Int
    public let feedsInMultipleFolders: Int
    public let duplicateFolderNameGroups: Int
    public let duplicateFeedIdentityGroups: Int
    public let duplicateArticleIdentityGroups: Int
    public let articles: Int
    public let readArticles: Int
    public let starredArticles: Int
    public let missingIdentities: Int
    public let starredMissingIdentities: Int
    public let missingReadingStates: Int
    public let articlesWithStableUniqueIdentity: Int
    public let starredWithStableUniqueIdentity: Int
    public let starredWithRSSBodyAndStableIdentity: Int
    public let flaggedFeedLinks: Int
    public let feedLinksWithCredentials: Int
    public let feedLinksWithQuery: Int
    public let feedLinksWithFragment: Int
    public let unverifiableFeedLinks: Int
    public let targetStatus: TargetStatus
    public let targetFeeds: Int
    public let feedsAlreadyObservedInTarget: Int
    public let feedsWithTargetDeletion: Int
    public let folderNamesAlreadyInTarget: Int
    public let articlesAlreadyObservedInTarget: Int
    public let observedReadDisagreements: Int
    public let observedStarDisagreements: Int
    public let targetEntriesRequiringReview: Int
}

enum ICloudMigrationPreviewError: Error, Sendable {
    case unavailableSource
}

/// One read transaction over the source and the sole existing iCloud account.
/// It never activates capture, prepares records, compresses bodies or contacts
/// CloudKit. Disabled/paused accounts remain available for local inspection.
struct ICloudMigrationPreviewRepository: Sendable {
    let database: LibraryDatabase

    func preview(sourceAccountID: String) async throws -> ICloudMigrationPreview {
        try await database.readAsync { db in
            guard let source = try ICloudLocalCopyRepository.copySource(accountID: sourceAccountID, in: db)
            else { throw ICloudMigrationPreviewError.unavailableSource }
            let feeds = try FeedRecord.filter(Column("account_id") == sourceAccountID && Column("is_deleted") == false).fetchAll(db)
            let folders = try FolderRecord.filter(Column("account_id") == sourceAccountID && Column("is_deleted") == false).fetchAll(db)
            let links = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, ICloudSyncIdentity.FeedLinkReview($0.feedURL)) })
            let feedGroups = Dictionary(grouping: links.values.compactMap(\.recordName), by: { $0 })
            let duplicateFeeds = Set(feedGroups.filter { $0.value.count > 1 }.keys)
            let folderGroups = Dictionary(grouping: folders.map(\.name), by: { $0 })
            let memberships = try Row.fetchAll(db, sql: """
                SELECT ff.feed_id, COUNT(*) AS relationships FROM feed_folders ff
                JOIN feeds f ON f.id = ff.feed_id AND f.account_id = ? AND f.is_deleted = 0
                JOIN folders d ON d.id = ff.folder_id AND d.account_id = f.account_id AND d.is_deleted = 0
                GROUP BY ff.feed_id;
                """, arguments: [sourceAccountID])
            let sourceRows = try Self.articleRows(accountID: sourceAccountID, in: db)
            var items: [SourceArticle] = []
            var missing = 0, starredMissing = 0, missingStates = 0, read = 0, starred = 0
            for row in sourceRows {
                let isRead: Bool? = row["is_read"], isStarred: Bool? = row["is_starred"]
                if isRead == true { read += 1 }
                if isStarred == true { starred += 1 }
                if isRead == nil || isStarred == nil { missingStates += 1 }
                let guid: String? = row["source_item_id"]
                if !ICloudSyncIdentity.hasSourceItemIdentity(guid) {
                    missing += 1
                    if isStarred == true { starredMissing += 1 }
                }
                let link = links[row["feed_id"] as String]!
                let identity = link.url.flatMap { try? ICloudSyncIdentity.articleRecordName(feedURL: $0, sourceItemID: guid) }
                items.append(.init(identity: identity, feedIdentity: link.recordName, read: isRead,
                    starred: isStarred, hasRSSBody: row["has_rss_body"]))
            }
            let articleGroups = Dictionary(grouping: items.compactMap(\.identity), by: { $0 })
            let duplicateArticles = Set(articleGroups.filter { $0.value.count > 1 }.keys)
            let identified = items.filter {
                guard let identity = $0.identity, let feed = $0.feedIdentity else { return false }
                return !duplicateArticles.contains(identity) && !duplicateFeeds.contains(feed) && $0.read != nil && $0.starred != nil
            }
            let target = try AccountRecord.filter(Column("type") == AccountType.iCloud.rawValue && Column("is_archived") == false).fetchOne(db)
            let observations = try target.map { try Self.targetObservations(account: $0, in: db) } ?? .init()
            let sourceFeedNames = Set(links.values.compactMap(\.recordName))
            let sourceFolderNames = Set(folders.map(\.name))
            var overlapping = 0, readDisagreements = 0, starDisagreements = 0
            for item in identified {
                if let existing = observations.articles[item.identity!] {
                    overlapping += 1
                    if let value = item.read, existing.read.contains(!value) { readDisagreements += 1 }
                    if let value = item.starred, existing.starred.contains(!value) { starDisagreements += 1 }
                }
            }
            return .init(scannedAt: Date(), sourceIsEnabled: source.isEnabled,
                feeds: feeds.count, folders: folders.count,
                folderRelationships: memberships.reduce(0) { $0 + ($1["relationships"] as Int) },
                feedsInMultipleFolders: memberships.filter { ($0["relationships"] as Int) > 1 }.count,
                duplicateFolderNameGroups: folderGroups.filter { $0.value.count > 1 }.count,
                duplicateFeedIdentityGroups: duplicateFeeds.count, duplicateArticleIdentityGroups: duplicateArticles.count,
                articles: sourceRows.count, readArticles: read, starredArticles: starred,
                missingIdentities: missing, starredMissingIdentities: starredMissing, missingReadingStates: missingStates,
                articlesWithStableUniqueIdentity: identified.count,
                starredWithStableUniqueIdentity: identified.filter { $0.starred == true }.count,
                starredWithRSSBodyAndStableIdentity: identified.filter { $0.starred == true && $0.hasRSSBody }.count,
                flaggedFeedLinks: links.values.filter(\.needsReview).count,
                feedLinksWithCredentials: links.values.filter(\.hasCredentials).count,
                feedLinksWithQuery: links.values.filter(\.hasQuery).count,
                feedLinksWithFragment: links.values.filter(\.hasFragment).count,
                unverifiableFeedLinks: links.values.filter(\.isUnverifiable).count,
                targetStatus: observations.status, targetFeeds: observations.liveFeedCount,
                feedsAlreadyObservedInTarget: sourceFeedNames.intersection(observations.feeds).count,
                feedsWithTargetDeletion: sourceFeedNames.intersection(observations.deletedFeeds).count,
                folderNamesAlreadyInTarget: sourceFolderNames.intersection(observations.folderNames).count,
                articlesAlreadyObservedInTarget: overlapping,
                observedReadDisagreements: readDisagreements, observedStarDisagreements: starDisagreements,
                targetEntriesRequiringReview: observations.unverifiable)
        }
    }

    private struct SourceArticle {
        let identity: String?
        let feedIdentity: String?
        let read: Bool?
        let starred: Bool?
        let hasRSSBody: Bool
    }
    private struct StateObservation {
        var read: Set<Bool> = []
        var starred: Set<Bool> = []
    }
    private struct TargetObservations {
        var status = ICloudMigrationPreview.TargetStatus.notCreated
        var liveFeedCount = 0
        var feeds: Set<String> = []
        var deletedFeeds: Set<String> = []
        var folderNames: Set<String> = []
        var articles: [String: StateObservation] = [:]
        var unverifiable = 0
    }

    private static func articleRows(accountID: String, in db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: """
            SELECT i.feed_id, i.source_item_id, st.is_read, st.is_starred,
                (length(trim(COALESCE(a.content_html, ''))) > 0 OR length(trim(COALESCE(a.summary, ''))) > 0) AS has_rss_body,
                f.feed_url
            FROM items i JOIN feeds f ON f.id = i.feed_id AND f.account_id = i.account_id
            LEFT JOIN article_states st ON st.item_id = i.id LEFT JOIN articles a ON a.item_id = i.id
            WHERE i.account_id = ? AND f.is_deleted = 0;
            """, arguments: [accountID])
    }

    private static func targetObservations(account: AccountRecord, in db: Database) throws -> TargetObservations {
        var result = TargetObservations()
        if !account.isEnabled { result.status = .disabled }
        else if let scope = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [account.id]) {
            let reason: String? = scope["pause_reason"], operation: Data? = scope["cloud_reset_operation"]
            let generation: String? = scope["cloud_generation"], fingerprint: String? = scope["user_fingerprint"]
            if reason != nil || operation != nil { result.status = .requiresReview }
            else if scope["capture_enabled"] as Bool, let generation, let uuid = UUID(uuidString: generation),
                    uuid.uuidString == generation, fingerprint?.isEmpty == false { result.status = .locallyBound }
            else { result.status = .notInitialized }
        } else { result.status = .notInitialized }
        for feed in try FeedRecord.filter(Column("account_id") == account.id).fetchAll(db) {
            if !feed.isDeleted { result.liveFeedCount += 1 }
            guard let name = ICloudSyncIdentity.FeedLinkReview(feed.feedURL).recordName else { result.unverifiable += 1; continue }
            result.feeds.insert(name)
            if feed.isDeleted { result.deletedFeeds.insert(name) }
        }
        result.folderNames = Set(try FolderRecord.filter(Column("account_id") == account.id && Column("is_deleted") == false).fetchAll(db).map(\.name))
        // Feed/read/starred metadata only. Content, settings, assets and AI are
        // deliberately absent from these queries.
        let cached = try Row.fetchCursor(db, sql: """
            SELECT record_name, envelope_json FROM icloud_records WHERE account_id = ?
              AND ((zone = ? AND record_name LIKE 'feed-v1:%')
                OR (zone = ? AND (record_name LIKE 'read-v1:%' OR record_name LIKE 'starred-v1:%')));
            """, arguments: [account.id, ICloudRecordZone.library.rawValue, ICloudRecordZone.articles.rawValue])
        while let row = try cached.next() {
            let text: String = row["envelope_json"]
            guard let value = try? JSONDecoder().decode(ICloudRecordEnvelope.self, from: Data(text.utf8)),
                  (try? value.validate()) != nil, value.recordName == row["record_name"] as String else {
                result.unverifiable += 1; continue
            }
            switch value.kind {
            case .feed:
                result.feeds.insert(value.recordName)
                if value.fields["deleted"]?.value == .flag(true) { result.deletedFeeds.insert(value.recordName) }
            case .read, .starred:
                let article = "article-v1:" + value.recordName.dropFirst((value.kind.rawValue + "-v1:").count)
                if case .flag(let flag) = value.fields["value"]?.value {
                    observe(flag, kind: value.kind, article: article, in: &result)
                }
            default: result.unverifiable += 1
            }
        }
        for row in try articleRows(accountID: account.id, in: db) {
            guard let url = ICloudSyncIdentity.FeedLinkReview(row["feed_url"]).url,
                  let article = try? ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: row["source_item_id"]),
                  let read: Bool = row["is_read"], let starred: Bool = row["is_starred"] else {
                result.unverifiable += 1; continue
            }
            observe(read, kind: .read, article: article, in: &result)
            observe(starred, kind: .starred, article: article, in: &result)
        }
        let pending = try Row.fetchCursor(db, sql: """
            SELECT kind, is_tombstone, json_extract(payload_json, '$.feed_url') AS feed_url,
                json_extract(payload_json, '$.source_item_id') AS source_item_id,
                json_extract(payload_json, '$.value') AS value, json_type(payload_json, '$.value') AS value_type
            FROM icloud_sync_changes WHERE account_id = ? AND is_pending = 1 AND kind IN ('feed', 'read', 'starred');
            """, arguments: [account.id])
        while let row = try pending.next() {
            guard let raw: String = row["feed_url"] else { result.unverifiable += 1; continue }
            let link = ICloudSyncIdentity.FeedLinkReview(raw)
            guard let name = link.recordName else { result.unverifiable += 1; continue }
            let kind: String = row["kind"]
            if kind == "feed" {
                result.feeds.insert(name)
                if row["is_tombstone"] as Bool { result.deletedFeeds.insert(name) }
            } else {
                let type: String? = row["value_type"]
                let flag: Int64? = row["value"]
                guard (type == "true" || type == "false" || (type == "integer" && (flag == 0 || flag == 1))),
                      let flag, let url = link.url,
                      let article = try? ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: row["source_item_id"]) else {
                    result.unverifiable += 1; continue
                }
                observe(flag == 1, kind: kind == "read" ? .read : .starred, article: article, in: &result)
            }
        }
        return result
    }

    private static func observe(_ value: Bool, kind: ICloudRecordKind, article: String, in target: inout TargetObservations) {
        var state = target.articles[article] ?? .init()
        if kind == .read { state.read.insert(value) }
        else { state.starred.insert(value) }
        target.articles[article] = state
    }
}
