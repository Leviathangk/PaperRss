import Foundation
import GRDB

/// Local review only: no CloudKit calls, activation, baseline capture or writes.
/// The public value deliberately contains no URLs, identity or approval fields.
public struct ICloudRecoveryReview: Sendable, Equatable {
    public enum Pause: Sendable, Equatable {
        case none, accountChanged, rootMissing, rootChanged, resetting, resetReview
        case zonesUnavailable, legacyData, incompatibleData, needsReview

        public var message: String? {
            switch self {
            case .none: return nil
            case .accountChanged, .zonesUnavailable, .needsReview:
                return ICloudSyncFailure.message(for: ICloudRecordError.recoveryRequired)
            case .rootMissing: return ICloudSyncFailure.message(for: ICloudRootError.rootMissing)
            case .rootChanged, .resetReview: return ICloudSyncFailure.message(for: ICloudRootError.generationChanged)
            case .resetting: return ICloudSyncFailure.message(for: ICloudRootError.resetInProgress)
            case .legacyData: return ICloudSyncFailure.message(for: ICloudRootError.legacyCloudRequiresReview)
            case .incompatibleData: return ICloudSyncFailure.message(for: ICloudRootError.malformedRoot)
            }
        }
    }

    public enum ResetProgress: Sendable, Equatable {
        case none, prepared, rootPublished, libraryCreated, articlesCreated
        case libraryDeleted, articlesDeleted, previousRetained, cloudReady, needsReview
    }

    public let isEnabled: Bool
    public let hasSyncScope: Bool
    public let captureEnabled: Bool
    public let pause: Pause
    public let resetProgress: ResetProgress
    public let feeds: Int
    public let folders: Int
    public let articles: Int
    public let readArticles: Int
    public let starredArticles: Int
    public let missingIdentities: Int
    public let starredMissingIdentities: Int
    public let articlesWithRSSBody: Int
    public let flaggedFeedLinks: Int
    public let feedLinksWithCredentials: Int
    public let feedLinksWithQuery: Int
    public let feedLinksWithFragment: Int
    public let unverifiableFeedLinks: Int
}

extension ICloudRecordRepository {
    func recoveryReview() async throws -> ICloudRecoveryReview {
        try await database.readAsync { db in
            guard let scope = try Row.fetchOne(db, sql: """
                SELECT a.is_enabled, s.account_id AS scope_account_id, s.capture_enabled,
                    s.pause_reason, s.cloud_generation, s.cloud_protocol_version, s.user_fingerprint, s.cloud_reset_operation
                FROM accounts a LEFT JOIN icloud_sync_scope s ON s.account_id = a.id
                WHERE a.id = ? AND a.type = ?;
                """, arguments: [self.accountID, AccountType.iCloud.rawValue]) else {
                throw ICloudRecordError.unavailableScope
            }
            let urls = try String.fetchAll(db, sql: """
                SELECT feed_url FROM feeds WHERE account_id = ? AND is_deleted = 0;
                """, arguments: [self.accountID])
            let folders = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM folders WHERE account_id = ? AND is_deleted = 0;
                """, arguments: [self.accountID]) ?? 0
            let counts = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS articles,
                    COUNT(CASE WHEN st.is_read = 1 THEN 1 END) AS read_articles,
                    COUNT(CASE WHEN st.is_starred = 1 THEN 1 END) AS starred_articles,
                    COUNT(CASE WHEN length(trim(COALESCE(a.content_html, ''))) > 0
                        OR length(trim(COALESCE(a.summary, ''))) > 0 THEN 1 END) AS rss_bodies
                FROM items i JOIN feeds f ON f.id = i.feed_id AND f.account_id = i.account_id
                LEFT JOIN article_states st ON st.item_id = i.id
                LEFT JOIN articles a ON a.item_id = i.id
                WHERE i.account_id = ? AND f.is_deleted = 0;
                """, arguments: [self.accountID])!
            let identities = try Row.fetchCursor(db, sql: """
                SELECT i.source_item_id, COALESCE(st.is_starred, 0) AS is_starred
                FROM items i JOIN feeds f ON f.id = i.feed_id AND f.account_id = i.account_id
                LEFT JOIN article_states st ON st.item_id = i.id
                WHERE i.account_id = ? AND f.is_deleted = 0;
                """, arguments: [self.accountID])
            var missing = 0, starredMissing = 0
            while let row = try identities.next() {
                if !ICloudSyncIdentity.hasSourceItemIdentity(row["source_item_id"]) {
                    missing += 1
                    if row["is_starred"] as Bool { starredMissing += 1 }
                }
            }
            var flagged = 0, credentials = 0, queries = 0, fragments = 0, invalid = 0
            for raw in urls {
                let link = ICloudSyncIdentity.FeedLinkReview(raw)
                if link.hasCredentials { credentials += 1 }
                if link.hasQuery { queries += 1 }
                if link.hasFragment { fragments += 1 }
                if link.isUnverifiable { invalid += 1 }
                if link.needsReview { flagged += 1 }
            }
            let rawPause: String? = scope["pause_reason"]
            let pause: ICloudRecoveryReview.Pause
            switch rawPause {
            case nil: pause = .none
            case "accountChanged": pause = .accountChanged
            case "cloudRootMissing": pause = .rootMissing
            case "cloudGenerationChanged": pause = .rootChanged
            case "cloudResetInProgress", "cloudResetRequested": pause = .resetting
            case "cloudResetReview": pause = .resetReview
            case "zoneDeleted", "zoneMissing", "structureDeleted": pause = .zonesUnavailable
            case "legacyCloudRoot": pause = .legacyData
            case "invalidCloudRoot": pause = .incompatibleData
            default: pause = .needsReview
            }
            var progress = ICloudRecoveryReview.ResetProgress.none
            if let data: Data = scope["cloud_reset_operation"] {
                if let operation = try? ICloudCloudResetOperation.decode(data),
                   scope["cloud_generation"] as String? == operation.approval.previousGeneration,
                   scope["cloud_protocol_version"] as Int == operation.approval.previousProtocolVersion,
                   scope["user_fingerprint"] as String? == operation.approval.systemFingerprint,
                   rawPause == (operation.stage == .cloudReady ? "cloudResetReview" : "cloudResetRequested") {
                    switch operation.stage {
                    case .prepared: progress = .prepared
                    case .rootPublished: progress = .rootPublished
                    case .libraryCreated: progress = .libraryCreated
                    case .articlesCreated: progress = .articlesCreated
                    case .libraryDeleted: progress = .libraryDeleted
                    case .articlesDeleted: progress = .articlesDeleted
                    case .previousRetained: progress = .previousRetained
                    case .cloudReady: progress = .cloudReady
                    }
                } else {
                    progress = .needsReview
                }
            } else if rawPause == "cloudResetRequested" || rawPause == "cloudResetReview" {
                progress = .needsReview
            }
            return ICloudRecoveryReview(
                isEnabled: scope["is_enabled"], hasSyncScope: scope["scope_account_id"] as String? != nil,
                captureEnabled: (scope["capture_enabled"] as Bool?) ?? false, pause: pause, resetProgress: progress,
                feeds: urls.count, folders: folders, articles: counts["articles"], readArticles: counts["read_articles"],
                starredArticles: counts["starred_articles"], missingIdentities: missing,
                starredMissingIdentities: starredMissing, articlesWithRSSBody: counts["rss_bodies"],
                flaggedFeedLinks: flagged, feedLinksWithCredentials: credentials, feedLinksWithQuery: queries,
                feedLinksWithFragment: fragments, unverifiableFeedLinks: invalid)
        }
    }
}
