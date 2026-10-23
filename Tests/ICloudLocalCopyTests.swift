import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudLocalCopyTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private let local = "local-default", cloud = "copy-cloud"
    private let generation = "00000000-0000-0000-0000-000000000002"
    private let date = Date(timeIntervalSince1970: 100)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCopy-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write { db in
            try AccountRecord(id: local, type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).insert(db)
            try AccountRecord(id: cloud, type: "iCloud", displayName: "Cloud", createdAt: 1, updatedAt: 1).insert(db)
        }
        let repository = ICloudRecordRepository(database: database, accountID: cloud)
        try repository.activate()
        try repository.bindSystemUserFingerprint("system-a")
        try database.write {
            try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation = ?, initialized_zones = 3 WHERE account_id = ?",
                           arguments: [generation, cloud])
        }
    }
    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }
    private var repository: ICloudLocalCopyRepository { .init(database: database) }
    private var context: ICloudLocalCopyRepository.Context { .init(userFingerprint: "system-a", generation: generation) }
    private func selection(feeds: Set<String>, folders: Set<String> = [], articles: Bool = true,
                           reviewed: Set<String> = [], source: String? = nil) -> ICloudLocalCopyRepository.Selection {
        .init(sourceAccountID: source ?? local, targetAccountID: cloud, feedIDs: feeds, folderIDs: folders,
              articles: articles ? .reliableArticles : .none, reviewedLinkIDs: reviewed)
    }
    private func plan(feeds: Set<String>, folders: Set<String> = [], articles: Bool = true,
                      reviewed: Set<String> = []) async throws -> ICloudLocalCopyRepository.Plan {
        try await repository.prepare(selection: selection(feeds: feeds, folders: folders, articles: articles, reviewed: reviewed),
                                     context: context, at: date)
    }
    private func execute(_ plan: ICloudLocalCopyRepository.Plan) async throws -> ICloudLocalCopyRepository.Counts {
        try await repository.execute(.init(plan), at: date.addingTimeInterval(1))
    }
    @discardableResult
    private func feed(_ url: String = "https://source.example/rss", account: String? = nil, deleted: Bool = false) throws -> String {
        let id = UUID().uuidString
        try database.write {
            try FeedRecord(id: id, accountID: account ?? local, externalID: "source-external-" + id, title: "RSS",
                siteURL: "https://source.example", feedURL: url, etag: "source-etag", lastModified: "source-date",
                lastRefreshedAt: 1, isDeleted: deleted, updatedAt: 1, storedIconURL: "https://private.example/icon", sortOrder: 4).insert($0)
        }
        return id
    }
    @discardableResult
    private func folder(_ name: String, account: String? = nil, deleted: Bool = false) throws -> String {
        let id = UUID().uuidString
        try database.write { try FolderRecord(id: id, accountID: account ?? local, externalID: "source-folder-" + id,
                                              name: name, sortOrder: 2, isDeleted: deleted, updatedAt: 1).insert($0) }
        return id
    }
    @discardableResult
    private func article(_ feed: String, guid: String? = "guid", read: Bool = true, star: Bool = true,
                         account: String? = nil, state: Bool = true, text: Bool = true, body: String = "<p>RSS</p>") throws -> String {
        let id = UUID().uuidString
        try database.write { db in
            try ItemRecord(id: id, accountID: account ?? local, externalID: "source-item-" + id, feedID: feed,
                           createdAt: 1, updatedAt: 1, sourceItemID: guid).insert(db)
            if text {
                var record = ArticleRecord(itemID: id, title: "RSS title", author: "author", url: "https://source.example/item",
                    publishedAt: 2, summary: "RSS summary", contentHTML: body, contentUpdatedAt: 1)
                record.previewImageURL = "https://private.example/derived-preview"
                record.previewInputHash = "derived-hash"
                record.previewExtractionRevision = 9
                try record.insert(db)
            }
            if state { try ArticleStateRecord(itemID: id, isRead: read, isStarred: star, dateArrived: 3, updatedAt: 1).insert(db) }
        }
        return id
    }
    private func rows() throws -> [Row] {
        try database.read { db in
            var result: [Row] = []
            for table in ["accounts", "feeds", "folders", "feed_folders", "items", "articles", "article_states",
                          "icloud_sync_scope", "icloud_sync_changes", "icloud_content_changes", "icloud_records", "icloud_record_mappings"] {
                result += try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            return result
        }
    }
    private func expectFailure(_ error: ICloudLocalCopyError, _ action: () async throws -> Void) async throws {
        let before = try rows()
        do { try await action(); XCTFail("Expected rejected copy") }
        catch let actual as ICloudLocalCopyError { XCTAssertEqual(actual, error) }
        XCTAssertEqual(try rows(), before)
    }

    func testPreparationIsReadOnlyAndNeedsCurrentBoundScope() async throws {
        let f = try feed()
        try article(f)
        let before = try rows()
        let ready = try await plan(feeds: [f])
        XCTAssertEqual(ready.counts.feeds, 1)
        XCTAssertEqual(ready.counts.articles, 1)
        XCTAssertEqual(try rows(), before)
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET initialized_zones = 1") }
        try await expectFailure(.unavailableTarget) { _ = try await self.plan(feeds: [f]) }
    }

    func testCopyPreservesSourceAndCreatesCompleteGraphAndDurableIntents() async throws {
        let f = try feed(), one = try folder("One"), two = try folder("Two")
        let item = try article(f, guid: " opaque ")
        try database.write {
            try FeedFolderRecord(feedID: f, folderID: one).insert($0)
            try FeedFolderRecord(feedID: f, folderID: two).insert($0)
        }
        let sourceBefore = try database.read { db in
            [try FeedRecord.fetchOne(db, key: f)!].map { $0 }
        }
        let sourceText = try database.read { try Row.fetchOne($0, sql: "SELECT * FROM articles WHERE item_id = ?", arguments: [item]) }
        let result = try await execute(plan(feeds: [f], folders: [one, two]))
        XCTAssertEqual(result.feeds, 1); XCTAssertEqual(result.folders, 2); XCTAssertEqual(result.relationships, 2)
        XCTAssertEqual(result.articles, 1); XCTAssertEqual(result.rssBodies, 1)
        try database.read { db in
            XCTAssertEqual(try FeedRecord.fetchOne(db, key: f), sourceBefore.first)
            XCTAssertEqual(try Row.fetchOne(db, sql: "SELECT * FROM articles WHERE item_id = ?", arguments: [item]), sourceText)
            let copied = try FeedRecord.filter(Column("account_id") == cloud).fetchOne(db)!
            XCTAssertNotEqual(copied.id, f); XCTAssertEqual(copied.feedURL, sourceBefore[0].feedURL)
            XCTAssertNil(copied.externalID); XCTAssertNil(copied.etag); XCTAssertNil(copied.lastModified)
            XCTAssertNil(copied.lastRefreshedAt); XCTAssertNil(copied.storedIconURL)
            XCTAssertEqual(copied.sortOrder, 4)
            let targetItem = try ItemRecord.filter(Column("account_id") == cloud).fetchOne(db)!
            XCTAssertEqual(targetItem.sourceItemID, " opaque ")
            XCTAssertEqual(targetItem.id, "\(copied.id)| opaque ".stableDigest)
            XCTAssertEqual(targetItem.externalID, targetItem.id)
            let state = try ArticleStateRecord.fetchOne(db, key: targetItem.id)!
            XCTAssertTrue(state.isRead); XCTAssertTrue(state.isStarred); XCTAssertEqual(state.dateArrived, 3)
            let content = try ArticleRecord.fetchOne(db, key: targetItem.id)!
            XCTAssertEqual(content.contentHTML, "<p>RSS</p>"); XCTAssertEqual(content.summary, "RSS summary")
            XCTAssertNil(content.previewImageURL); XCTAssertNil(content.previewInputHash); XCTAssertEqual(content.previewExtractionRevision, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_changes WHERE account_id = ? AND is_pending = 1", arguments: [cloud]), 7)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_content_changes WHERE account_id = ? AND is_pending = 1", arguments: [cloud]), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cloud_generation FROM icloud_sync_scope WHERE account_id = ?", arguments: [cloud]), generation)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_scope WHERE account_id = ?", arguments: [local]), 0)
        }
    }

    func testSubscriptionsOnlyDoesNotReadOrCopyArticleBodiesOrStates() async throws {
        let f = try feed()
        let sourceItem = try article(f, body: String(repeating: "secret", count: 1500000))
        let prepared = try await plan(feeds: [f], articles: false)
        try database.write { try $0.execute(sql: "UPDATE article_states SET is_starred = 0 WHERE item_id = ?", arguments: [sourceItem]) }
        let result = try await execute(prepared)
        XCTAssertEqual(result.articles, 0); XCTAssertEqual(result.rssBodies, 0)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items WHERE account_id = ?", arguments: [cloud]) }, 0)
    }

    func testDefaultBodyPolicyCopiesStarredOnlyAndUnreadRequiresExistingTargetOption() async throws {
        let f = try feed()
        try article(f, guid: "read", read: true, star: false)
        try article(f, guid: "unread", read: false, star: false)
        try article(f, guid: "star", read: true, star: true)
        let copied = try await execute(plan(feeds: [f]))
        XCTAssertEqual(copied.articles, 3); XCTAssertEqual(copied.rssBodies, 1)
        let bodies = try database.read { try Row.fetchAll($0, sql: "SELECT i.source_item_id, a.content_html, a.summary FROM items i JOIN articles a ON a.item_id = i.id WHERE i.account_id = ? ORDER BY i.source_item_id", arguments: [cloud]) }
        XCTAssertNil(bodies[0]["content_html"] as String?); XCTAssertEqual(bodies[0]["summary"] as String, "")
        XCTAssertEqual(bodies[1]["content_html"] as String?, "<p>RSS</p>"); XCTAssertNil(bodies[2]["content_html"] as String?)
        let second = try feed("https://unread.example/rss")
        try article(second, read: false, star: false)
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET sync_unread_content = 1 WHERE account_id = ?", arguments: [cloud]) }
        let unread = try await execute(plan(feeds: [second]))
        XCTAssertEqual(unread.rssBodies, 1)
    }

    func testMissingDuplicateAndIncompleteArticleIdentitiesStayInSource() async throws {
        let f = try feed()
        try article(f, guid: nil); try article(f, guid: "\n\u{00A0}")
        try article(f, guid: "duplicate"); try article(f, guid: "duplicate")
        try article(f, guid: "no-state", state: false); try article(f, guid: "no-text", text: false)
        try article(f, guid: "valid")
        let copied = try await execute(plan(feeds: [f]))
        XCTAssertEqual(copied.articles, 1); XCTAssertEqual(copied.skippedArticles, 6)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items WHERE account_id = ?", arguments: [local]) }, 7)
    }

    func testAmbiguousInvalidAndCredentialFeedLinksStayLocalAndQueryNeedsReview() async throws {
        let first = try feed("https://example.com/rss#one"), alias = try feed("HTTPS://EXAMPLE.COM:443/rss#two")
        let credentials = try feed("https://user:password@private.example/rss?token=secret")
        let invalid = try feed("file:///private/rss"), query = try feed("https://query.example/rss?a=1&b=2")
        for f in [first, alias, credentials, invalid, query] { try article(f) }
        let prepared = try await plan(feeds: [first, alias, credentials, invalid, query], reviewed: [first, alias, credentials])
        XCTAssertEqual(prepared.counts.feeds, 0); XCTAssertEqual(prepared.counts.skippedFeeds, 5)
        _ = try await execute(prepared)
        let reviewed = try await execute(plan(feeds: [query], reviewed: [query]))
        XCTAssertEqual(reviewed.feeds, 1)
        XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT feed_url FROM feeds WHERE account_id = ?", arguments: [cloud]) }, "https://query.example/rss?a=1&b=2")
    }

    func testExistingTargetAndDeletedParentNeverReceiveSourceStateOrResurrect() async throws {
        let localFeed = try feed(), target = try feed(account: cloud)
        try article(localFeed, guid: "same", read: true, star: true)
        let targetItem = try article(target, guid: "same", read: false, star: false, account: cloud)
        let before = try rows()
        let result = try await execute(plan(feeds: [localFeed]))
        XCTAssertEqual(result.feeds, 0); XCTAssertEqual(result.articles, 0); XCTAssertEqual(try rows(), before)
        try database.write { try $0.execute(sql: "UPDATE feeds SET is_deleted = 1 WHERE id = ?", arguments: [target]) }
        let deletedBefore = try rows()
        _ = try await execute(plan(feeds: [localFeed]))
        XCTAssertEqual(try rows(), deletedBefore)
        XCTAssertFalse(try database.read { try ArticleStateRecord.fetchOne($0, key: targetItem)!.isStarred })
    }

    func testWebsiteCredentialsAndUnverifiableLinksNeverCopyEvenWhenReviewed() async throws {
        var feeds: Set<String> = []
        for (index, website) in ["https://user:password@private.example/", "https://user:password@private.example/path with space", "file:///private/rss"].enumerated() {
            let source = try feed("https://source.example/\(index)/rss")
            try article(source)
            try database.write { try $0.execute(sql: "UPDATE feeds SET site_url = ? WHERE id = ?", arguments: [website, source]) }
            feeds.insert(source)
        }
        let before = try rows()
        let review = try await plan(feeds: feeds, reviewed: feeds)
        XCTAssertEqual(review.counts.feeds, 0); XCTAssertEqual(review.counts.skippedFeeds, 3)
        XCTAssertEqual(review.counts.articles, 0)
        _ = try await execute(review)
        XCTAssertEqual(try rows(), before)
    }

    func testPurgedFeedWithPendingTombstoneStillProtectsTargetIdentity() async throws {
        let source = try feed(), target = try feed(account: cloud)
        try database.write { _ = try FeedRecord.deleteOne($0, key: target) }
        let before = try rows()
        let result = try await execute(plan(feeds: [source]))
        XCTAssertEqual(result.feeds, 0); XCTAssertEqual(try rows(), before)
    }

    func testOrphanCloudStateAndPurgedFeedMappingProtectTargetIdentity() async throws {
        let f = try feed()
        let url = URL(string: "https://source.example/rss")!
        let identity = try ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: "remote-only")!
        let wire = try ICloudRecordEnvelope(kind: .read, recordName: "read-v1:" + identity.dropFirst("article-v1:".count),
            feedURL: url.absoluteString, sourceItemID: "remote-only", fields: ["value": .init(value: .flag(true), version: .bootstrap)])
        try database.write { db in
            let json = String(data: try JSONEncoder().encode(wire), encoding: .utf8)!
            try db.execute(sql: "INSERT INTO icloud_records(account_id, zone, record_name, envelope_json) VALUES (?, ?, ?, ?)",
                           arguments: [cloud, wire.zone.rawValue, wire.recordName, json])
        }
        let orphan = try await plan(feeds: [f])
        XCTAssertEqual(orphan.counts.feeds, 0)
        try database.write { db in
            try db.execute(sql: "DELETE FROM icloud_records WHERE account_id = ?", arguments: [cloud])
            try db.execute(sql: "INSERT INTO icloud_record_mappings(account_id, kind, entity_id, record_name) VALUES (?, 'feed', 'purged', ?)",
                           arguments: [cloud, try ICloudSyncIdentity.feedRecordName(feedURL: url)])
        }
        let mapped = try await plan(feeds: [f])
        XCTAssertEqual(mapped.counts.feeds, 0)
    }

    // Deliberately rewrite both nested and outer object key order; array order
    // and scalar values are preserved. All data lives in this test's database.
    private func orderedJSON(_ value: Any, reversed: Bool) throws -> String {
        if let object = value as? [String: Any] {
            let keys = object.keys.sorted()
            return "{" + (try (reversed ? Array(keys.reversed()) : keys).map { key in
                let quoted = try orderedJSON(key, reversed: reversed)
                return quoted + ":" + (try orderedJSON(object[key]!, reversed: reversed))
            }).joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            return "[" + (try array.map { try orderedJSON($0, reversed: reversed) }).joined(separator: ",") + "]"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private func orphanJSONFixture() throws -> (String, String, [String: Any]) {
        let existing = try feed(), fresh = try feed("https://new.example/rss")
        let url = URL(string: "https://source.example/rss")!
        let identity = try ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: "remote-only")!
        let wire = try ICloudRecordEnvelope(kind: .read, recordName: "read-v1:" + identity.dropFirst("article-v1:".count),
            feedURL: url.absoluteString, sourceItemID: "remote-only", fields: ["value": .init(value: .flag(true), version: .bootstrap)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        // Unknown fields must remain protected too, including exact large integers.
        object["future"] = ["counter": Int64(9007199254740993), "values": [1, 2]] as [String: Any]
        try database.write { db in
            try db.execute(sql: "INSERT INTO icloud_records(account_id, zone, record_name, envelope_json) VALUES (?, ?, ?, ?)",
                arguments: [cloud, wire.zone.rawValue, wire.recordName, try orderedJSON(object, reversed: true)])
        }
        return (existing, fresh, object)
    }

    func testJSONKeyOrderDoesNotInvalidateOrphanCopyPlan() async throws {
        let (existing, fresh, object) = try orphanJSONFixture()
        let reviewed = try await plan(feeds: [existing, fresh])
        XCTAssertEqual(reviewed.counts.feeds, 1)
        XCTAssertEqual(reviewed.counts.skippedFeeds, 1)
        let reordered = try orderedJSON(object, reversed: false)
        XCTAssertNotEqual(reordered, try orderedJSON(object, reversed: true))
        try database.write { try $0.execute(sql: "UPDATE icloud_records SET envelope_json = ? WHERE account_id = ?", arguments: [reordered, cloud]) }
        let copied = try await execute(reviewed)
        XCTAssertEqual(copied.feeds, 1)
        let urls = try database.read { try String.fetchAll($0, sql: "SELECT feed_url FROM feeds WHERE account_id = ?", arguments: [cloud]) }
        XCTAssertEqual(urls, ["https://new.example/rss"])
    }

    func testJSONValueChangeStillInvalidatesCopyPlan() async throws {
        let (existing, fresh, original) = try orphanJSONFixture()
        let reviewed = try await plan(feeds: [existing, fresh])
        var changed = original
        changed["future"] = ["counter": Int64(9007199254740992), "values": [1, 2]] as [String: Any]
        let json = try orderedJSON(changed, reversed: false)
        try database.write { try $0.execute(sql: "UPDATE icloud_records SET envelope_json = ? WHERE account_id = ?", arguments: [json, cloud]) }
        try await expectFailure(.stalePlan) { _ = try await self.execute(reviewed) }
    }

    func testDuplicateAndOccupiedFolderNamesAndForeignRelationshipsAreSkipped() async throws {
        let f = try feed(), duplicate1 = try folder("Duplicate"), duplicate2 = try folder("Duplicate")
        let occupied = try folder("Occupied"), new = try folder("New")
        _ = try folder("Occupied", account: cloud, deleted: true)
        let foreign = try folder("Foreign", account: cloud)
        try database.write { db in
            for id in [duplicate1, duplicate2, occupied, new, foreign] { try FeedFolderRecord(feedID: f, folderID: id).insert(db) }
        }
        let result = try await execute(plan(feeds: [f], folders: [duplicate1, duplicate2, occupied, new]))
        XCTAssertEqual(result.folders, 1); XCTAssertEqual(result.skippedFolders, 3); XCTAssertEqual(result.relationships, 1)
    }

    func testStateGUIDAndRSSChangesInvalidateReviewedPlanEvenWithSameCounts() async throws {
        let f = try feed(), item = try article(f)
        for sql in ["UPDATE article_states SET is_read = 1 - is_read WHERE item_id = ?",
                    "UPDATE items SET source_item_id = source_item_id || 'changed' WHERE id = ?",
                    "UPDATE articles SET content_html = '<p>changed RSS</p>' WHERE item_id = ?"] {
            let prepared = try await plan(feeds: [f])
            try database.write { try $0.execute(sql: sql, arguments: [item]) }
            try await expectFailure(.stalePlan) { _ = try await self.execute(prepared) }
        }
    }

    func testTargetChangesInvalidatePlanAndDisabledChangedOrPausedScopeRejects() async throws {
        let f = try feed()
        let prepared = try await plan(feeds: [f])
        _ = try folder("Other", account: cloud)
        try await expectFailure(.stalePlan) { _ = try await self.execute(prepared) }
        for sql in ["UPDATE accounts SET is_enabled = 0 WHERE type = 'iCloud'",
                    "UPDATE icloud_sync_scope SET capture_enabled = 0", "UPDATE icloud_sync_scope SET suppress_capture = 1",
                    "UPDATE icloud_sync_scope SET pause_reason = 'accountChanged'",
                    "UPDATE icloud_sync_scope SET user_fingerprint = 'system-b'",
                    "UPDATE icloud_sync_scope SET cloud_generation = NULL",
                    "UPDATE icloud_sync_scope SET cloud_reset_operation = X'00'"] {
            let candidate = try await plan(feeds: [f])
            try database.write { try $0.execute(sql: sql) }
            try await expectFailure(.unavailableTarget) { _ = try await self.execute(candidate) }
            try database.write { db in
                try db.execute(sql: "UPDATE accounts SET is_enabled = 1 WHERE type = 'iCloud'")
                try db.execute(sql: "UPDATE icloud_sync_scope SET capture_enabled = 1, suppress_capture = 0, pause_reason = NULL, user_fingerprint = 'system-a', cloud_generation = ?, cloud_reset_operation = NULL", arguments: [generation])
            }
        }
    }

    func testExpiredFutureAndOtherDatabasePlansCannotExecute() async throws {
        let f = try feed(), candidate = try await plan(feeds: [f])
        for time in [-1.0, 600.0] {
            try await expectFailure(.stalePlan) {
                _ = try await self.repository.execute(.init(candidate), at: self.date.addingTimeInterval(time))
            }
        }
        let other = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try await expectFailure(.stalePlan) {
            _ = try await ICloudLocalCopyRepository(database: other).execute(.init(candidate), at: self.date)
        }
    }

    func testTransactionFailureRollsBackGraphJournalAndClockAndCanRetrySamePlan() async throws {
        let f = try feed(), folder = try folder("Folder")
        try article(f)
        let prepared = try await plan(feeds: [f], folders: [folder])
        try database.write { try $0.execute(sql: "CREATE TRIGGER fail_copy BEFORE INSERT ON article_states WHEN NEW.item_id != 'source' AND EXISTS(SELECT 1 FROM items i WHERE i.id = NEW.item_id AND i.account_id = 'copy-cloud') BEGIN SELECT RAISE(ABORT, 'copy injection'); END") }
        let before = try rows()
        do { _ = try await execute(prepared); XCTFail("Expected transaction failure") }
        catch is DatabaseError {}
        XCTAssertEqual(try rows(), before)
        try database.write { try $0.execute(sql: "DROP TRIGGER fail_copy") }
        let retried = try await execute(prepared)
        XCTAssertEqual(retried.articles, 1)
    }

    func testCancellationWhileWriterIsQueuedDoesNotCopyOrChangeIntents() async throws {
        let f = try feed(), candidate = try await plan(feeds: [f])
        let before = try rows()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let db = database!
        let blocker = Task { try await db.writeAsync { _ in started.signal(); release.wait(); return true } }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let copyRepository = repository
        let operationDate = date
        let operation = Task { try await copyRepository.execute(.init(candidate), at: operationDate) }
        try await Task.sleep(for: .milliseconds(30))
        operation.cancel(); release.signal()
        _ = try await blocker.value
        do { _ = try await operation.value; XCTFail("Expected cancelled copy") }
        catch is CancellationError {}
        XCTAssertEqual(try rows(), before)
    }

    func testOversizedRSSBodyStaysInSourceWhileReliableStarredStateCopies() async throws {
        let f = try feed(), original = String(repeating: "x", count: 8388609)
        let item = try article(f, body: original)
        let result = try await execute(plan(feeds: [f]))
        XCTAssertEqual(result.articles, 1); XCTAssertEqual(result.rssBodies, 0); XCTAssertEqual(result.omittedRSSBodies, 1)
        XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT content_html FROM articles WHERE item_id = ?", arguments: [item]) }, original)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM article_states s JOIN items i ON i.id = s.item_id WHERE i.account_id = ? AND is_starred = 1", arguments: [cloud]) }, 1)
    }

    func testPlanExpiringWhileQueuedIsRejectedBeforeAnyInsert() async throws {
        let f = try feed(), candidate = try await plan(feeds: [f])
        let before = try rows()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let db = database!
        let blocker = Task { try await db.writeAsync { _ in started.signal(); release.wait(); return true } }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let copyRepository = repository
        let operationDate = date.addingTimeInterval(599.98)
        let operation = Task { try await copyRepository.execute(.init(candidate), at: operationDate) }
        try await Task.sleep(for: .milliseconds(80))
        release.signal()
        _ = try await blocker.value
        do { _ = try await operation.value; XCTFail("Expected expired plan") }
        catch let error as ICloudLocalCopyError { XCTAssertEqual(error, .stalePlan) }
        XCTAssertEqual(try rows(), before)
    }

    func testRepeatedCopyIsIdempotentAndOldReviewedPlanBecomesStale() async throws {
        let f = try feed()
        try article(f)
        let first = try await plan(feeds: [f])
        _ = try await execute(first)
        try await expectFailure(.stalePlan) { _ = try await self.execute(first) }
        let before = try rows(), next = try await plan(feeds: [f])
        let result = try await execute(next)
        XCTAssertEqual(result.feeds, 0); XCTAssertEqual(result.articles, 0); XCTAssertEqual(try rows(), before)
    }

    func testInvalidOrForeignSelectionAndMalformedTargetCacheRejectBeforeMutation() async throws {
        let f = try feed(), targetFeed = try feed("https://target.example/rss", account: cloud)
        for selected in [selection(feeds: [targetFeed]), selection(feeds: [f], reviewed: ["not-selected"]),
                         selection(feeds: [f], source: cloud)] {
            try await expectFailure(.invalidSelection) {
                _ = try await self.repository.prepare(selection: selected, context: self.context, at: self.date)
            }
        }
        try database.write { try $0.execute(sql: "INSERT INTO icloud_records(account_id, zone, record_name, envelope_json) VALUES (?, ?, 'unknown', '{}')", arguments: [cloud, ICloudRecordZone.library.rawValue]) }
        try await expectFailure(.targetRequiresReview) { _ = try await self.plan(feeds: [f]) }
    }
}
