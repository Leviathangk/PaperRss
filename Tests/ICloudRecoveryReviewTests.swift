import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudRecoveryReviewTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var repository: ICloudRecordRepository!
    private let account = "review-cloud"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudReview-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write {
            try AccountRecord(id: account, type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0)
            try AccountRecord(id: "local-default", type: AccountType.local.rawValue,
                              displayName: "Local", createdAt: 1, updatedAt: 1).save($0)
        }
        repository = ICloudRecordRepository(database: database, accountID: account)
    }

    override func tearDownWithError() throws {
        repository = nil; database = nil
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func feed(url: String = "https://example.com/rss", deleted: Bool = false,
                      accountID: String? = nil) throws -> String {
        let id = UUID().uuidString
        try database.write {
            try FeedRecord(id: id, accountID: accountID ?? account, title: "Feed", feedURL: url,
                           isDeleted: deleted, updatedAt: 1).save($0)
        }
        return id
    }

    private func article(feed: String, source: String?, read: Bool = false, starred: Bool = false,
                         body: String? = nil, summary: String = "", accountID: String? = nil) throws {
        try database.write {
            let id = UUID().uuidString
            try ItemRecord(id: id, accountID: accountID ?? account, externalID: id, feedID: feed,
                           createdAt: 1, updatedAt: 1, sourceItemID: source).save($0)
            try ArticleRecord(itemID: id, title: "RSS", summary: summary, contentHTML: body).save($0)
            try ArticleStateRecord(itemID: id, isRead: read, isStarred: starred, dateArrived: 1, updatedAt: 1).save($0)
        }
    }

    func testReviewWorksWithoutActivatingScopeOrConnectingToCloud() async throws {
        _ = try feed()
        let snapshot = try await repository.recoveryReview()
        XCTAssertEqual(snapshot.feeds, 1)
        XCTAssertTrue(snapshot.isEnabled)
        XCTAssertFalse(snapshot.hasSyncScope)
        XCTAssertFalse(snapshot.captureEnabled)
        XCTAssertEqual(snapshot.pause, .none)
        XCTAssertEqual(snapshot.resetProgress, .none)
        XCTAssertEqual(try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_scope")
        }, 0)
    }

    func testWhitespaceIdentityReviewMatchesActualPortableIdentityEligibility() async throws {
        let f = try feed()
        for guid in [" \t\n", "\u{00A0}"] {
            try article(feed: f, source: guid, starred: true)
            XCTAssertNil(try ICloudSyncIdentity.articleRecordName(feedURL: URL(string: "https://example.com/rss")!, sourceItemID: guid))
        }
        try article(feed: f, source: " opaque ", starred: true)
        let snapshot = try await repository.recoveryReview()
        XCTAssertEqual(snapshot.articles, 3)
        XCTAssertEqual(snapshot.missingIdentities, 2)
        XCTAssertEqual(snapshot.starredMissingIdentities, 2)
    }

    func testCountsOnlyCurrentAccountAndLiveParentsIncludingNonPendingHistory() async throws {
        let live = try feed(), deleted = try feed(deleted: true)
        try article(feed: live, source: "guid-1", read: true, starred: true, body: "<p>Body</p>")
        try article(feed: live, source: nil, starred: true, summary: "Summary")
        try article(feed: live, source: "  ", body: "  ")
        try article(feed: live, source: "guid-4")
        try article(feed: deleted, source: nil, read: true, starred: true, body: "Deleted")
        let local = try feed(accountID: "local-default")
        try article(feed: local, source: nil, starred: true, accountID: "local-default")
        // Foreign keys do not enforce matching item/feed account ownership.
        try article(feed: local, source: nil, starred: true)
        try database.write {
            try FolderRecord(id: "live-folder", accountID: account, name: "Live", updatedAt: 1).save($0)
            try FolderRecord(id: "deleted-folder", accountID: account, name: "Deleted", isDeleted: true, updatedAt: 1).save($0)
            try FolderRecord(id: "local-folder", accountID: "local-default", name: "Local", updatedAt: 1).save($0)
        }
        let snapshot = try await repository.recoveryReview()
        XCTAssertEqual(snapshot.feeds, 1)
        XCTAssertEqual(snapshot.folders, 1)
        XCTAssertEqual(snapshot.articles, 4)
        XCTAssertEqual(snapshot.readArticles, 1)
        XCTAssertEqual(snapshot.starredArticles, 2)
        XCTAssertEqual(snapshot.missingIdentities, 2)
        XCTAssertEqual(snapshot.starredMissingIdentities, 1)
        XCTAssertEqual(snapshot.articlesWithRSSBody, 2)
    }

    func testDisabledPausedAndCaptureOffReviewPreservesDurableSyncData() async throws {
        try repository.activate()
        let live = try feed(url: "https://user:password@example.com/rss?token=private")
        try article(feed: live, source: nil, starred: true, body: "RSS")
        try repository.persistEngineState(Data([1, 2, 3]))
        try database.write {
            try $0.execute(sql: """
                UPDATE accounts SET is_enabled = 0 WHERE id = ?;
                """, arguments: [account])
            try $0.execute(sql: """
                UPDATE icloud_sync_scope SET capture_enabled = 0, pause_reason = 'accountChanged',
                    cloud_generation = ?, user_fingerprint = 'private-user' WHERE account_id = ?;
                """, arguments: [UUID().uuidString, account])
        }
        let before = try durableState()
        let first = try await repository.recoveryReview()
        let second = try await repository.recoveryReview()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEnabled)
        XCTAssertTrue(first.hasSyncScope)
        XCTAssertFalse(first.captureEnabled)
        XCTAssertEqual(first.pause, .accountChanged)
        XCTAssertEqual(first.missingIdentities, 1)
        XCTAssertEqual(try durableState(), before)
        let publicDescription = String(reflecting: first)
        for secret in ["password", "private-user", "token=private", "https://"] {
            XCTAssertFalse(publicDescription.contains(secret))
        }
    }

    func testLinkRisksOverlapWithoutRewritingURLsOrReportingTheirValues() async throws {
        let urls = [
            "https://user:password@example.com/rss?token=private#hidden",
            "https://example.com/rss?sort=recent",
            "https://example.com/rss#section",
            "https://example.com/private-token-in-path/rss",
            "not-a-web-url", "https://example.com/%ZZ", "file:///private/rss"
        ]
        for url in urls { _ = try feed(url: url) }
        _ = try feed(url: "https://private:deleted@example.com/rss", deleted: true)
        let snapshot = try await repository.recoveryReview()
        XCTAssertEqual(snapshot.feeds, 7)
        XCTAssertEqual(snapshot.flaggedFeedLinks, 6)
        XCTAssertEqual(snapshot.feedLinksWithCredentials, 1)
        XCTAssertEqual(snapshot.feedLinksWithQuery, 2)
        XCTAssertEqual(snapshot.feedLinksWithFragment, 2)
        XCTAssertEqual(snapshot.unverifiableFeedLinks, 3)
        let retained = try database.read { try String.fetchAll($0, sql: "SELECT feed_url FROM feeds WHERE is_deleted = 0") }
        XCTAssertEqual(Set(retained), Set(urls))
        XCTAssertFalse(String(reflecting: snapshot).contains("private-token"))
    }

    func testEveryResetStageIsProjectedWithoutExposingApproval() async throws {
        try repository.activate()
        let approval = ICloudCloudResetApproval(operationID: UUID().uuidString,
            previousGeneration: UUID().uuidString, replacementGeneration: UUID().uuidString,
            systemFingerprint: "private-user")
        let expected: [ICloudRecoveryReview.ResetProgress] = [
            .prepared, .rootPublished, .libraryCreated, .articlesCreated,
            .libraryDeleted, .articlesDeleted, .cloudReady
        ]
        for (stage, progress) in zip(ICloudCloudResetOperation.Stage.allCases, expected) {
            var operation = ICloudCloudResetOperation(approval: approval)
            operation.stage = stage
            try database.write {
                try $0.execute(sql: """
                    UPDATE icloud_sync_scope SET cloud_reset_operation = ?, cloud_generation = ?,
                        user_fingerprint = ?, pause_reason = ? WHERE account_id = ?;
                    """, arguments: [try operation.serialized(), approval.previousGeneration,
                        approval.systemFingerprint, stage == .cloudReady ? "cloudResetReview" : "cloudResetRequested", account])
            }
            let before = try durableState()
            let snapshot = try await repository.recoveryReview()
            XCTAssertEqual(snapshot.resetProgress, progress)
            XCTAssertEqual(try durableState(), before)
            let publicDescription = String(reflecting: snapshot)
            for secret in [approval.operationID, approval.previousGeneration, approval.replacementGeneration, approval.systemFingerprint] {
                XCTAssertFalse(publicDescription.contains(secret))
            }
        }
    }

    func testDamagedMissingUnknownAndStaleApprovalOnlyRequestReview() async throws {
        try repository.activate()
        let approval = ICloudCloudResetApproval(operationID: UUID().uuidString,
            previousGeneration: UUID().uuidString, replacementGeneration: UUID().uuidString,
            systemFingerprint: "private-user")
        let data = try ICloudCloudResetOperation(approval: approval).serialized()
        for bad in [Data("private-invalid-json".utf8), Data(repeating: 0, count: 8193),
                    Data(#"{"schemaVersion":999}"#.utf8), data] {
            try database.write {
                try $0.execute(sql: """
                    UPDATE icloud_sync_scope SET cloud_reset_operation = ?, pause_reason = 'cloudResetRequested'
                    WHERE account_id = ?;
                    """, arguments: [bad, account])
            }
            let before = try durableState()
            let snapshot = try await repository.recoveryReview()
            XCTAssertEqual(snapshot.resetProgress, .needsReview)
            XCTAssertEqual(try durableState(), before)
            XCTAssertFalse(String(reflecting: snapshot).contains("private-"))
        }
        try database.write {
            try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_reset_operation = NULL WHERE account_id = ?", arguments: [account])
        }
        let missing = try await repository.recoveryReview()
        XCTAssertEqual(missing.resetProgress, .needsReview)
        try repository.pause(reason: "private-unknown-pause")
        let unknown = try await repository.recoveryReview()
        XCTAssertEqual(unknown.pause, .needsReview)
        XCTAssertFalse(unknown.pause.message?.contains("private-") == true)
    }

    func testLocalServerAndMissingAccountsCannotEnterCloudReview() async throws {
        try database.write {
            try AccountRecord(id: "server", type: "freshRSS", displayName: "Server", createdAt: 1, updatedAt: 1).save($0)
        }
        for id in ["local-default", "server", "missing"] {
            do {
                _ = try await ICloudRecordRepository(database: database, accountID: id).recoveryReview()
                XCTFail("Only iCloud accounts may enter recovery review")
            } catch ICloudRecordError.unavailableScope { }
        }
    }

    private func durableState() throws -> [Row] {
        try database.read { db in
            var rows = try Row.fetchAll(db, sql: "SELECT * FROM icloud_sync_scope ORDER BY account_id")
            for table in ["icloud_sync_changes", "icloud_content_changes", "icloud_records", "icloud_record_mappings",
                          "feeds", "folders", "items", "articles", "article_states"] {
                rows += try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            return rows
        }
    }
}
