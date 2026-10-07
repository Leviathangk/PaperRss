import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudAccountStatusTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var repository: ICloudRecordRepository!
    private let account = "cloud-status"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudStatus-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write {
            try AccountRecord(id: account, type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0)
        }
        repository = ICloudRecordRepository(database: database, accountID: account)
        try repository.activate()
    }

    override func tearDownWithError() throws {
        repository = nil
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func article(source: String?, starred: Bool = false) throws -> String {
        try database.write { db in
            let existing = try FeedRecord.filter(Column("account_id") == account).fetchOne(db)
            let feed = existing?.id ?? UUID().uuidString
            if existing == nil {
                try FeedRecord(id: feed, accountID: account, title: "Feed", feedURL: "https://example.com/rss", updatedAt: 1).save(db)
            }
            let item = UUID().uuidString
            try ItemRecord(id: item, accountID: account, externalID: item, feedID: feed, createdAt: 1, updatedAt: 1, sourceItemID: source).save(db)
            try ArticleRecord(itemID: item, title: "RSS", contentHTML: "<p>RSS</p>").save(db)
            try ArticleStateRecord(itemID: item, isRead: false, isStarred: starred, dateArrived: 1, updatedAt: 1).save(db)
            return item
        }
    }

    func testSnapshotDeduplicatesPreparedRecordsAndReadingDoesNotAdvanceClockOrCheckpoint() async throws {
        try article(source: "opaque-guid", starred: true)
        let outgoing = try repository.outgoingRecords()
        try repository.persistEngineState(Data([1, 2, 3]))
        let clock = try database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }
        let first = try await repository.accountSnapshot()
        let second = try await repository.accountSnapshot()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pendingChanges, outgoing.count)
        XCTAssertEqual(first.missingArticleIdentities, 0)
        XCTAssertEqual(try database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }, clock)
        XCTAssertEqual(try repository.engineState(), Data([1, 2, 3]))
        for value in outgoing {
            try repository.confirm(value, server: .init(envelope: value.envelope, systemFields: nil, bodyData: value.bodyData))
        }
        let confirmed = try await repository.accountSnapshot()
        XCTAssertEqual(confirmed.pendingChanges, 0)
    }

    func testMissingIdentitiesCountArticlesOnceAndRemainSeparateFromPortableChanges() async throws {
        try article(source: nil, starred: true)
        try article(source: "  ", starred: true)
        try article(source: "real-guid", starred: true)
        let outgoing = try repository.outgoingRecords()
        let snapshot = try await repository.accountSnapshot()
        XCTAssertEqual(snapshot.missingArticleIdentities, 2)
        XCTAssertEqual(snapshot.pendingChanges, outgoing.count)
        XCTAssertEqual(snapshot.deferredBodies, 0)
    }

    func testMaintenanceProtectsConfirmedLocalStarsAndUnpreparedChangesWithoutWriting() async throws {
        let item = try article(source: "protected", starred: true)
        for value in try repository.outgoingRecords() {
            try repository.confirm(value, server: .init(envelope: value.envelope, systemFields: nil, bodyData: value.bodyData))
        }
        let before = try database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }
        let confirmed = try await repository.maintenanceProtection()
        XCTAssertFalse(confirmed.hasUnresolvedChanges)
        XCTAssertTrue(confirmed.recordNames.contains(where: { $0.hasPrefix("read-v1:") }))
        try database.write {
            try ArticleStateRepository(database: self.database).markRead(itemID: item, isRead: true, in: $0)
        }
        let changedClock = try database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }
        XCTAssertNotEqual(before, changedClock)
        let pending = try await repository.maintenanceProtection()
        XCTAssertFalse(pending.recordNames.isEmpty)
        XCTAssertEqual(try database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }, changedClock)
    }

    func testMaintenanceHoldsForUnconfirmedSettingsMissingIdentitiesAndPausedScope() async throws {
        let initial = try await repository.maintenanceProtection()
        XCTAssertTrue(initial.hasUnresolvedChanges)
        for value in try repository.outgoingRecords() {
            try repository.confirm(value, server: .init(envelope: value.envelope, systemFields: nil, bodyData: value.bodyData))
        }
        _ = try article(source: nil, starred: true)
        let historical = try await repository.maintenanceProtection()
        XCTAssertTrue(historical.hasUnresolvedChanges)
        try repository.pause(reason: "accountChanged")
        do {
            _ = try await repository.maintenanceProtection()
            XCTFail("Paused accounts must not generate cleanup candidates")
        } catch { XCTAssertEqual(error as? ICloudRecordError, .recoveryRequired) }
    }

    func testUnpreparedFeedIntentProtectsCloudChildrenBeforeMappingExists() async throws {
        for value in try repository.outgoingRecords() {
            try repository.confirm(value, server: .init(envelope: value.envelope, systemFields: nil, bodyData: value.bodyData))
        }
        try database.write {
            try FeedRecord(id: UUID().uuidString, accountID: self.account,
                title: "Pending", feedURL: "https://example.com/rss", updatedAt: 1).save($0)
        }
        let mappings = try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_record_mappings WHERE kind = 'feed'")
        }
        XCTAssertEqual(mappings, 0)
        let protection = try await repository.maintenanceProtection()
        XCTAssertFalse(protection.hasUnresolvedChanges)
        let name = try ICloudSyncIdentity.feedRecordName(feedURL: URL(string: "https://example.com/rss")!)
        XCTAssertTrue(protection.recordNames.contains(name))
    }

    func testDeferredContentAndCanceledUnreadBodiesDoNotInflatePendingCount() async throws {
        let item = try article(source: "body-guid", starred: true)
        try database.write {
            try $0.execute(sql: "UPDATE icloud_content_changes SET deferred_reason = 'contentTooLarge' WHERE item_id = ?", arguments: [item])
        }
        let deferredOutgoing = try repository.outgoingRecords()
        let deferred = try await repository.accountSnapshot()
        XCTAssertEqual(deferred.deferredBodies, 1)
        XCTAssertEqual(deferred.pendingChanges, deferredOutgoing.count)
        try database.write {
            try $0.execute(sql: "UPDATE article_states SET is_starred = 0 WHERE item_id = ?", arguments: [item])
        }
        let disabled = try await repository.accountSnapshot()
        XCTAssertEqual(disabled.deferredBodies, 0)
        try await repository.setSyncUnreadContentAsync(true)
        _ = try repository.outgoingRecords()
        try await repository.setSyncUnreadContentAsync(false)
        let canceled = try await repository.accountSnapshot()
        let outgoing = try repository.outgoingRecords()
        XCTAssertEqual(canceled.pendingChanges, outgoing.count)
        XCTAssertFalse(outgoing.contains { $0.envelope.kind == .content })
    }

    func testInboxBeforeParentAndPauseRemainVisibleWithoutSending() async throws {
        let url = URL(string: "https://missing.example/rss")!
        let identity = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: "missing-guid"))
        let state = try ICloudRecordEnvelope(kind: .starred, recordName: "starred-v1:" + identity.dropFirst("article-v1:".count),
            feedURL: ICloudSyncIdentity.canonicalFeedURL(url), sourceItemID: "missing-guid",
            fields: ["value": .init(value: .flag(true), version: .init(counter: 10, deviceID: UUID().uuidString))])
        try repository.receive([.init(envelope: state, systemFields: nil)])
        try repository.pause(reason: "accountChanged")
        let snapshot = try await repository.accountSnapshot()
        XCTAssertTrue(snapshot.isPaused)
        XCTAssertEqual(snapshot.waitingArticleStates, 1)
        XCTAssertEqual(snapshot.waitingRelationships, 0)
        XCTAssertEqual(snapshot.waitingBodies, 0)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
    }

    func testUnreadOptionSurvivesReopenAndLocalAccountCannotUseCloudSettings() async throws {
        try await repository.setSyncUnreadContentAsync(true)
        let reopened = try LibraryDatabase(databaseURL: URL(fileURLWithPath: database.databasePath))
        let persisted = try await ICloudRecordRepository(database: reopened, accountID: account).accountSnapshot()
        XCTAssertTrue(persisted.syncUnreadContent)
        let local = ICloudRecordRepository(database: database, accountID: "local-default")
        do {
            try await local.setSyncUnreadContentAsync(true)
            XCTFail("Local account must not acquire an iCloud scope")
        } catch { }
        XCTAssertEqual(try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_scope WHERE account_id = 'local-default'")
        }, 0)
    }
}
