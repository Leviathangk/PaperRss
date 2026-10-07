@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudRecordTests: XCTestCase {
    private var directories: [URL] = []
    private let feedURL = "https://example.com/rss"
    private let sourceID = "urn:entry:opaque"

    private struct Peer {
        let database: LibraryDatabase
        let repository: ICloudRecordRepository
        let account: String
    }

    override func tearDownWithError() throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories = []
    }

    private func peer() throws -> Peer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudRecordTests-\(UUID())")
        directories.append(directory)
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let account = UUID().uuidString
        try database.write { db in
            try AccountRecord(id: account, type: AccountType.iCloud.rawValue, displayName: "iCloud", createdAt: 1, updatedAt: 1).save(db)
        }
        let repository = ICloudRecordRepository(database: database, accountID: account)
        try repository.activate()
        return Peer(database: database, repository: repository, account: account)
    }

    private func article(_ peer: Peer, source: String? = "urn:entry:opaque", item: String = UUID().uuidString) throws -> String {
        try peer.database.write { db in
            let existing = try FeedRecord.filter(Column("account_id") == peer.account && Column("feed_url") == feedURL).fetchOne(db)
            let feed = existing?.id ?? UUID().uuidString
            if existing == nil {
                try FeedRecord(id: feed, accountID: peer.account, title: "Feed", feedURL: feedURL, updatedAt: 1).save(db)
            }
            try ItemRecord(id: item, accountID: peer.account, externalID: item, feedID: feed, createdAt: 1, updatedAt: 1, sourceItemID: source).save(db)
            try ArticleStateRecord(itemID: item, isRead: false, isStarred: false, dateArrived: 1, updatedAt: 1).save(db)
            return item
        }
    }

    private func state(_ peer: Peer, item: String) throws -> ArticleStateRecord {
        try peer.database.read { try XCTUnwrap(ArticleStateRecord.fetchOne($0, key: item)) }
    }

    private func mark(_ peer: Peer, item: String, read: Bool? = nil, starred: Bool? = nil) throws {
        try peer.database.write { db in
            let repository = ArticleStateRepository(database: peer.database)
            if let read { try repository.markRead(itemID: item, isRead: read, in: db) }
            if let starred { try repository.markStarred(itemID: item, isStarred: starred, in: db) }
        }
    }

    @discardableResult
    private func send(_ peer: Peer, to other: Peer? = nil) throws -> [ICloudPreparedRecord] {
        let sent = try peer.repository.outgoingRecords()
        let received = sent.map { ICloudReceivedRecord(envelope: $0.envelope, systemFields: nil) }
        if let other { try other.repository.receive(received) }
        for (snapshot, server) in zip(sent, received) { try peer.repository.confirm(snapshot, server: server) }
        return sent
    }

    func testIndependentAccountsAndSourceIDsConvergeAcrossDifferentLocalUUIDs() throws {
        let a = try peer(), b = try peer()
        let itemA = try article(a)
        try send(a, to: b)
        let itemB = try article(b)
        try b.repository.reconcileInbox()
        try mark(a, item: itemA, read: true)
        try mark(b, item: itemB, starred: true)
        let left = try a.repository.outgoingRecords(), right = try b.repository.outgoingRecords()
        try a.repository.receive(right.map { .init(envelope: $0.envelope, systemFields: nil) })
        try b.repository.receive(left.map { .init(envelope: $0.envelope, systemFields: nil) })
        XCTAssertTrue(try state(a, item: itemA).isRead)
        XCTAssertTrue(try state(b, item: itemB).isRead)
        XCTAssertTrue(try state(a, item: itemA).isStarred)
        XCTAssertTrue(try state(b, item: itemB).isStarred)
        XCTAssertNotEqual(itemA, itemB)
        XCTAssertEqual(try a.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM article_state_outbox") }, 0)
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM article_state_outbox") }, 0)
    }

    func testRestoreBeforeRSSPersistsInboxAndDefaultFalseCannotEraseRemoteTrue() throws {
        let a = try peer(), b = try peer()
        let itemA = try article(a)
        try mark(a, item: itemA, read: true, starred: true)
        try send(a, to: b)
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
        let itemB = try article(b)
        let bootstrap = try b.repository.outgoingRecords().filter { $0.envelope.zone == .articles }
        XCTAssertTrue(bootstrap.allSatisfy { $0.envelope.fields["value"]?.value == .flag(true) })
        try b.repository.reconcileInbox()
        XCTAssertTrue(try state(b, item: itemB).isRead)
        XCTAssertTrue(try state(b, item: itemB).isStarred)
        try b.repository.activate()
        try send(b)
        XCTAssertEqual(try b.repository.pendingCount(), 0)
    }

    func testUserFalseAfterRestoreHasPriorityOverBootstrapAndPropagates() throws {
        let a = try peer(), b = try peer()
        let itemA = try article(a)
        try mark(a, item: itemA, read: true)
        try send(a, to: b)
        let itemB = try article(b)
        try b.repository.reconcileInbox()
        try mark(b, item: itemB, read: false)
        let edit = try XCTUnwrap(b.repository.outgoingRecords().first { $0.envelope.kind == .read })
        XCTAssertGreaterThan(edit.envelope.fields["value"]!.version.counter, 0)
        XCTAssertEqual(edit.envelope.fields["value"]!.value, .flag(false))
        try send(b, to: a)
        XCTAssertFalse(try state(a, item: itemA).isRead)
    }

    func testPendingUserStateWinsAnOlderIncomingStateBeforeAnyPrepareCall() throws {
        let a = try peer(), b = try peer()
        let itemA = try article(a)
        let old = try send(a, to: b)
        let itemB = try article(b)
        try b.repository.reconcileInbox()
        try mark(b, item: itemB, read: true)
        try b.repository.receive(old.map { .init(envelope: $0.envelope, systemFields: nil) })
        XCTAssertTrue(try state(b, item: itemB).isRead)
        XCTAssertFalse(try state(a, item: itemA).isRead)
        XCTAssertTrue(try b.repository.outgoingRecords().contains { $0.envelope.kind == .read && $0.envelope.fields["value"]?.value == .flag(true) })
    }

    func testLateConfirmationDoesNotClearASecondEdit() throws {
        let a = try peer()
        let item = try article(a)
        try send(a)
        try mark(a, item: item, read: true)
        let old = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.kind == .read })
        try mark(a, item: item, read: false)
        try a.repository.confirm(old, server: .init(envelope: old.envelope, systemFields: Data([1])))
        let newer = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.kind == .read })
        XCTAssertGreaterThan(newer.envelope.fields["value"]!.version.counter, old.envelope.fields["value"]!.version.counter)
        XCTAssertEqual(newer.envelope.fields["value"]!.value, .flag(false))
        XCTAssertEqual(try a.repository.pendingCount(), 1)
    }

    func testOnlyConfirmedSuccessesLeaveQueueAndFailuresSurviveReopen() throws {
        let a = try peer()
        _ = try article(a)
        let pending = try a.repository.outgoingRecords()
        let first = try XCTUnwrap(pending.first)
        try a.repository.confirm(first, server: .init(envelope: first.envelope, systemFields: nil))
        let reopened = try LibraryDatabase(databaseURL: URL(fileURLWithPath: a.database.databasePath))
        let restarted = ICloudRecordRepository(database: reopened, accountID: a.account)
        XCTAssertEqual(try restarted.outgoingRecords().count, pending.count - 1)
        XCTAssertGreaterThan(try restarted.pendingCount(), 0)
    }

    func testRemotePageValidationFailureRollsBackRecordsBusinessAndCheckpoint() throws {
        let a = try peer(), b = try peer()
        _ = try article(a)
        let valid = try a.repository.outgoingRecords()
        var invalid = try XCTUnwrap(valid.first).envelope
        invalid.fields["api_key"] = .init(value: .text("must-never-apply"), version: .bootstrap)
        try b.repository.persistEngineState(Data([8]))
        XCTAssertThrowsError(try b.repository.receive(valid.map { .init(envelope: $0.envelope, systemFields: nil) } +
            [.init(envelope: invalid, systemFields: nil)], checkpoint: Data([9])))
        XCTAssertEqual(try b.repository.engineState(), Data([8]))
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 0)
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_records") }, 0)
        XCTAssertEqual(try b.database.read { try Bool.fetchOne($0, sql: "SELECT suppress_capture FROM icloud_sync_scope") }, false)
    }

    func testFieldVersionsAdvanceOnlyForChangedStructureFields() throws {
        let a = try peer()
        _ = try article(a)
        let baseline = try XCTUnwrap(send(a).first { $0.envelope.kind == .feed })
        try a.database.write { try $0.execute(sql: "UPDATE feeds SET title = 'Renamed' WHERE account_id = ?", arguments: [a.account]) }
        let renamed = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.kind == .feed })
        XCTAssertGreaterThan(renamed.envelope.fields["title"]!.version, baseline.envelope.fields["title"]!.version)
        XCTAssertEqual(renamed.envelope.fields["sort_order"]!.version, baseline.envelope.fields["sort_order"]!.version)
        XCTAssertEqual(renamed.envelope.fields["site_url"]!.version, baseline.envelope.fields["site_url"]!.version)
    }

    func testConcurrentDifferentStructureFieldsAreMerged() throws {
        let a = try peer(), b = try peer()
        _ = try article(a)
        try send(a, to: b)
        try a.database.write { try $0.execute(sql: "UPDATE feeds SET title = 'Custom title' WHERE account_id = ?", arguments: [a.account]) }
        try b.database.write { try $0.execute(sql: "UPDATE feeds SET sort_order = 90 WHERE account_id = ?", arguments: [b.account]) }
        let left = try a.repository.outgoingRecords(), right = try b.repository.outgoingRecords()
        try a.repository.receive(right.map { .init(envelope: $0.envelope, systemFields: nil) })
        try b.repository.receive(left.map { .init(envelope: $0.envelope, systemFields: nil) })
        for peer in [a, b] {
            let feed = try peer.database.read { try XCTUnwrap(FeedRecord.fetchOne($0, sql: "SELECT * FROM feeds WHERE account_id = ?", arguments: [peer.account])) }
            XCTAssertEqual(feed.title, "Custom title")
            XCTAssertEqual(feed.sortOrder, 90)
        }
    }

    func testDeterministicConcurrentSameFieldConflictAndCausalNextEdit() throws {
        let a = try peer(), b = try peer()
        _ = try article(a)
        try send(a, to: b)
        try a.database.write { try $0.execute(sql: "UPDATE feeds SET title = 'A' WHERE account_id = ?", arguments: [a.account]) }
        try b.database.write { try $0.execute(sql: "UPDATE feeds SET title = 'B' WHERE account_id = ?", arguments: [b.account]) }
        let left = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.kind == .feed })
        let right = try XCTUnwrap(b.repository.outgoingRecords().first { $0.envelope.kind == .feed })
        let expected = try left.envelope.merged(with: right.envelope)
        XCTAssertEqual(expected, try right.envelope.merged(with: left.envelope))
        try a.repository.receive([.init(envelope: right.envelope, systemFields: nil)])
        try b.repository.receive([.init(envelope: left.envelope, systemFields: nil)])
        try b.database.write { try $0.execute(sql: "UPDATE feeds SET title = 'After observation' WHERE account_id = ?", arguments: [b.account]) }
        let later = try XCTUnwrap(b.repository.outgoingRecords().first { $0.envelope.kind == .feed })
        XCTAssertGreaterThan(later.envelope.fields["title"]!.version.counter, expected.fields["title"]!.version.counter)
        try send(b, to: a)
        XCTAssertEqual(try a.database.read { try String.fetchOne($0, sql: "SELECT title FROM feeds WHERE account_id = ?", arguments: [a.account]) }, "After observation")
    }

    func testFolderRenameKeepsCloudIdentityAndMembershipAndPropagates() throws {
        let a = try peer(), b = try peer()
        _ = try article(a)
        let feeds = FeedRepository(database: a.database)
        try a.database.write { db in
            let feed = try XCTUnwrap(FeedRecord.fetchOne(db, sql: "SELECT * FROM feeds WHERE account_id = ?", arguments: [a.account]))
            try feeds.setFeedFolder(feedID: feed.id, folderName: "News", accountID: a.account, in: db)
        }
        let initial = try send(a, to: b)
        let old = try XCTUnwrap(initial.first { $0.envelope.kind == .folder })
        let localID = try a.database.read { try String.fetchOne($0, sql: "SELECT id FROM folders WHERE account_id = ?", arguments: [a.account]) }
        try a.database.write { try feeds.renameFolder(oldName: "News", newName: "Reading", accountID: a.account, in: $0) }
        let renamed = try send(a, to: b)
        XCTAssertEqual(renamed.filter { $0.envelope.kind == .folder }.map(\.envelope.recordName), [old.envelope.recordName])
        XCTAssertEqual(try a.database.read { try String.fetchOne($0, sql: "SELECT id FROM folders WHERE account_id = ?", arguments: [a.account]) }, localID)
        XCTAssertEqual(try b.database.read { try String.fetchOne($0, sql: "SELECT name FROM folders WHERE account_id = ?", arguments: [b.account]) }, "Reading")
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feed_folders") }, 1)
    }

    func testMembershipBeforeParentsIsRetainedAndLaterApplied() throws {
        let a = try peer(), b = try peer()
        _ = try article(a)
        try a.database.write { db in
            let feed = try XCTUnwrap(FeedRecord.fetchOne(db, sql: "SELECT * FROM feeds WHERE account_id = ?", arguments: [a.account]))
            try FeedRepository(database: a.database).setFeedFolder(feedID: feed.id, folderName: "News", accountID: a.account, in: db)
        }
        let outgoing = try a.repository.outgoingRecords()
        let relation = outgoing.filter { $0.envelope.kind == .membership }
        try b.repository.receive(relation.map { .init(envelope: $0.envelope, systemFields: nil) }, checkpoint: Data([1]))
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feed_folders") }, 0)
        try b.repository.receive(outgoing.filter { $0.envelope.kind != .membership }.map { .init(envelope: $0.envelope, systemFields: nil) })
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feed_folders") }, 1)
        XCTAssertEqual(try b.repository.engineState(), Data([1]))
    }

    func testTombstoneSurvivesPhysicalDeleteAndStaleRecordCannotReviveFeed() throws {
        let a = try peer(), b = try peer()
        _ = try article(a)
        let old = try send(a, to: b)
        try a.database.write { try $0.execute(sql: "DELETE FROM feeds WHERE account_id = ?", arguments: [a.account]) }
        let deleted = try send(a, to: b)
        XCTAssertTrue(deleted.contains { $0.envelope.kind == .feed && $0.envelope.fields["deleted"]?.value == .flag(true) })
        try b.repository.receive(old.map { .init(envelope: $0.envelope, systemFields: nil) })
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 0)
        XCTAssertEqual(try b.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
    }

    func testBaselineAfterReceiveDoesNotEchoStructureOrStates() throws {
        let a = try peer(), b = try peer()
        _ = try article(a)
        try send(a, to: b)
        try b.repository.activate()
        XCTAssertTrue(try b.repository.outgoingRecords().isEmpty)
        XCTAssertEqual(try b.repository.pendingCount(), 0)
    }

    func testUnrecoverableHistoryDoesNotBlockPortableStateAndDoesNotGuessGUID() throws {
        let a = try peer()
        _ = try article(a, source: nil, item: "legacy")
        let portable = try article(a)
        try mark(a, item: "legacy", starred: true)
        try mark(a, item: portable, read: true)
        let outgoing = try a.repository.outgoingRecords(limit: 2)
        XCTAssertFalse(outgoing.isEmpty)
        XCTAssertFalse(outgoing.contains { $0.envelope.sourceItemID == "legacy" })
        try send(a)
        XCTAssertEqual(try a.repository.pendingCount(), 2) // legacy read + star stay local
    }

    func testSystemAccountChangePausesWithoutDiscardingOrRebindingLocalData() throws {
        let a = try peer()
        _ = try article(a)
        try a.repository.bindSystemUserFingerprint("opaque-hash-A")
        XCTAssertThrowsError(try a.repository.bindSystemUserFingerprint("opaque-hash-B")) {
            XCTAssertEqual($0 as? ICloudRecordError, .accountChanged)
        }
        XCTAssertThrowsError(try a.repository.outgoingRecords()) {
            XCTAssertEqual($0 as? ICloudRecordError, .recoveryRequired)
        }
        XCTAssertEqual(try a.database.read { try String.fetchOne($0, sql: "SELECT user_fingerprint FROM icloud_sync_scope") }, "opaque-hash-A")
        XCTAssertEqual(try a.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 1)
        XCTAssertGreaterThan(try a.repository.pendingCount(), 0)
    }

    func testSingleICloudAccountConstraintAndReaderCapabilityBoundary() throws {
        let a = try peer()
        XCTAssertThrowsError(try a.database.write {
            try AccountRecord(id: "second", type: "iCloud", displayName: "Second", createdAt: 1, updatedAt: 1).save($0)
        })
        XCTAssertTrue(AccountType.iCloud.fetchesRSSDirectly)
        XCTAssertFalse(AccountType.iCloud.syncsRemoteArticleStates)
        XCTAssertNil(AccountType.iCloud.readerVariant)
    }

    func testLocalAccountCannotStartProductionWireScope() throws {
        let a = try peer()
        try a.database.write {
            try AccountRecord(id: "local", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save($0)
        }
        let repository = ICloudRecordRepository(database: a.database, accountID: "local")
        XCTAssertThrowsError(try repository.activate()) {
            XCTAssertEqual($0 as? ICloudSyncRepositoryError, .unsupportedAccount)
        }
    }

    func testCloudKitCodecUsesWhitelistedEnvelopeAndPreservesRecordIdentity() throws {
        let a = try peer()
        _ = try article(a)
        for value in try a.repository.outgoingRecords() {
            let record = try ICloudRecordCodec.encode(value.envelope, systemFields: nil)
            XCTAssertEqual(Set(record.allKeys()), ["envelope"])
            XCTAssertEqual(try ICloudRecordCodec.decode(record), value.envelope)
            let restored = try ICloudRecordCodec.encode(value.envelope, systemFields: ICloudRecordCodec.systemFields(record))
            XCTAssertEqual(restored.recordID, record.recordID)
            XCTAssertThrowsError(try ICloudRecordCodec.encode(value.envelope, systemFields: Data([0, 1, 2])))
        }
    }

    func testCloudKitCodecRejectsWrongZoneRecordNameAndSchema() throws {
        let a = try peer()
        _ = try article(a)
        let snapshot = try XCTUnwrap(a.repository.outgoingRecords().first)
        let wrong = CKRecord(recordType: ICloudRecordCodec.recordType, recordID: CKRecord.ID(recordName: "wrong", zoneID: ICloudRecordCodec.zoneID(snapshot.envelope.zone)))
        wrong["envelope"] = try JSONEncoder().encode(snapshot.envelope) as NSData
        XCTAssertThrowsError(try ICloudRecordCodec.decode(wrong))
        let valid = try ICloudRecordCodec.encode(snapshot.envelope, systemFields: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.envelope)) as? [String: Any])
        json["schemaVersion"] = 99
        valid["envelope"] = try JSONSerialization.data(withJSONObject: json) as NSData
        XCTAssertThrowsError(try ICloudRecordCodec.decode(valid)) {
            XCTAssertEqual($0 as? ICloudRecordError, .unsupportedVersion)
        }
    }

    func testUnentitledDriverRejectsBeforeAnyContainerInitialization() async throws {
        guard !ICloudSyncEngineDriver.isEntitled else { throw XCTSkip("Entitled test runner") }
        let a = try peer()
        let driver = ICloudSyncEngineDriver(repository: a.repository)
        do {
            try await driver.synchronize()
            XCTFail("Must reject before CKContainer")
        } catch {
            XCTAssertEqual(error as? ICloudEngineError, .notEntitled)
        }
        XCTAssertNil(try a.repository.engineState())
    }

    func testScopedBatchCanSelectArticleWithoutLibraryRecordsStarvingIt() throws {
        let a = try peer()
        _ = try article(a)
        let all = try a.repository.outgoingRecords()
        let star = try XCTUnwrap(all.first { $0.envelope.kind == .starred })
        let scoped = try a.repository.outgoingRecords(limit: 1, recordNames: [star.envelope.recordName])
        XCTAssertEqual(scoped.map(\.envelope.recordName), [star.envelope.recordName])
        XCTAssertTrue(try a.repository.outgoingRecords(recordNames: []).isEmpty)
    }

    func testStatusExpiryRemovesCleanInboxAndKeepsPendingIntentAndReaderState() throws {
        let a = try peer()
        let item = try article(a)
        let initial = try send(a)
        let read = try XCTUnwrap(initial.first { $0.envelope.kind == .read })
        try a.repository.discardServerMetadata(recordName: read.envelope.recordName, zone: .articles)
        XCTAssertFalse(try state(a, item: item).isRead)
        try mark(a, item: item, read: true)
        let pending = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.kind == .read })
        try a.repository.discardServerMetadata(recordName: pending.envelope.recordName, zone: .articles)
        XCTAssertTrue(try state(a, item: item).isRead)
        XCTAssertEqual(try a.repository.pendingCount(), 1)
        let retained = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.kind == .read })
        XCTAssertNil(retained.systemFields)
        XCTAssertEqual(retained.envelope.fields["value"]?.value, .flag(true))
        XCTAssertThrowsError(try a.repository.discardServerMetadata(recordName: initial[0].envelope.recordName, zone: .library))
    }

    func testInboxReappliesStateAfterLocalItemCacheIsDeletedAndRefetchedWithNewID() throws {
        let a = try peer(), b = try peer()
        let oldItem = try article(a)
        try mark(a, item: oldItem, read: true, starred: true)
        try send(a, to: b)
        let first = try article(b)
        try b.repository.reconcileInbox()
        try b.database.write { _ = try ItemRecord.deleteOne($0, key: first) }
        let replacement = try article(b)
        XCTAssertNotEqual(first, replacement)
        try b.repository.reconcileInbox()
        XCTAssertTrue(try state(b, item: replacement).isRead)
        XCTAssertTrue(try state(b, item: replacement).isStarred)
        XCTAssertEqual(try b.repository.pendingCount(), 0)
    }

    func testV14UpgradePreservesPendingJournalAndLocalIdentityWithoutActivatingCloudAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudV14-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v14-icloud-sync-journal")
        let feed = UUID().uuidString
        try pool.write { db in
            try AccountRecord(id: "local", type: "local", displayName: "Existing", createdAt: 1, updatedAt: 1).save(db)
            try db.execute(sql: "INSERT INTO icloud_sync_scope(account_id, capture_enabled) VALUES ('local', 1)")
            try FeedRecord(id: feed, accountID: "local", title: "Existing", feedURL: feedURL, updatedAt: 1).save(db)
            try ItemRecord(id: "old-local-ID", accountID: "local", externalID: "old-local-ID", feedID: feed, createdAt: 1, updatedAt: 1, sourceItemID: sourceID).save(db)
            try ArticleStateRecord(itemID: "old-local-ID", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).save(db)
        }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertEqual(try AccountRecord.fetchOne(db, key: "local")?.type, "local")
            XCTAssertEqual(try ItemRecord.fetchOne(db, key: "old-local-ID")?.sourceItemID, sourceID)
            XCTAssertTrue(try XCTUnwrap(ArticleStateRecord.fetchOne(db, key: "old-local-ID")).isStarred)
            let rows = try Row.fetchAll(db, sql: "SELECT field_versions_json FROM icloud_sync_changes WHERE is_pending = 1")
            XCTAssertEqual(rows.count, 3)
            for row in rows {
                let versions = try JSONDecoder().decode([String: ICloudFieldVersion].self, from: Data((row["field_versions_json"] as String).utf8))
                XCTAssertFalse(versions.isEmpty)
                XCTAssertTrue(versions.values.allSatisfy { $0.counter > 0 && UUID(uuidString: $0.deviceID) != nil })
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts WHERE type = 'iCloud'"), 0)
        }
    }

    func testSameLogicalCounterUsesDeviceTieBreakAndRejectsReusedVersionWithDifferentValue() throws {
        let a = try peer()
        _ = try article(a)
        var left = try XCTUnwrap(a.repository.outgoingRecords().first { $0.envelope.kind == .feed }).envelope
        var right = left
        let versionA = ICloudFieldVersion(counter: 42, deviceID: "00000000-0000-0000-0000-000000000001")
        let versionB = ICloudFieldVersion(counter: 42, deviceID: "00000000-0000-0000-0000-000000000002")
        left.fields["title"] = .init(value: .text("A"), version: versionA)
        right.fields["title"] = .init(value: .text("B"), version: versionB)
        XCTAssertEqual(try left.merged(with: right), try right.merged(with: left))
        XCTAssertEqual(try left.merged(with: right).fields["title"]?.value, .text("B"))
        right.fields["title"] = .init(value: .text("Corrupt"), version: versionA)
        XCTAssertThrowsError(try left.merged(with: right)) {
            XCTAssertEqual($0 as? ICloudRecordError, .malformedRecord)
        }
    }
}
