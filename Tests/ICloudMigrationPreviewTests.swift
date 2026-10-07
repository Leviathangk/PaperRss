import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudMigrationPreviewTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private let source = "local-default"
    private let cloud = "preview-cloud"
    private let device = "00000000-0000-0000-0000-000000000001"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationPreview-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write {
            try AccountRecord(id: source, type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save($0)
        }
    }
    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func preview(_ account: String? = nil) async throws -> ICloudMigrationPreview {
        try await ICloudMigrationPreviewRepository(database: database).preview(sourceAccountID: account ?? source)
    }
    private func addCloud() throws -> ICloudRecordRepository {
        try database.write {
            try AccountRecord(id: cloud, type: "iCloud", displayName: "Cloud", createdAt: 1, updatedAt: 1).save($0)
        }
        return ICloudRecordRepository(database: database, accountID: cloud)
    }
    @discardableResult
    private func feed(_ url: String = "https://example.com/rss", account: String? = nil, deleted: Bool = false) throws -> String {
        let id = UUID().uuidString
        try database.write {
            try FeedRecord(id: id, accountID: account ?? source, title: "Feed", feedURL: url, isDeleted: deleted, updatedAt: 1).save($0)
        }
        return id
    }
    @discardableResult
    private func article(_ feed: String, guid: String?, account: String? = nil, read: Bool = false,
                         starred: Bool = false, body: String? = nil, state: Bool = true) throws -> String {
        let id = UUID().uuidString
        try database.write {
            try ItemRecord(id: id, accountID: account ?? source, externalID: id, feedID: feed,
                           createdAt: 1, updatedAt: 1, sourceItemID: guid).save($0)
            try ArticleRecord(itemID: id, title: "RSS", contentHTML: body).save($0)
            if state {
                try ArticleStateRecord(itemID: id, isRead: read, isStarred: starred, dateArrived: 1, updatedAt: 1).save($0)
            }
        }
        return id
    }
    private func cachedState(_ kind: ICloudRecordKind, url: String, guid: String, value: Bool) throws {
        let parsed = URL(string: url)!
        let id = try ICloudSyncIdentity.articleRecordName(feedURL: parsed, sourceItemID: guid)!
        let record = try ICloudRecordEnvelope(kind: kind,
            recordName: kind.rawValue + "-v1:" + id.dropFirst("article-v1:".count),
            feedURL: ICloudSyncIdentity.canonicalFeedURL(parsed), sourceItemID: guid,
            fields: ["value": .init(value: .flag(value), version: .init(counter: 1, deviceID: device))])
        try cache(record)
    }
    private func cache(_ record: ICloudRecordEnvelope) throws {
        let json = String(data: try JSONEncoder().encode(record), encoding: .utf8)!
        try database.write {
            try $0.execute(sql: """
                INSERT INTO icloud_records(account_id, zone, record_name, envelope_json, needs_apply)
                VALUES (?, ?, ?, ?, 1);
                """, arguments: [cloud, record.zone.rawValue, record.recordName, json])
        }
    }
    private func durableRows() throws -> [Row] {
        try database.read { db in
            var rows: [Row] = []
            for table in ["accounts", "feeds", "folders", "feed_folders", "items", "articles", "article_states",
                          "icloud_sync_scope", "icloud_sync_changes", "icloud_content_changes", "icloud_records", "icloud_record_mappings"] {
                rows += try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            return rows
        }
    }

    func testPreviewNeedsNoCloudAccountOrEntitlementAndPreservesSourceData() async throws {
        let f = try feed()
        try article(f, guid: "guid", read: true, starred: true, body: "<p>RSS</p>")
        try article(f, guid: nil, starred: true)
        let before = try durableRows()
        let result = try await preview()
        XCTAssertEqual(result.targetStatus, .notCreated)
        XCTAssertEqual(result.feeds, 1)
        XCTAssertEqual(result.articles, 2)
        XCTAssertEqual(result.readArticles, 1)
        XCTAssertEqual(result.starredArticles, 2)
        XCTAssertEqual(result.missingIdentities, 1)
        XCTAssertEqual(result.starredMissingIdentities, 1)
        XCTAssertEqual(result.articlesWithStableUniqueIdentity, 1)
        XCTAssertEqual(result.starredWithRSSBodyAndStableIdentity, 1)
        XCTAssertEqual(try durableRows(), before)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_scope") }, 0)
    }

    func testDeletedForeignParentAndOtherAccountRowsAreExcluded() async throws {
        try database.write {
            try AccountRecord(id: "other-local", type: "local", displayName: "Other", createdAt: 1, updatedAt: 1).save($0)
        }
        let live = try feed(), deleted = try feed(deleted: true), other = try feed(account: "other-local")
        try article(live, guid: "live")
        try article(deleted, guid: nil, starred: true)
        try article(other, guid: nil, account: "other-local", starred: true)
        try article(other, guid: nil, starred: true)
        let result = try await preview()
        XCTAssertEqual(result.feeds, 1)
        XCTAssertEqual(result.articles, 1)
        XCTAssertEqual(result.missingIdentities, 0)
    }

    func testWhitespaceGUIDsRemainMissingAndOpaqueGUIDSpacingIsPreserved() async throws {
        let f = try feed()
        for guid in [nil, " \t\n", "\u{00A0}"] as [String?] { try article(f, guid: guid, starred: true) }
        try article(f, guid: "opaque", starred: true)
        try article(f, guid: " opaque ", starred: true)
        let result = try await preview()
        XCTAssertEqual(result.missingIdentities, 3)
        XCTAssertEqual(result.starredMissingIdentities, 3)
        XCTAssertEqual(result.articlesWithStableUniqueIdentity, 2)
        XCTAssertEqual(result.duplicateArticleIdentityGroups, 0)
    }

    func testCanonicalFeedAliasesAndDuplicateArticleIdentitiesRequireReview() async throws {
        let first = try feed("https://example.com/rss#first")
        let alias = try feed("HTTPS://EXAMPLE.COM:443/rss#second")
        try article(first, guid: "same", starred: true)
        try article(alias, guid: "same", starred: true)
        try article(alias, guid: "different", starred: true)
        let separate = try feed("https://different.example/rss")
        try article(separate, guid: "same", starred: true)
        let result = try await preview()
        XCTAssertEqual(result.duplicateFeedIdentityGroups, 1)
        XCTAssertEqual(result.duplicateArticleIdentityGroups, 1)
        XCTAssertEqual(result.articlesWithStableUniqueIdentity, 1)
        XCTAssertEqual(result.starredWithStableUniqueIdentity, 1)
        XCTAssertEqual(result.feedLinksWithFragment, 2)
    }

    func testCredentialsAndQueryOrderRemainDistinctAndURLsAreNotRewrittenOrExposed() async throws {
        let urls = ["https://user:password@example.com/rss?token=private#hidden",
                    "https://example.com/rss?a=1&b=2", "https://example.com/rss?b=2&a=1",
                    "https://example.com/private-token/rss", "file:///private/rss"]
        for url in urls { _ = try feed(url) }
        let before = try durableRows()
        let result = try await preview()
        XCTAssertEqual(result.flaggedFeedLinks, 4)
        XCTAssertEqual(result.feedLinksWithCredentials, 1)
        XCTAssertEqual(result.feedLinksWithQuery, 3)
        XCTAssertEqual(result.feedLinksWithFragment, 1)
        XCTAssertEqual(result.unverifiableFeedLinks, 1)
        XCTAssertEqual(result.duplicateFeedIdentityGroups, 0)
        XCTAssertEqual(try durableRows(), before)
        let description = String(reflecting: result)
        for secret in ["https://", "password", "token=private", "private-token"] { XCTAssertFalse(description.contains(secret)) }
    }

    func testMissingStatesAndInvalidFeedDoNotCountAsStablePortableHistory() async throws {
        let normal = try feed(), invalid = try feed("not-a-web-url")
        try article(normal, guid: "without-state", state: false)
        try article(invalid, guid: "guid", starred: true)
        let result = try await preview()
        XCTAssertEqual(result.articles, 2)
        XCTAssertEqual(result.missingReadingStates, 1)
        XCTAssertEqual(result.unverifiableFeedLinks, 1)
        XCTAssertEqual(result.missingIdentities, 0)
        XCTAssertEqual(result.articlesWithStableUniqueIdentity, 0)
    }

    func testFolderDuplicatesMultipleMembershipsAndTargetNameOverlapAreCountedWithoutMerging() async throws {
        _ = try addCloud()
        let f = try feed()
        try database.write {
            for id in ["folder-1", "folder-2"] {
                try FolderRecord(id: id, accountID: source, name: "Private Folder", updatedAt: 1).save($0)
                try FeedFolderRecord(feedID: f, folderID: id).save($0)
            }
            try FolderRecord(id: "target-folder", accountID: cloud, name: "Private Folder", updatedAt: 1).save($0)
            try FolderRecord(id: "deleted-folder", accountID: source, name: "Deleted", isDeleted: true, updatedAt: 1).save($0)
        }
        let before = try durableRows()
        let result = try await preview()
        XCTAssertEqual(result.folders, 2)
        XCTAssertEqual(result.folderRelationships, 2)
        XCTAssertEqual(result.feedsInMultipleFolders, 1)
        XCTAssertEqual(result.duplicateFolderNameGroups, 1)
        XCTAssertEqual(result.folderNamesAlreadyInTarget, 1)
        XCTAssertEqual(try durableRows(), before)
        XCTAssertFalse(String(reflecting: result).contains("Private Folder"))
    }

    func testTargetCachedStatesWithoutLocalArticlesReportDisagreements() async throws {
        _ = try addCloud()
        let f = try feed()
        try article(f, guid: "old-guid", read: true, starred: false)
        try cachedState(.read, url: "https://example.com/rss", guid: "old-guid", value: false)
        try cachedState(.starred, url: "https://example.com/rss", guid: "old-guid", value: true)
        let before = try durableRows()
        let result = try await preview()
        XCTAssertEqual(result.targetStatus, .notInitialized)
        XCTAssertEqual(result.targetFeeds, 0)
        XCTAssertEqual(result.articlesAlreadyObservedInTarget, 1)
        XCTAssertEqual(result.observedReadDisagreements, 1)
        XCTAssertEqual(result.observedStarDisagreements, 1)
        XCTAssertEqual(try durableRows(), before)
    }

    func testPreparedAndUnpreparedTargetFeedTombstonesRemainProtected() async throws {
        let repository = try addCloud()
        try repository.activate()
        let source1 = try feed("https://example.com/one"), source2 = try feed("https://example.com/two")
        try article(source1, guid: "one")
        try article(source2, guid: "two")
        _ = try feed("https://example.com/one", account: cloud, deleted: true)
        _ = try repository.outgoingRecords()
        // Physical deletion leaves the journal and prepared wire tombstone.
        try database.write { try $0.execute(sql: "DELETE FROM feeds WHERE account_id = ?", arguments: [cloud]) }
        _ = try feed("https://example.com/two", account: cloud, deleted: true)
        try database.write { try $0.execute(sql: "DELETE FROM feeds WHERE account_id = ?", arguments: [cloud]) }
        let before = try durableRows()
        let result = try await preview()
        XCTAssertEqual(result.targetFeeds, 0)
        XCTAssertEqual(result.feedsWithTargetDeletion, 2)
        XCTAssertEqual(result.feedsAlreadyObservedInTarget, 2)
        XCTAssertEqual(try durableRows(), before)
    }

    func testPendingIntegerStatesAreObservedBeforePreparation() async throws {
        let repository = try addCloud()
        try repository.activate()
        let f = try feed(), target = try feed(account: cloud)
        try article(f, guid: "shared", read: true, starred: false)
        try article(target, guid: "shared", account: cloud, read: false, starred: true)
        let result = try await preview()
        XCTAssertEqual(result.articlesAlreadyObservedInTarget, 1)
        XCTAssertEqual(result.observedReadDisagreements, 1)
        XCTAssertEqual(result.observedStarDisagreements, 1)
        XCTAssertEqual(result.targetEntriesRequiringReview, 0)
    }

    func testDisabledPausedAndBoundTargetsAreOnlyLocalStatusAndDoNotChangeCapture() async throws {
        let repository = try addCloud()
        try repository.activate()
        try repository.bindSystemUserFingerprint("private-user")
        try database.write {
            try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation = ? WHERE account_id = ?", arguments: [device, cloud])
            try $0.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id IN (?, ?)", arguments: [source, cloud])
        }
        var result = try await preview()
        XCTAssertFalse(result.sourceIsEnabled)
        XCTAssertEqual(result.targetStatus, .disabled)
        try database.write { try $0.execute(sql: "UPDATE accounts SET is_enabled = 1 WHERE id = ?", arguments: [cloud]) }
        result = try await preview()
        XCTAssertEqual(result.targetStatus, .locallyBound)
        try repository.pause(reason: "cloudResetReview")
        let before = try durableRows()
        result = try await preview()
        XCTAssertEqual(result.targetStatus, .requiresReview)
        XCTAssertEqual(try durableRows(), before)
        XCTAssertFalse(String(reflecting: result).contains("private-user"))
        XCTAssertFalse(String(reflecting: result).contains(device))
    }

    func testMalformedTargetMetadataIsReportedWithoutRepairOrReadingContentRecords() async throws {
        _ = try addCloud()
        try database.write {
            for (zone, name) in [(ICloudRecordZone.library, "feed-v1:invalid"),
                                 (.articles, "read-v1:invalid"), (.articles, "content-v1:private-body")] {
                try $0.execute(sql: "INSERT INTO icloud_records(account_id, zone, record_name, envelope_json) VALUES (?, ?, ?, '{}')",
                               arguments: [cloud, zone.rawValue, name])
            }
        }
        let before = try durableRows()
        let result = try await preview()
        XCTAssertEqual(result.targetEntriesRequiringReview, 2)
        XCTAssertEqual(try durableRows(), before)
        XCTAssertFalse(String(reflecting: result).contains("private-body"))
    }

    func testCloudServerAndMissingAccountsCannotBecomeMigrationSources() async throws {
        _ = try addCloud()
        try database.write {
            try AccountRecord(id: "server", type: "freshRSS", displayName: "Server", createdAt: 1, updatedAt: 1).save($0)
        }
        for id in [cloud, "server", "missing"] {
            do { _ = try await preview(id); XCTFail("Only local accounts can be migration sources") }
            catch ICloudMigrationPreviewError.unavailableSource { }
        }
    }
}
