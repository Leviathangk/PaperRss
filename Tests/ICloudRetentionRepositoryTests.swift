@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudRetentionRepositoryTests: XCTestCase {
    private let generation = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let feedURL = "https://example.com/rss"
    private let source = "urn:fixture:opaque-entry"
    private var directories: [URL] = []

    private struct Peer: Sendable {
        let database: LibraryDatabase
        let repository: ICloudRecordRepository
        let url: URL
    }

    private struct Metadata: ICloudResidueMetadataReading {
        let root: ICloudCloudRoot
        func metadata(for context: ICloudResidueContext) async throws -> ICloudResidueMetadata {
            .init(root: .found(root, changeTag: "fixture-tag"),
                  zones: try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: root.generation) },
                  hasLegacySnapshot: false)
        }
    }

    override func tearDownWithError() throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }

    private func peer(version: Int = 3) async throws -> Peer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionRepository-\(UUID())")
        directories.append(directory)
        let url = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: url)
        try database.write {
            try AccountRecord(id: "cloud", type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0)
        }
        let repository = ICloudRecordRepository(database: database, accountID: "cloud")
        try repository.activate()
        try await repository.acceptCloudRoot(.init(generation: generation, phase: .ready, protocolVersion: version))
        return .init(database: database, repository: repository, url: url)
    }

    private func name(_ kind: ICloudRecordKind) throws -> String {
        let identity = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: URL(string: feedURL)!, sourceItemID: source))
        return "\(kind.rawValue)-v1:" + identity.dropFirst("article-v1:".count)
    }

    private func state(_ kind: ICloudRecordKind, value: Bool, counter: Int64 = 10) throws -> ICloudRecordEnvelope {
        try .init(kind: kind, recordName: name(kind), feedURL: feedURL, sourceItemID: source,
                  fields: ["value": .init(value: .flag(value), version: .init(counter: counter, deviceID: counter == 0 ? "" : device))])
    }

    private func body(counter: Int64 = 10, title: String = "Cloud body") throws -> ICloudReceivedRecord {
        let body = try ICloudArticleContentCodec.encode(.init(ArticleRecord(itemID: "portable-only", title: title, contentHTML: "<p>Original RSS</p>")))
        let envelope = try ICloudRecordEnvelope(kind: .content, recordName: name(.content), feedURL: feedURL, sourceItemID: source,
            fields: ["payload_hash": .init(value: .text(ICloudArticleContentCodec.hash(body)), version: .init(counter: counter, deviceID: device))])
        return .init(envelope: envelope, systemFields: nil, bodyData: body)
    }

    private func fence(retiring: [ICloudRecordEnvelope] = []) throws -> ICloudRecordEnvelope {
        try ICloudRetentionFence(generation: generation, article: state(.read, value: false))
            .retiring(retiring).envelope()
    }

    private func feed() throws -> ICloudRecordEnvelope {
        try .init(kind: .feed, recordName: ICloudSyncIdentity.feedRecordName(feedURL: URL(string: feedURL)!), feedURL: feedURL,
                  fields: ["feed_url": .init(value: .text(feedURL), version: .bootstrap),
                           "title": .init(value: .text("Feed"), version: .bootstrap),
                           "site_url": .init(value: .null, version: .bootstrap),
                           "sort_order": .init(value: .integer(0), version: .bootstrap),
                           "deleted": .init(value: .flag(false), version: .bootstrap)])
    }

    private func receive(_ peer: Peer, _ envelopes: [ICloudRecordEnvelope], checkpoint: Data? = nil) throws {
        try peer.repository.receive(envelopes.map { .init(envelope: $0, systemFields: nil) }, checkpoint: checkpoint)
    }

    @discardableResult
    private func seed(_ peer: Peer, read: Bool = false, starred: Bool = false) throws -> String {
        try peer.database.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture = 1")
            try FeedRecord(id: "local-feed", accountID: "cloud", title: "Local feed", feedURL: feedURL, updatedAt: 1).save(db)
            try ItemRecord(id: "local-item", accountID: "cloud", externalID: "local-item", feedID: "local-feed", createdAt: 1, updatedAt: 1, sourceItemID: source).save(db)
            try ArticleRecord(itemID: "local-item", title: "Local body", summary: "Local summary", contentHTML: "<p>Local original</p>", contentUpdatedAt: 1).save(db)
            try ArticleStateRecord(itemID: "local-item", isRead: read, isStarred: starred, dateArrived: 1, updatedAt: 1).save(db)
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture = 0")
            return "local-item"
        }
    }

    private func mark(_ peer: Peer, read: Bool? = nil, starred: Bool? = nil) throws {
        try peer.database.write { db in
            let states = ArticleStateRepository(database: peer.database)
            if let read { try states.markRead(itemID: "local-item", isRead: read, in: db) }
            if let starred { try states.markStarred(itemID: "local-item", isStarred: starred, in: db) }
        }
    }

    private func localState(_ peer: Peer) throws -> ArticleStateRecord {
        try peer.database.read { try XCTUnwrap(ArticleStateRecord.fetchOne($0, key: "local-item")) }
    }

    private func cached(_ peer: Peer, _ kind: ICloudRecordKind) throws -> ICloudPreparedRecord? {
        try peer.database.read { try peer.repository.cached(name(kind), zone: .articles, in: $0) }
    }

    private func group(_ envelopes: [ICloudRecordEnvelope]) -> ICloudRecordSaveGroup {
        .init(records: envelopes.map { .init(envelope: $0, systemFields: nil, origins: [], isPending: true) })
    }

    func testHashOnlyWireRoundTripsWithEpochIdentityAndNoAssets() throws {
        let envelope = try fence(retiring: [state(.read, value: true), body().envelope])
        let record = try ICloudRecordCodec.encode(envelope, systemFields: nil, generation: generation)
        XCTAssertEqual(record.recordID.zoneID, try ICloudGenerationZone.id(.articles, generation: generation))
        XCTAssertEqual(Set(record.allKeys()), ["envelope"])
        XCTAssertEqual(try ICloudRecordCodec.received(record, generation: generation).envelope, envelope)
        let payload = String(decoding: try XCTUnwrap(record["envelope"] as? Data), as: UTF8.self)
        for secret in [feedURL, source, "Local body", "Cloud body", "portable-only"] { XCTAssertFalse(payload.contains(secret)) }
        XCTAssertNil(envelope.feedURL); XCTAssertNil(envelope.sourceItemID)
        XCTAssertEqual(try ICloudRetentionFence(envelope: envelope, generation: generation).envelope(), envelope)
        XCTAssertThrowsError(try ICloudRecordCodec.decode(record, generation: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
    }

    func testWireWhitelistRejectsNestedOrTopLevelPrivateFieldsAndOversize() throws {
        let envelope = try fence()
        let original = try JSONEncoder().encode(envelope)
        for location in ["top", "field", "version", "value"] {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            if location == "top" { root["guid"] = source }
            else {
                var fields = root["fields"] as! [String: Any]
                var field = fields["read_floor"] as! [String: Any]
                if location == "field" { field["private"] = source }
                else {
                    var nested = field[location] as! [String: Any]
                    nested["private"] = source; field[location] = nested
                }
                fields["read_floor"] = field; root["fields"] = fields
            }
            let record = try ICloudRecordCodec.encode(envelope, systemFields: nil, generation: generation)
            record["envelope"] = try JSONSerialization.data(withJSONObject: root) as NSData
            XCTAssertThrowsError(try ICloudRecordCodec.decode(record, generation: generation), location)
        }
        XCTAssertThrowsError(try ICloudRetentionFence.validateWireData(Data(repeating: 32, count: 2_049)))
        var invalid = envelope
        invalid.fields["read_floor"] = .init(value: .flag(false), version: .init(counter: 1, deviceID: device))
        XCTAssertThrowsError(try invalid.validate())
    }

    func testUnsetAndRetiredBootstrapFloorsMergeMonotonicallyInBothDirections() throws {
        let empty = try fence()
        let retired = try fence(retiring: [state(.read, value: false, counter: 0)])
        XCTAssertEqual(try empty.merged(with: retired), retired)
        XCTAssertEqual(try retired.merged(with: empty), retired)
        let newer = try fence(retiring: [state(.read, value: true, counter: 100)])
        XCTAssertEqual(try newer.merged(with: retired), newer)
        XCTAssertEqual(try retired.merged(with: newer), newer)
    }

    func testProtocolBindingPersistsAndSameGenerationCannotUpgradeOrDowngrade() async throws {
        let guarded = try await peer()
        let reopened = try LibraryDatabase(databaseURL: guarded.url)
        XCTAssertTrue(try ICloudRecordRepository(database: reopened, accountID: "cloud").usesRetentionProtocol())
        do {
            try await guarded.repository.acceptCloudRoot(.init(generation: generation, phase: .ready))
            XCTFail("Same physical generation cannot change writer contract")
        } catch { XCTAssertEqual(error as? ICloudRootError, .unsupportedVersion) }
        XCTAssertEqual(try guarded.database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }, "invalidCloudRoot")
        XCTAssertEqual(try guarded.database.read { try Int.fetchOne($0, sql: "SELECT cloud_protocol_version FROM icloud_sync_scope") }, 3)
        let legacy = try await peer(version: 2)
        do {
            try await legacy.repository.acceptCloudRoot(.init(generation: generation, phase: .ready, protocolVersion: 3))
            XCTFail("Legacy writers must be isolated in another generation")
        } catch { XCTAssertEqual(error as? ICloudRootError, .unsupportedVersion) }
        XCTAssertEqual(try legacy.database.read { try Int.fetchOne($0, sql: "SELECT cloud_protocol_version FROM icloud_sync_scope") }, 2)
    }

    func testLegacyProtocolRejectsFenceWithoutAdvancingCheckpointOrInbox() async throws {
        let peer = try await peer(version: 2)
        try peer.repository.persistEngineState(Data([1]))
        XCTAssertThrowsError(try receive(peer, [fence()], checkpoint: Data([2]))) {
            XCTAssertEqual($0 as? ICloudRetentionError, .unsupportedProtocol)
        }
        XCTAssertEqual(try peer.database.read { try Data.fetchOne($0, sql: "SELECT engine_state FROM icloud_sync_scope") }, Data([1]))
        XCTAssertEqual(try peer.database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }, "invalidCloudRoot")
        XCTAssertEqual(try peer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_records") }, 0)
    }

    func testArticlePageWaitsForFenceAndReplaysAfterLaterVerifiedFence() async throws {
        let peer = try await peer()
        try seed(peer)
        try receive(peer, [state(.read, value: true)], checkpoint: Data([1]))
        XCTAssertFalse(try localState(peer).isRead)
        XCTAssertEqual(try peer.repository.engineState(), Data([1]))
        try receive(peer, [fence()], checkpoint: Data([2]))
        XCTAssertTrue(try localState(peer).isRead)
        XCTAssertEqual(try peer.repository.engineState(), Data([2]))
    }

    func testUnorderedRetiredPageCannotMaterializeOldStarOrBodyOnNewDevice() async throws {
        let peer = try await peer()
        let read = try state(.read, value: true), star = try state(.starred, value: true), body = try body()
        try peer.repository.receive([body, .init(envelope: star, systemFields: nil),
            .init(envelope: feed(), systemFields: nil), .init(envelope: read, systemFields: nil),
            .init(envelope: fence(retiring: [read, star, body.envelope]), systemFields: nil)])
        XCTAssertEqual(try peer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
        XCTAssertEqual(try peer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM articles") }, 0)
        XCTAssertFalse(try XCTUnwrap(cached(peer, .starred)).isPending)
        try peer.repository.reconcileInbox()
        XCTAssertEqual(try peer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
    }

    func testNewerStarAndBodyRestoreWhileRetiredReadCannotOverwriteThem() async throws {
        let peer = try await peer()
        let read = try state(.read, value: true), oldStar = try state(.starred, value: false), oldBody = try body()
        try peer.repository.receive([body(counter: 12, title: "New body"),
            .init(envelope: state(.starred, value: true, counter: 11), systemFields: nil),
            .init(envelope: read, systemFields: nil), .init(envelope: feed(), systemFields: nil),
            .init(envelope: fence(retiring: [read, oldStar, oldBody.envelope]), systemFields: nil)])
        let restored = try peer.database.read { try XCTUnwrap(ArticleRecord.fetchOne($0)) }
        XCTAssertEqual(restored.title, "New body")
        let flags = try peer.database.read { try XCTUnwrap(ArticleStateRecord.fetchOne($0)) }
        XCTAssertTrue(flags.isStarred); XCTAssertFalse(flags.isRead)
    }

    func testRetirementKeepsLocalReaderHistoryAndDoesNotResendAcknowledgedCache() async throws {
        let peer = try await peer()
        try seed(peer)
        let read = try state(.read, value: true)
        try receive(peer, [read, fence()])
        let before = try localState(peer)
        let article = try peer.database.read { try ArticleRecord.fetchOne($0, key: "local-item") }
        try receive(peer, [fence(retiring: [read])])
        XCTAssertEqual(try localState(peer), before)
        XCTAssertEqual(try peer.database.read { try ArticleRecord.fetchOne($0, key: "local-item") }, article)
        XCTAssertFalse(try peer.repository.outgoingRecords().contains { $0.envelope.kind == .read })
        try peer.repository.activate()
        try peer.repository.reconcileInbox()
        XCTAssertEqual(try localState(peer), before)
        XCTAssertFalse(try peer.repository.outgoingRecords().contains { $0.envelope.kind == .read })
    }

    func testOfflineStarRebasesAndLateOldReceiptCannotAcknowledgeNewVersion() async throws {
        let peer = try await peer()
        try seed(peer)
        try receive(peer, [fence()])
        try mark(peer, starred: true)
        let old = try XCTUnwrap(peer.repository.outgoingRecords().first { $0.envelope.kind == .starred })
        let expired = try state(.starred, value: false, counter: 100)
        try receive(peer, [fence(retiring: [expired])])
        let new = try XCTUnwrap(peer.repository.outgoingRecords().first { $0.envelope.kind == .starred })
        XCTAssertGreaterThan(new.envelope.fields["value"]!.version.counter, 100)
        XCTAssertEqual(new.envelope.fields["value"]!.value, .flag(true))
        try peer.repository.confirm(old, server: .init(envelope: old.envelope, systemFields: nil))
        XCTAssertEqual(try peer.repository.outgoingRecords().first { $0.envelope.kind == .starred }?.envelope, new.envelope)
        XCTAssertEqual(try peer.repository.pendingCount(), 1)
        let reopened = try LibraryDatabase(databaseURL: peer.url)
        XCTAssertEqual(try ICloudRecordRepository(database: reopened, accountID: "cloud").outgoingRecords().first { $0.envelope.kind == .starred }?.envelope, new.envelope)
    }

    func testExplicitFalseIntentSurvivesRetiredTrueValue() async throws {
        let peer = try await peer()
        try seed(peer)
        try receive(peer, [state(.read, value: true), fence()])
        try mark(peer, read: false)
        try receive(peer, [fence(retiring: [state(.read, value: true, counter: 100)])])
        let change = try XCTUnwrap(peer.repository.outgoingRecords().first { $0.envelope.kind == .read })
        XCTAssertEqual(change.envelope.fields["value"]?.value, .flag(false))
        XCTAssertGreaterThan(change.envelope.fields["value"]!.version.counter, 100)
        XCTAssertFalse(try localState(peer).isRead)
    }

    func testRetiredBootstrapDoesNotTurnDefaultStateIntoNewUserIntent() async throws {
        let peer = try await peer()
        try seed(peer)
        try peer.repository.activate()
        try receive(peer, [fence(retiring: [state(.read, value: false, counter: 0), state(.starred, value: false, counter: 0)])])
        XCTAssertFalse(try peer.repository.outgoingRecords().contains { $0.envelope.kind == .read || $0.envelope.kind == .starred })
        XCTAssertFalse(try localState(peer).isRead); XCTAssertFalse(try localState(peer).isStarred)
    }

    func testPendingBodyRebasesWithNewStarAndOldBodyReceiptPreservesPending() async throws {
        let peer = try await peer()
        try seed(peer)
        try receive(peer, [fence()])
        try mark(peer, starred: true)
        let old = try XCTUnwrap(peer.repository.outgoingRecords().first { $0.envelope.kind == .content })
        try receive(peer, [fence(retiring: [state(.starred, value: false, counter: 100), body(counter: 100).envelope])])
        let new = try XCTUnwrap(peer.repository.outgoingRecords().first { $0.envelope.kind == .content })
        XCTAssertGreaterThan(new.envelope.fields["payload_hash"]!.version.counter, 100)
        XCTAssertEqual(new.bodyData, old.bodyData)
        try peer.repository.confirm(old, server: .init(envelope: old.envelope, systemFields: nil, bodyData: old.bodyData))
        XCTAssertEqual(try peer.repository.outgoingRecords().first { $0.envelope.kind == .content }?.envelope, new.envelope)
        XCTAssertEqual(try peer.database.read { try Bool.fetchOne($0, sql: "SELECT is_pending FROM icloud_content_changes WHERE item_id = 'local-item'") }, true)
    }

    func testAcknowledgedOldStarCannotAutomaticallyReuploadRetiredBody() async throws {
        let peer = try await peer()
        try seed(peer)
        try receive(peer, [fence()])
        try mark(peer, starred: true)
        for sent in try peer.repository.outgoingRecords() {
            try peer.repository.confirm(sent, server: .init(envelope: sent.envelope, systemFields: nil, bodyData: sent.bodyData))
        }
        let star = try XCTUnwrap(cached(peer, .starred)), body = try XCTUnwrap(cached(peer, .content))
        let before = try peer.database.read { try ArticleRecord.fetchOne($0, key: "local-item") }
        try receive(peer, [fence(retiring: [star.envelope, body.envelope])])
        try peer.repository.discardServerMetadata(recordName: body.envelope.recordName, zone: .articles)
        try peer.repository.reconcileInbox()
        XCTAssertTrue(try localState(peer).isStarred)
        XCTAssertEqual(try peer.database.read { try ArticleRecord.fetchOne($0, key: "local-item") }, before)
        XCTAssertFalse(try peer.repository.outgoingRecords().contains { $0.envelope.kind == .content || $0.envelope.kind == .starred })
        try mark(peer, starred: false)
        try mark(peer, starred: true)
        XCTAssertTrue(try peer.repository.outgoingRecords().contains { $0.envelope.kind == .content })
    }

    func testValidNewRemoteStarRequeuesBodyEvenWhenOldLocalFlagWasAlreadyTrue() async throws {
        let peer = try await peer()
        try seed(peer)
        try receive(peer, [fence()])
        try mark(peer, starred: true)
        for sent in try peer.repository.outgoingRecords() {
            try peer.repository.confirm(sent, server: .init(envelope: sent.envelope, systemFields: nil, bodyData: sent.bodyData))
        }
        let star = try XCTUnwrap(cached(peer, .starred)), body = try XCTUnwrap(cached(peer, .content))
        try receive(peer, [fence(retiring: [star.envelope, body.envelope])])
        try receive(peer, [state(.starred, value: true, counter: 200)])
        let renewed = try XCTUnwrap(peer.repository.outgoingRecords().first { $0.envelope.kind == .content })
        XCTAssertGreaterThan(renewed.envelope.fields["payload_hash"]!.version, body.envelope.fields["payload_hash"]!.version)
        XCTAssertEqual(renewed.bodyData, body.bodyData)
    }

    func testFenceIdentityMismatchRollsBackAllRowsClockAndCheckpoint() async throws {
        let peer = try await peer()
        try seed(peer)
        try receive(peer, [fence()], checkpoint: Data([1]))
        let clock = try peer.database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }
        let before = try localState(peer)
        let fields = try fence(retiring: [state(.read, value: true, counter: 100)]).fields
        let invalid = try ICloudRecordEnvelope(kind: .retention, recordName: fence().recordName,
            feedRecordName: "feed-v1:" + String(repeating: "c", count: 64), fields: fields)
        XCTAssertThrowsError(try receive(peer, [invalid, state(.read, value: true)], checkpoint: Data([2])))
        XCTAssertEqual(try localState(peer), before)
        XCTAssertEqual(try peer.repository.engineState(), Data([1]))
        XCTAssertEqual(try peer.database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }, clock)
        XCTAssertEqual(try peer.database.read { try Bool.fetchOne($0, sql: "SELECT suppress_capture FROM icloud_sync_scope") }, false)
    }

    func testOverflowCannotCommitFenceOrConsumePendingUserIntent() async throws {
        let peer = try await peer()
        try seed(peer)
        try receive(peer, [fence()], checkpoint: Data([1]))
        try mark(peer, read: true)
        let old = try XCTUnwrap(peer.repository.outgoingRecords().first { $0.envelope.kind == .read })
        XCTAssertThrowsError(try receive(peer, [fence(retiring: [state(.read, value: true, counter: .max)])], checkpoint: Data([2]))) {
            XCTAssertEqual($0 as? ICloudRetentionError, .clockOverflow)
        }
        XCTAssertEqual(try peer.repository.engineState(), Data([1]))
        XCTAssertEqual(try peer.repository.outgoingRecords().first { $0.envelope.kind == .read }, old)
        XCTAssertEqual(try peer.repository.pendingCount(), 1)
    }

    func testMissingFencePausesWithoutErasingHistoryOrFloor() async throws {
        let peer = try await peer()
        try seed(peer, read: true, starred: true)
        let marker = try fence(retiring: [state(.read, value: true)])
        try receive(peer, [marker])
        let before = try localState(peer)
        XCTAssertThrowsError(try peer.repository.discardServerMetadata(recordName: marker.recordName, zone: .articles))
        XCTAssertEqual(try peer.database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }, "retentionFenceMissing")
        XCTAssertEqual(try localState(peer), before)
        XCTAssertEqual(try peer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_records WHERE record_name LIKE 'retention-v1:%'") }, 1)
    }

    func testClockCannotBecomeSQLiteRealWhenNativeCaptureOverflows() async throws {
        let peer = try await peer()
        try seed(peer)
        try peer.database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET logical_clock = ?", arguments: [Int64.max]) }
        let before = try localState(peer)
        XCTAssertThrowsError(try mark(peer, read: true))
        XCTAssertEqual(try localState(peer), before)
        XCTAssertEqual(try peer.database.read { try String.fetchOne($0, sql: "SELECT typeof(logical_clock) FROM icloud_sync_scope") }, "integer")
        XCTAssertEqual(try peer.repository.pendingCount(), 0)
    }

    func testGuardedRootCodecRoundTripKeepsVersionAndRejectsFractionalVersions() throws {
        let root = ICloudCloudRoot(generation: generation, phase: .ready, protocolVersion: 3)
        let record = try ICloudCloudRootCodec.encode(root)
        XCTAssertEqual(try ICloudCloudRootCodec.decode(record), root)
        XCTAssertEqual(record["schemaVersion"] as? Int, 3)
        record["schemaVersion"] = 3.5 as NSNumber
        XCTAssertThrowsError(try ICloudCloudRootCodec.decode(record))
        XCTAssertThrowsError(try ICloudCloudRootCodec.encode(.init(generation: generation, phase: .ready, protocolVersion: 4)))
    }

    func testWriterGroupsAllArticleKindsWithOneGuardWithoutSpeculativePersistence() async throws {
        let peer = try await peer()
        try seed(peer)
        try peer.repository.activate()
        try mark(peer, starred: true)
        let groups = try peer.repository.outgoingRecordGroups()
        let article = try XCTUnwrap(groups.first { $0.records.contains { $0.envelope.kind == .content } })
        XCTAssertEqual(Set(article.records.map(\.envelope.kind)), [.retention, .read, .starred, .content])
        XCTAssertEqual(article.records.filter { $0.envelope.kind == .retention }.count, 1)
        let guardRecord = try XCTUnwrap(article.records.first { $0.envelope.kind == .retention })
        XCTAssertNil(guardRecord.systemFields)
        XCTAssertEqual(try peer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_records WHERE record_name LIKE 'retention-v1:%'") }, 0)
        let batch = try ICloudSaveBatchPlanner.select(groups, generation: generation, requiresArticleGuards: true)
        XCTAssertTrue(batch.atomicByZone)
        let sdk = CKSyncEngine.RecordZoneChangeBatch(recordsToSave: try batch.records.map {
            try ICloudRecordCodec.encode($0.envelope, systemFields: $0.systemFields, bodyData: $0.bodyData, generation: generation)
        }, atomicByZone: batch.atomicByZone)
        XCTAssertTrue(sdk.atomicByZone)
        XCTAssertTrue(sdk.recordIDsToDelete.isEmpty)
        XCTAssertEqual(sdk.recordsToSave.count, batch.records.count)
    }

    func testEachAtomicSaveStampsAChangedGuardWithoutChangingIdentityOrFloors() throws {
        let marker = try fence(retiring: [state(.read, value: true, counter: 1)])
        let read = try state(.read, value: false, counter: 2)
        let groups = [group([marker, read])]
        let first = try ICloudSaveBatchPlanner.select(groups, generation: generation, requiresArticleGuards: true)
        let second = try ICloudSaveBatchPlanner.select(groups, generation: generation, requiresArticleGuards: true)
        let a = try XCTUnwrap(first.records.first { $0.envelope.kind == .retention }).envelope
        let b = try XCTUnwrap(second.records.first { $0.envelope.kind == .retention }).envelope
        XCTAssertNotEqual(a.fields["writer_nonce"], b.fields["writer_nonce"])
        XCTAssertNotEqual(a.fields["writer_nonce"]?.value, .text(""))
        XCTAssertEqual(a.recordName, marker.recordName)
        XCTAssertEqual(a.feedRecordName, marker.feedRecordName)
        XCTAssertEqual(try ICloudRetentionFence(envelope: a, generation: generation), try ICloudRetentionFence(envelope: b, generation: generation))
        for key in ["read_floor", "starred_floor", "content_floor"] { XCTAssertEqual(a.fields[key], marker.fields[key]) }
        XCTAssertNoThrow(try ICloudRecordCodec.encode(a, systemFields: nil, generation: generation))
        var invalid = marker
        invalid.fields["writer_nonce"] = .init(value: .text(feedURL), version: .bootstrap)
        XCTAssertThrowsError(try invalid.validate())
    }

    func testScopeCountBytesAndInFlightLimitsCannotSplitGuardFromArticle() throws {
        let read = try state(.read, value: true), marker = try fence()
        let grouped = group([marker, read])
        let readID = try ICloudRecordCodec.recordID(read, generation: generation)
        let guardID = try ICloudRecordCodec.recordID(marker, generation: generation)
        for batch in [
            try ICloudSaveBatchPlanner.select([grouped], generation: generation, requiresArticleGuards: true, scope: .recordIDs([readID])),
            try ICloudSaveBatchPlanner.select([grouped], generation: generation, requiresArticleGuards: true, maximumRecords: 1),
            try ICloudSaveBatchPlanner.select([grouped], generation: generation, requiresArticleGuards: true, maximumBytes: 10),
            try ICloudSaveBatchPlanner.select([grouped], generation: generation, requiresArticleGuards: true, unavailable: [guardID])
        ] { XCTAssertTrue(batch.records.isEmpty) }
        let permitted = try ICloudSaveBatchPlanner.select([grouped], generation: generation, requiresArticleGuards: true,
                                                          scope: .recordIDs([readID, guardID]))
        XCTAssertEqual(permitted.records.count, 2)
        XCTAssertTrue(permitted.atomicByZone)
    }

    func testUnguardedMixedExpiredOrDuplicateArticleGroupsAreRejected() throws {
        let read = try state(.read, value: true), marker = try fence()
        let other = try ICloudRecordEnvelope(kind: .read,
            recordName: "read-v1:" + XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: URL(string: feedURL)!, sourceItemID: "another-entry")).dropFirst("article-v1:".count),
            feedURL: feedURL, sourceItemID: "another-entry", fields: read.fields)
        let invalidGroups = try [group([read]), group([marker, read, feed()]), group([marker, read, other]),
                                 group([marker, read, read]), group([fence(retiring: [read]), read])]
        for invalid in invalidGroups {
            XCTAssertThrowsError(try ICloudSaveBatchPlanner.select([invalid], generation: generation, requiresArticleGuards: true))
        }
        XCTAssertThrowsError(try ICloudSaveBatchPlanner.select([group([marker, read])], generation: generation, requiresArticleGuards: false))
        let legacy = try ICloudSaveBatchPlanner.select([group([read])], generation: generation, requiresArticleGuards: false)
        XCTAssertFalse(legacy.atomicByZone); XCTAssertEqual(legacy.records.count, 1)
    }

    func testSavedArticleWithoutGuardReceiptCannotAcknowledgeItsJournal() async throws {
        let peer = try await peer()
        try seed(peer)
        try mark(peer, read: true)
        let groups = try peer.repository.outgoingRecordGroups()
        let batch = try ICloudSaveBatchPlanner.select(groups, generation: generation, requiresArticleGuards: true)
        let pairs = try batch.records.map { (try ICloudRecordCodec.recordID($0.envelope, generation: generation), $0) }
        let inFlight = Dictionary(uniqueKeysWithValues: pairs)
        let readID = try ICloudRecordCodec.recordID(XCTUnwrap(batch.records.first { $0.envelope.kind == .read }).envelope, generation: generation)
        XCTAssertThrowsError(try ICloudSaveBatchPlanner.validateSavedReceipts([readID], inFlight: inFlight,
            generation: generation, requiresArticleGuards: true))
        XCTAssertEqual(try peer.repository.pendingCount(), 1)
        XCTAssertNoThrow(try ICloudSaveBatchPlanner.validateSavedReceipts(Set(inFlight.keys), inFlight: inFlight,
            generation: generation, requiresArticleGuards: true))
        for record in batch.records.sorted(by: { $0.envelope.kind == .retention && $1.envelope.kind != .retention }) {
            try peer.repository.confirm(record, server: .init(envelope: record.envelope, systemFields: nil, bodyData: record.bodyData))
        }
        XCTAssertEqual(try peer.repository.pendingCount(), 0)
    }

    func testGuardRemainsQueuedWhileArticlePendingAndBecomesInactiveAfterConfirmation() async throws {
        let peer = try await peer()
        try seed(peer)
        try mark(peer, read: true)
        let grouped = try XCTUnwrap(peer.repository.outgoingRecordGroups().first { $0.records.contains { $0.envelope.kind == .read } })
        let marker = try XCTUnwrap(grouped.records.first { $0.envelope.kind == .retention })
        XCTAssertFalse(try peer.repository.inactivePreparedRecordNames([marker.envelope.recordName]).contains(marker.envelope.recordName))
        for record in grouped.records {
            try peer.repository.confirm(record, server: .init(envelope: record.envelope, systemFields: nil, bodyData: record.bodyData))
        }
        XCTAssertTrue(try peer.repository.inactivePreparedRecordNames([marker.envelope.recordName]).contains(marker.envelope.recordName))
    }

    func testV20MigrationPreservesFrozenArchiveAndOnlyAddsLegacyProtocolBinding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionV20Migration-\(UUID())")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v20-icloud-readonly-local-archive")
        try pool.write { db in
            try AccountRecord(id: "old", type: "iCloud", displayName: "Old", createdAt: 1, updatedAt: 1).save(db)
            try db.execute(sql: "INSERT INTO icloud_sync_scope(account_id,capture_enabled,user_fingerprint,cloud_generation,engine_state,pause_reason) VALUES ('old',1,'fixture-user',?,?,'accountChanged')", arguments: [generation, Data([1, 3, 5])])
            try db.execute(sql: "UPDATE icloud_sync_scope SET capture_enabled=0,suppress_capture=1 WHERE account_id='old'")
            try db.execute(sql: "UPDATE accounts SET is_enabled=0,is_archived=1 WHERE id='old'")
        }
        let old = try pool.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM icloud_sync_scope")) }
        let account = try pool.read { try AccountRecord.fetchOne($0, key: "old") }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            let columns = old.columnNames.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ", ")
            XCTAssertEqual(try Row.fetchOne(db, sql: "SELECT \(columns) FROM icloud_sync_scope"), old)
            XCTAssertEqual(try AccountRecord.fetchOne(db, key: "old"), account)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT cloud_protocol_version FROM icloud_sync_scope"), 2)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
        }
        XCTAssertThrowsError(try pool.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_protocol_version=3 WHERE account_id='old'") })
    }

    func testSameAccountResumeVerifiesProtocolAndPreservesGuardedBinding() async throws {
        let peer = try await peer()
        try peer.repository.bindSystemUserFingerprint("fixture-user")
        try peer.repository.pause(reason: "accountChanged")
        let bad = Metadata(root: .init(generation: generation, phase: .ready))
        do {
            try await ICloudSameAccountResumeCoordinator(repository: peer.repository, transport: bad).resume()
            XCTFail("A protocol mismatch cannot release the pause")
        } catch { XCTAssertEqual(error as? ICloudSameAccountResumeError, .cloudNeedsReview) }
        XCTAssertEqual(try peer.database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }, "accountChanged")
        let good = Metadata(root: .init(generation: generation, phase: .ready, protocolVersion: 3))
        try await ICloudSameAccountResumeCoordinator(repository: peer.repository, transport: good).resume()
        XCTAssertTrue(try peer.repository.usesRetentionProtocol())
    }

    func testResidueReviewCannotCallSameGenerationProtocolMismatchReady() async throws {
        let peer = try await peer(version: 2)
        try peer.repository.bindSystemUserFingerprint("fixture-user")
        let metadata = Metadata(root: .init(generation: generation, phase: .ready, protocolVersion: 3))
        let review = try await ICloudCloudResidueScanner(repository: peer.repository, transport: metadata).scan()
        XCTAssertEqual(review.rootStatus, .incompatible)
        XCTAssertFalse(review.isComplete)
    }

    func testRecordLimitCountsCompanionGuardsAcrossManyArticles() throws {
        var groups: [ICloudRecordSaveGroup] = []
        for i in 0..<110 {
            let entry = "urn:fixture:\(i)"
            let identity = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: URL(string: feedURL)!, sourceItemID: entry))
            let read = try ICloudRecordEnvelope(kind: .read, recordName: "read-v1:" + identity.dropFirst("article-v1:".count),
                feedURL: feedURL, sourceItemID: entry, fields: ["value": .init(value: .flag(true), version: .bootstrap)])
            groups.append(group([try ICloudRetentionFence(generation: generation, article: read).envelope(), read]))
        }
        let batch = try ICloudSaveBatchPlanner.select(groups, generation: generation, requiresArticleGuards: true)
        XCTAssertEqual(batch.records.count, 150)
        XCTAssertEqual(batch.records.filter { $0.envelope.kind == .read }.count, 75)
        XCTAssertEqual(batch.records.filter { $0.envelope.kind == .retention }.count, 75)
        let sent = try Dictionary(uniqueKeysWithValues: batch.records.map { (try ICloudRecordCodec.recordID($0.envelope, generation: generation), $0) })
        XCTAssertNoThrow(try ICloudSaveBatchPlanner.validateSavedReceipts(Set(sent.keys), inFlight: sent,
            generation: generation, requiresArticleGuards: true))
    }

    func testSingleLargeAssetAllowanceStillIncludesGuardAndBlocksAdditionalGroups() throws {
        // Planning-only bytes; no SDK asset encoding or upload is performed.
        let bytes = Data(repeating: 1, count: ICloudArticleContentCodec.maximumCompressedBytes)
        let content = try ICloudRecordEnvelope(kind: .content, recordName: name(.content), feedURL: feedURL, sourceItemID: source,
            fields: ["payload_hash": .init(value: .text(ICloudArticleContentCodec.hash(bytes)), version: .init(counter: 10, deviceID: device))])
        let body = ICloudPreparedRecord(envelope: content, systemFields: nil, origins: [], isPending: true, bodyData: bytes)
        let small = try [fence(), state(.read, value: true), state(.starred, value: true)]
        let grouped = ICloudRecordSaveGroup(records: group(small).records + [body])
        let batch = try ICloudSaveBatchPlanner.select([grouped, group([feed()])], generation: generation, requiresArticleGuards: true)
        XCTAssertEqual(batch.records.count, 4)
        XCTAssertEqual(batch.records.filter { $0.envelope.kind == .retention }.count, 1)
        XCTAssertFalse(batch.records.contains { $0.envelope.kind == .feed })
    }
}
