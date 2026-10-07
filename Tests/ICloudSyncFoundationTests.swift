import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudSyncIdentityTests: XCTestCase {
    func testConservativeURLNormalizationAndSHA256Names() throws {
        let left = URL(string: "HTTPS://Example.COM:443/rss?b=2&a=1#top")!
        let right = URL(string: "https://example.com/rss?b=2&a=1")!
        XCTAssertEqual(try ICloudSyncIdentity.feedRecordName(feedURL: left),
                       try ICloudSyncIdentity.feedRecordName(feedURL: right))
        XCTAssertEqual(try ICloudSyncIdentity.feedRecordName(feedURL: right).count, 72)
        XCTAssertEqual(try ICloudSyncIdentity.feedRecordName(feedURL: right),
                       "feed-v1:ae3e53b8f85e8c8789fb361815d640d1ec31f47d62380ba0e51835869ee8cdd8")
        for different in [
            "https://example.com/rss/?b=2&a=1",
            "https://example.com/rss?a=1&b=2",
            "http://example.com/rss?b=2&a=1",
            "https://example.com/RSS?b=2&a=1"
        ] {
            XCTAssertNotEqual(try ICloudSyncIdentity.feedRecordName(feedURL: right),
                              try ICloudSyncIdentity.feedRecordName(feedURL: URL(string: different)!))
        }
    }

    func testSourceIDsAreOpaqueAndScopedToTheFeed() throws {
        let feed = URL(string: "https://example.com/rss")!
        let name = try ICloudSyncIdentity.articleRecordName(feedURL: feed, sourceItemID: "urn:文:1|2")
        XCTAssertNotEqual(name, try ICloudSyncIdentity.articleRecordName(
            feedURL: URL(string: "https://example.com/other")!, sourceItemID: "urn:文:1|2"))
        XCTAssertNotEqual(name, try ICloudSyncIdentity.articleRecordName(
            feedURL: feed, sourceItemID: "URN:文:1|2"))
        XCTAssertNotEqual(try ICloudSyncIdentity.articleRecordName(feedURL: feed, sourceItemID: "a"),
                          try ICloudSyncIdentity.articleRecordName(feedURL: feed, sourceItemID: " a"))
        XCTAssertNil(try ICloudSyncIdentity.articleRecordName(feedURL: feed, sourceItemID: nil))
        XCTAssertNil(try ICloudSyncIdentity.articleRecordName(feedURL: feed, sourceItemID: " "))
        XCTAssertThrowsError(try ICloudSyncIdentity.feedRecordName(feedURL: URL(string: "file:///tmp/feed")!))
    }

    func testParserDoesNotAdvertiseRandomOrTitleDateFallbacksAsCloudIdentities() throws {
        let base = URL(string: "https://example.com/feed")!
        let xml = Data("""
            <rss version="2.0"><channel><title>Feed</title>
            <item><guid>opaque-guid</guid><title>One</title></item>
            <item><link>https://example.com/two</link><title>Two</title></item>
            <item><title>Three</title><pubDate>Tue, 01 Sep 2026 12:00:00 GMT</pubDate></item>
            <item><title>Four</title></item>
            </channel></rss>
            """.utf8)
        XCTAssertEqual(try FeedParser.parse(data: xml, baseURL: base).entries.map(\.syncIdentityIsReliable),
                       [true, true, false, false])
        let json = Data("""
            {"version":"https://jsonfeed.org/version/1.1","title":"Feed","items":[
              {"id":"json-guid","title":"One"},
              {"url":"https://example.com/two","title":"Two"},
              {"title":"Three"}]}
            """.utf8)
        XCTAssertEqual(try FeedParser.parse(data: json, baseURL: base).entries.map(\.syncIdentityIsReliable),
                       [true, true, false])
    }

    func testContentPolicyAlwaysRetainsStarsAndOnlyOptionallyUnreadContent() {
        for read in [false, true] {
            for starred in [false, true] {
                for option in [false, true] {
                    XCTAssertEqual(ICloudArticleSyncPolicy.shouldSyncContent(
                        isRead: read, isStarred: starred, syncUnreadContent: option),
                        starred || (!read && option))
                }
            }
        }
        let old = Date(timeIntervalSince1970: 1)
        let cutoff = Date(timeIntervalSince1970: 2)
        XCTAssertTrue(ICloudArticleSyncPolicy.canExpireState(
            isRead: true, isStarred: false, hasPendingChange: false, dateArrived: old, cutoff: cutoff))
        XCTAssertFalse(ICloudArticleSyncPolicy.canExpireState(
            isRead: false, isStarred: false, hasPendingChange: false, dateArrived: old, cutoff: cutoff))
        XCTAssertFalse(ICloudArticleSyncPolicy.canExpireState(
            isRead: true, isStarred: true, hasPendingChange: false, dateArrived: old, cutoff: cutoff))
        XCTAssertFalse(ICloudArticleSyncPolicy.canExpireState(
            isRead: true, isStarred: false, hasPendingChange: true, dateArrived: old, cutoff: cutoff))
        XCTAssertFalse(ICloudArticleSyncPolicy.canExpireState(
            isRead: true, isStarred: false, hasPendingChange: false, dateArrived: cutoff, cutoff: cutoff))
    }
}

final class ICloudSyncFoundationTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var journal: ICloudSyncRepository!
    private let accountID = "local-default"
    private let feedID = UUID().uuidString
    private let itemID = "local-item"
    private enum ProbeError: Error { case rollback }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudFoundation-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        journal = ICloudSyncRepository(database: database)
        try database.write { db in
            try AccountRecord(id: accountID, type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save(db)
            try AccountRecord(id: "reader-account", type: "freshRSS", displayName: "Reader", createdAt: 1, updatedAt: 1).save(db)
            try AccountRecord(id: "miniflux-account", type: "miniflux", displayName: "Miniflux", createdAt: 1, updatedAt: 1).save(db)
            try insertArticle(account: accountID, feed: feedID, item: itemID, in: db)
            try FeedRepository(database: database).setFeedFolder(feedID: feedID, folderName: "News", in: db)
        }
    }

    override func tearDownWithError() throws {
        journal = nil
        database = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func insertArticle(account: String, feed: String, item: String, in db: Database) throws {
        try FeedRecord(id: feed, accountID: account, title: "Feed",
                       feedURL: "https://example.com/rss", updatedAt: 1).save(db)
        try ItemRecord(id: item, accountID: account, externalID: item, feedID: feed,
                       createdAt: 1, updatedAt: 1, sourceItemID: "opaque-source-id").save(db)
        try ArticleRecord(itemID: item, title: "Article", summary: "excluded-summary",
                          contentHTML: "<p>excluded-body</p>", contentUpdatedAt: 1).save(db)
        try ArticleStateRecord(itemID: item, isRead: false, isStarred: false,
                               dateArrived: 1, updatedAt: 1).save(db)
    }

    private func activateAndConfirmBaseline() throws {
        try journal.setCaptureEnabled(accountID: accountID, enabled: true)
        for change in try journal.pendingChanges(accountID: accountID) {
            XCTAssertTrue(try journal.acknowledge(change))
        }
    }

    private func pending() throws -> [ICloudSyncChange] {
        try journal.pendingChanges(accountID: accountID)
    }

    private func state() throws -> ArticleStateRecord {
        try database.read { db in
            try XCTUnwrap(ArticleStateRecord.filter(Column("item_id") == itemID).fetchOne(db))
        }
    }

    private func payload(_ change: ICloudSyncChange) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(change.payloadJSON.utf8)) as? [String: Any])
    }

    func testMigrationNeverEnablesCapture() throws {
        try database.write { db in
            try ArticleStateRepository(database: database).markRead(itemID: itemID, isRead: true, in: db)
            try db.execute(sql: "UPDATE feeds SET title = 'Changed' WHERE id = ?", arguments: [feedID])
        }
        XCTAssertTrue(try pending().isEmpty)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_scope") }, 0)
    }

    func testBaselineHasOnlyWhitelistedStructureAndIndependentFields() throws {
        try journal.setCaptureEnabled(accountID: accountID, enabled: true)
        let changes = try pending()
        XCTAssertEqual(changes.count, 5)
        XCTAssertEqual(Set(changes.map(\.kind)), Set(ICloudSyncChangeKind.allCases))
        let read = try XCTUnwrap(changes.first { $0.kind == .read })
        XCTAssertEqual(Set(try payload(read).keys), ["item_id", "feed_url", "source_item_id", "value"])
        XCTAssertEqual(try payload(read)["source_item_id"] as? String, "opaque-source-id")
        let encoded = changes.map(\.payloadJSON).joined()
        XCTAssertFalse(encoded.contains("excluded-body"))
        XCTAssertFalse(encoded.contains("excluded-summary"))
        XCTAssertFalse(encoded.contains("apiKey"))
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM article_state_outbox") }, 0)
    }

    func testReaderAccountsCannotEnterCloudCaptureAndRetainTheirOutbox() throws {
        for account in ["reader-account", "miniflux-account", "missing"] {
            XCTAssertThrowsError(try journal.setCaptureEnabled(accountID: account, enabled: true)) {
                XCTAssertEqual($0 as? ICloudSyncRepositoryError, .unsupportedAccount)
            }
        }
        try activateAndConfirmBaseline()
        try database.write { db in
            try insertArticle(account: "reader-account", feed: UUID().uuidString, item: "remote-item", in: db)
            try ArticleStateRepository(database: database).markRead(itemID: "remote-item", isRead: true, in: db)
        }
        XCTAssertTrue(try journal.pendingChanges(accountID: "reader-account").isEmpty)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM article_state_outbox") }, 1)
        XCTAssertTrue(try pending().isEmpty)
    }

    func testDirectRecordSaveCapturedButRefreshMetadataDoesNotQueue() throws {
        try activateAndConfirmBaseline()
        try database.write { db in
            var feed = try XCTUnwrap(FeedRecord.fetchOne(db, key: feedID))
            feed.etag = "local-etag"
            feed.lastModified = "local-modified"
            feed.lastRefreshedAt = 5
            feed.storedIconURL = "https://example.com/icon.png"
            feed.updatedAt = 6
            try feed.save(db)
        }
        XCTAssertTrue(try pending().isEmpty)
        try database.write { db in
            var feed = try XCTUnwrap(FeedRecord.fetchOne(db, key: feedID))
            feed.title = "Renamed"
            try feed.save(db)
        }
        let change = try XCTUnwrap(pending().first)
        XCTAssertEqual(change.kind, .feed)
        XCTAssertEqual(try payload(change)["title"] as? String, "Renamed")
        XCTAssertFalse(change.payloadJSON.contains("local-etag"))
        XCTAssertFalse(change.payloadJSON.contains("icon.png"))
    }

    func testRepeatedEditsCoalesceAndLateAcknowledgmentCannotEraseNewRevision() throws {
        try activateAndConfirmBaseline()
        let states = ArticleStateRepository(database: database)
        try database.write { try states.markRead(itemID: itemID, isRead: true, in: $0) }
        let firstSend = try XCTUnwrap(pending().first)
        try database.write { db in
            try states.markRead(itemID: itemID, isRead: false, in: db)
            try states.markStarred(itemID: itemID, isStarred: true, in: db)
        }
        XCTAssertFalse(try journal.acknowledge(firstSend))
        let changes = try pending()
        XCTAssertEqual(changes.count, 2)
        let read = try XCTUnwrap(changes.first { $0.kind == .read })
        XCTAssertGreaterThan(read.revision, firstSend.revision)
        XCTAssertEqual(try payload(read)["value"] as? Int, 0)
        XCTAssertTrue(try journal.acknowledge(read))
        XCTAssertEqual(try pending().map(\.kind), [.starred])
    }

    func testConfirmedRevisionsSurviveAndPreventABA() throws {
        try journal.setCaptureEnabled(accountID: accountID, enabled: true)
        let old = try XCTUnwrap(pending().first { $0.kind == .read })
        for change in try pending() { try journal.acknowledge(change) }
        try database.write { try ArticleStateRepository(database: database).markRead(itemID: itemID, isRead: true, in: $0) }
        let new = try XCTUnwrap(pending().first)
        XCTAssertGreaterThan(new.revision, old.revision)
        XCTAssertFalse(try journal.acknowledge(old))
        XCTAssertEqual(try pending(), [new])
    }

    func testNoOpStateSaveAndRepeatedBaselineDoNotCreateWork() throws {
        try activateAndConfirmBaseline()
        try database.write { db in
            let states = ArticleStateRepository(database: database)
            try states.markRead(itemID: itemID, isRead: false, in: db)
            try states.markStarred(itemID: itemID, isStarred: false, in: db)
        }
        try journal.setCaptureEnabled(accountID: accountID, enabled: true)
        XCTAssertTrue(try pending().isEmpty)
    }

    func testBulkSQLAndMarkAllReadCaptureEachAffectedLocalField() throws {
        try database.write { try insertArticle(account: accountID, feed: UUID().uuidString, item: "second-item", in: $0) }
        try activateAndConfirmBaseline()
        try database.write {
            try ArticleStateRepository(database: database).markAllRead(accountID: accountID, in: $0)
        }
        XCTAssertEqual(Set(try pending().map(\.entityID)), [itemID, "second-item"])
        XCTAssertEqual(Set(try pending().map(\.kind)), [.read])
    }

    func testTransactionRollbackRollsBackStateAndJournalTogether() throws {
        try activateAndConfirmBaseline()
        XCTAssertThrowsError(try database.write { db in
            try ArticleStateRepository(database: database).markRead(itemID: itemID, isRead: true, in: db)
            throw ProbeError.rollback
        })
        XCTAssertFalse(try state().isRead)
        XCTAssertTrue(try pending().isEmpty)
    }

    func testPhysicalFeedDeletionPreservesTombstoneAndCascadeRelationshipSnapshot() throws {
        try activateAndConfirmBaseline()
        try database.write { try FeedRepository(database: database).deleteFeed(id: feedID, in: $0) }
        let changes = try pending()
        let feed = try XCTUnwrap(changes.first { $0.kind == .feed })
        XCTAssertTrue(feed.isTombstone)
        XCTAssertEqual(try payload(feed)["feed_url"] as? String, "https://example.com/rss")
        let relation = try XCTUnwrap(changes.first { $0.kind == .membership })
        XCTAssertTrue(relation.isTombstone)
        XCTAssertEqual(try payload(relation)["feed_id"] as? String, feedID)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
        XCTAssertEqual(try database.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }, 0)
    }

    func testFolderRenameAndMoveCaptureRelationshipDeletesAndAdds() throws {
        try activateAndConfirmBaseline()
        try database.write { try FeedRepository(database: database).renameFolder(
            oldName: "News", newName: "Reading", in: $0) }
        let changes = try pending()
        XCTAssertEqual(changes.filter { $0.kind == .folder }.count, 2)
        XCTAssertEqual(changes.filter { $0.kind == .membership }.count, 2)
        XCTAssertEqual(changes.filter(\.isTombstone).count, 2)
        XCTAssertFalse(changes.contains { $0.kind == .feed })
    }

    func testSuspendedCaptureReconcilesMissedDeletionsAndKeepsRevisions() throws {
        try activateAndConfirmBaseline()
        try journal.setCaptureEnabled(accountID: accountID, enabled: false)
        try database.write { try FeedRepository(database: database).deleteFeed(id: feedID, in: $0) }
        XCTAssertTrue(try pending().isEmpty)
        try journal.setCaptureEnabled(accountID: accountID, enabled: true)
        let changes = try pending()
        XCTAssertEqual(Set(changes.map(\.kind)), [.feed, .membership])
        XCTAssertTrue(changes.allSatisfy { $0.isTombstone && $0.revision > 1 })
    }

    func testDeletingOnlyLocalBodyDoesNotEnqueueCloudStateDeletion() throws {
        try activateAndConfirmBaseline()
        try database.write { try ArticleRepository(database: database).deleteArticle(itemID: itemID, in: $0) }
        XCTAssertTrue(try pending().isEmpty)
        XCTAssertFalse(try state().isRead)
    }

    func testQueuePersistsAcrossReopeningTheDatabase() throws {
        try activateAndConfirmBaseline()
        try database.write { try ArticleStateRepository(database: database).markRead(itemID: itemID, isRead: true, in: $0) }
        let expected = try pending()
        journal = nil
        database = nil
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        journal = ICloudSyncRepository(database: database)
        XCTAssertEqual(try pending(), expected)
        XCTAssertTrue(try state().isRead)
    }

    func testLargeBaselineKeepsSendBatchBoundedAndSingleReadUpdatesOnlyOneField() throws {
        try database.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x + 1 FROM n WHERE x < 99)
                INSERT INTO feeds (id, account_id, title, feed_url, updated_at)
                SELECT 'bulk-feed-' || x, 'local-default', 'Feed', 'https://example.org/' || x, 1 FROM n;

                WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x + 1 FROM n WHERE x < 49999)
                INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at, source_item_id)
                SELECT 'bulk-item-' || x, 'local-default', 'bulk-item-' || x,
                       'bulk-feed-' || (x % 100), 1, 1, 'source-' || x FROM n;

                INSERT INTO article_states (item_id, is_read, is_starred, date_arrived, updated_at)
                SELECT id, 0, 0, 1, 1 FROM items WHERE id LIKE 'bulk-item-%';
                """)
        }
        try journal.setCaptureEnabled(accountID: accountID, enabled: true)
        XCTAssertEqual(try journal.pendingChanges(accountID: accountID).count, 150)
        XCTAssertEqual(try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_changes WHERE is_pending = 1")
        }, 100_105)
        // Set up a fully confirmed large library without 100,000 individual
        // test-side transactions. Confirmation correctness is tested separately.
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_changes SET is_pending = 0") }
        try database.write {
            try ArticleStateRepository(database: database).markRead(itemID: "bulk-item-1", isRead: true, in: $0)
        }
        let changes = try pending()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .read)
        XCTAssertEqual(changes[0].entityID, "bulk-item-1")
    }

    func testRemoteStarAppliesWithoutOverwritingPendingLocalReadOrEcho() throws {
        try activateAndConfirmBaseline()
        try database.write { try ArticleStateRepository(database: database).markRead(itemID: itemID, isRead: true, in: $0) }
        let checkpoint = Data("checkpoint-one".utf8)
        try journal.applyRemoteBatch(accountID: accountID, engineState: checkpoint) { db in
            XCTAssertTrue(try journal.applyRemoteArticleState(
                accountID: accountID, itemID: itemID, isRead: false, isStarred: true, in: db))
        }
        XCTAssertTrue(try state().isRead)
        XCTAssertTrue(try state().isStarred)
        XCTAssertEqual(try pending().map(\.kind), [.read])
        XCTAssertEqual(try journal.engineState(accountID: accountID), checkpoint)
    }

    func testRemoteReadAppliesWithoutOverwritingPendingLocalStar() throws {
        try activateAndConfirmBaseline()
        try database.write { try ArticleStateRepository(database: database).markStarred(itemID: itemID, isStarred: true, in: $0) }
        try journal.applyRemoteBatch(accountID: accountID, engineState: nil) { db in
            try journal.applyRemoteArticleState(
                accountID: accountID, itemID: itemID, isRead: true, isStarred: false, in: db)
        }
        XCTAssertTrue(try state().isRead)
        XCTAssertTrue(try state().isStarred)
        XCTAssertEqual(try pending().map(\.kind), [.starred])
    }

    func testBatchWithoutNewEngineStatePreservesPreviousCheckpoint() throws {
        try activateAndConfirmBaseline()
        let checkpoint = Data("previous-checkpoint".utf8)
        try journal.applyRemoteBatch(accountID: accountID, engineState: checkpoint) { _ in }
        try journal.applyRemoteBatch(accountID: accountID, engineState: nil) { db in
            try journal.applyRemoteArticleState(
                accountID: accountID, itemID: itemID, isRead: true, isStarred: nil, in: db)
        }
        XCTAssertEqual(try journal.engineState(accountID: accountID), checkpoint)
    }

    func testRemoteBatchAndCheckpointRollbackTogetherAndRestoreCapture() throws {
        try activateAndConfirmBaseline()
        XCTAssertThrowsError(try journal.applyRemoteBatch(accountID: accountID, engineState: Data([1])) { db in
            try journal.applyRemoteArticleState(accountID: accountID, itemID: itemID, isRead: true, isStarred: true, in: db)
            throw ProbeError.rollback
        })
        XCTAssertFalse(try state().isRead)
        XCTAssertFalse(try state().isStarred)
        XCTAssertNil(try journal.engineState(accountID: accountID))
        XCTAssertTrue(try pending().isEmpty)
        try database.write { try ArticleStateRepository(database: database).markStarred(itemID: itemID, isStarred: true, in: $0) }
        XCTAssertEqual(try pending().map(\.kind), [.starred])
    }

    func testRemoteSnapshotDoesNotRequeueOnBaselineButLaterUserUndoDoes() throws {
        try activateAndConfirmBaseline()
        try journal.applyRemoteBatch(accountID: accountID, engineState: Data([2])) { db in
            try journal.applyRemoteArticleState(accountID: accountID, itemID: itemID, isRead: true, isStarred: nil, in: db)
        }
        try journal.setCaptureEnabled(accountID: accountID, enabled: true)
        XCTAssertTrue(try pending().isEmpty)
        try database.write { try ArticleStateRepository(database: database).markRead(itemID: itemID, isRead: false, in: $0) }
        XCTAssertEqual(try pending().map(\.kind), [.read])
        XCTAssertEqual(try payload(XCTUnwrap(pending().first))["value"] as? Int, 0)
    }

    func testRemoteApplicationRequiresScopedBatchAndDoesNotCrossAccounts() throws {
        try activateAndConfirmBaseline()
        XCTAssertThrowsError(try database.write {
            try journal.applyRemoteArticleState(accountID: accountID, itemID: itemID, isRead: true, isStarred: nil, in: $0)
        }) { XCTAssertEqual($0 as? ICloudSyncRepositoryError, .remoteBatchRequired) }
        try database.write { try insertArticle(account: "reader-account", feed: UUID().uuidString, item: "remote-item", in: $0) }
        XCTAssertThrowsError(try journal.applyRemoteBatch(accountID: accountID, engineState: Data([3])) { db in
            try journal.applyRemoteArticleState(accountID: accountID, itemID: "remote-item", isRead: true, isStarred: nil, in: db)
        }) { XCTAssertEqual($0 as? ICloudSyncRepositoryError, .wrongAccount) }
        XCTAssertNil(try journal.engineState(accountID: accountID))
        XCTAssertThrowsError(try journal.applyRemoteBatch(accountID: "reader-account", engineState: nil) { _ in }) {
            XCTAssertEqual($0 as? ICloudSyncRepositoryError, .inactiveScope)
        }
    }

    func testMissingRemoteItemCannotAdvanceCheckpointOrInventLocalArticle() throws {
        try activateAndConfirmBaseline()
        XCTAssertThrowsError(try journal.applyRemoteBatch(accountID: accountID, engineState: Data([4])) { db in
            try journal.applyRemoteArticleState(
                accountID: accountID, itemID: "not-downloaded", isRead: true, isStarred: true, in: db)
        }) { XCTAssertEqual($0 as? ICloudSyncRepositoryError, .missingItem) }
        XCTAssertNil(try journal.engineState(accountID: accountID))
        XCTAssertTrue(try pending().isEmpty)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 1)
    }

    func testExistingOPMLImportAutomaticallyCapturesFeedInsertion() async throws {
        try activateAndConfirmBaseline()
        let provider = LocalAccountProvider(accountID: accountID, database: database)
        let opml = Data("""
            <opml version="2.0"><head><title>Import</title></head><body>
              <outline text="Imported"><outline type="rss" text="New Feed"
                xmlUrl="https://example.org/feed"/></outline>
            </body></opml>
            """.utf8)
        _ = try await provider.importOPMLAsync(opml)
        XCTAssertEqual(Set(try pending().map(\.kind)), [.feed, .folder, .membership])
        let imported = try XCTUnwrap(provider.fetchFeeds().first { $0.feedURL.absoluteString == "https://example.org/feed" })
        XCTAssertEqual(imported.title, "New Feed")
        XCTAssertEqual(imported.folder, "Imported")
    }

    func testSourceIdentityBackfillKeepsExistingLocalIdentityAndReadingState() throws {
        let parsed = ParsedFeedEntry(id: "legacy-guid", title: "Legacy", author: nil, url: nil,
                                     publishedAt: nil, summary: "", contentHTML: nil)
        let legacyID = "\(feedID)|\(parsed.id)".stableDigest
        try database.write { db in
            try ItemRecord(id: legacyID, accountID: accountID, externalID: legacyID,
                           feedID: feedID, createdAt: 1, updatedAt: 1).save(db)
            try ArticleRecord(itemID: legacyID, title: "Legacy", contentUpdatedAt: 1).save(db)
            try ArticleStateRecord(itemID: legacyID, isRead: true, isStarred: true,
                                   dateArrived: 1, updatedAt: 1).save(db)
        }
        try activateAndConfirmBaseline()
        let added = try database.write { db in
            try ArticleRepository(database: database).mergeParsedEntries(
                feedID: feedID, parsedEntries: [parsed], in: db)
        }
        XCTAssertTrue(added.isEmpty)
        let item = try database.read { try XCTUnwrap(ItemRecord.fetchOne($0, key: legacyID)) }
        XCTAssertEqual(item.id, legacyID)
        XCTAssertEqual(item.externalID, legacyID)
        XCTAssertEqual(item.sourceItemID, "legacy-guid")
        let state = try database.read { try XCTUnwrap(ArticleStateRecord.fetchOne($0, key: legacyID)) }
        XCTAssertTrue(state.isRead)
        XCTAssertTrue(state.isStarred)
        XCTAssertEqual(Set(try pending().map(\.kind)), [.read, .starred])
        for change in try pending() {
            XCTAssertEqual(try payload(change)["source_item_id"] as? String, "legacy-guid")
            XCTAssertEqual(try payload(change)["value"] as? Int, 1)
        }
    }

    func testDistinctLocalFeedUUIDsProduceTheSamePortableArticleIdentity() throws {
        let secondFeedID = UUID().uuidString
        let parsed = ParsedFeedEntry(id: "shared-guid", title: "Article", author: nil, url: nil,
                                     publishedAt: nil, summary: "", contentHTML: nil)
        try database.write { db in
            try FeedRecord(id: secondFeedID, accountID: accountID, title: "Feed",
                           feedURL: "https://example.com/rss", updatedAt: 1).save(db)
            for feed in [feedID, secondFeedID] {
                _ = try ArticleRepository(database: database).mergeParsedEntries(
                    feedID: feed, parsedEntries: [parsed], in: db)
            }
        }
        let localIDs = [feedID, secondFeedID].map { "\($0)|\(parsed.id)".stableDigest }
        XCTAssertNotEqual(localIDs[0], localIDs[1])
        let names = try database.read { db in
            try localIDs.map { id in
                let item = try XCTUnwrap(ItemRecord.fetchOne(db, key: id))
                let feed = try XCTUnwrap(FeedRecord.fetchOne(db, key: item.feedID))
                return try ICloudSyncIdentity.articleRecordName(
                    feedURL: URL(string: feed.feedURL)!, sourceItemID: item.sourceItemID)
            }
        }
        XCTAssertNotNil(names[0])
        XCTAssertEqual(names[0], names[1])
    }

    func testUnreliableParserFallbackDoesNotPersistASourceIdentity() throws {
        var parsed = ParsedFeedEntry(id: "temporary-id", title: "Local only", author: nil, url: nil,
                                     publishedAt: nil, summary: "", contentHTML: nil)
        parsed.syncIdentityIsReliable = false
        let added = try database.write { try ArticleRepository(database: database).mergeParsedEntries(
            feedID: feedID, parsedEntries: [parsed], in: $0) }
        XCTAssertEqual(added.count, 1)
        let item = try database.read { try XCTUnwrap(ItemRecord.fetchOne($0, key: added[0].id)) }
        XCTAssertNil(item.sourceItemID)
    }

    func testV13MigrationPreservesDataAndOptionalLegacyItemDecoding() throws {
        let legacyPath = directory.appendingPathComponent("legacy.sqlite")
        let pool = try DatabasePool(path: legacyPath.path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v13-extend-account-types-miniflux")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO accounts (id, type, display_name, created_at, updated_at) VALUES ('local', 'local', 'Local', 1, 1);
                INSERT INTO feeds (id, account_id, title, feed_url, updated_at) VALUES ('old-feed', 'local', 'Feed', 'https://example.com/rss', 1);
                INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at) VALUES ('old-item', 'local', 'old-item', 'old-feed', 1, 1);
                INSERT INTO articles (item_id, title, content_html, content_updated_at) VALUES ('old-item', 'Kept', '<p>Kept</p>', 1);
                INSERT INTO article_states (item_id, is_read, is_starred, date_arrived, updated_at) VALUES ('old-item', 1, 1, 1, 1);
                """)
        }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertNil(try XCTUnwrap(ItemRecord.fetchOne(db, key: "old-item")).sourceItemID)
            XCTAssertEqual(try XCTUnwrap(ArticleRecord.fetchOne(db, key: "old-item")).contentHTML, "<p>Kept</p>")
            XCTAssertTrue(try XCTUnwrap(ArticleStateRecord.fetchOne(db, key: "old-item")).isStarred)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_scope"), 0)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        let json = Data("""
            {"id":"old-item","account_id":"local","external_id":"old-item","feed_id":"old-feed","created_at":1,"updated_at":1}
            """.utf8)
        XCTAssertNil(try JSONDecoder().decode(ItemRecord.self, from: json).sourceItemID)
    }
}
