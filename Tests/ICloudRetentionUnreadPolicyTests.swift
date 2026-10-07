@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudRetentionUnreadPolicyTests: XCTestCase {
    private let generation = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private var directories: [URL] = []

    private func peer(protocolVersion: Int = 3) async throws -> ICloudRecordRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionPolicy-\(UUID())")
        directories.append(directory)
        let db = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try db.write { try AccountRecord(id: "cloud", type: "iCloud", displayName: "Fixture", createdAt: 1, updatedAt: 1).save($0) }
        let repository = ICloudRecordRepository(database: db, accountID: "cloud")
        try repository.activate()
        try await repository.acceptCloudRoot(.init(generation: generation, phase: .ready, protocolVersion: protocolVersion))
        return repository
    }

    override func tearDownWithError() throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }

    private func version(_ counter: Int64) -> ICloudFieldVersion {
        .init(counter: counter, deviceID: counter == 0 ? "" : device)
    }

    private func record(_ repository: ICloudRecordRepository, kind: ICloudRecordKind) throws -> ICloudPreparedRecord? {
        try repository.outgoingRecordGroups().flatMap(\.records).first { $0.envelope.kind == kind }
    }

    private func confirm(_ repository: ICloudRecordRepository, _ record: ICloudPreparedRecord) throws {
        // Inert server receipt fixture, no container or database operation.
        try repository.confirm(record, server: .init(envelope: record.envelope, systemFields: nil))
    }

    private func cache(_ repository: ICloudRecordRepository) throws -> ICloudRetentionUnreadPolicy? {
        try repository.database.read { db in
            try repository.cached(ICloudRetentionUnreadPolicy.recordName, zone: .articles, in: db)
                .map { try ICloudRetentionUnreadPolicy(envelope: $0.envelope, generation: generation) }
        }
    }

    func testUnknownAndEqualVersionPoliciesKeepUnreadContentProtected() throws {
        XCTAssertFalse(try ICloudRetentionUnreadPolicy(generation: generation).allowsUnreadRemoval)
        XCTAssertTrue(try ICloudRetentionUnreadPolicy(generation: generation, releasedVersion: .bootstrap).allowsUnreadRemoval)
        let enabled = try ICloudRetentionUnreadPolicy(generation: generation, protectedVersion: version(10), releasedVersion: version(10))
        XCTAssertFalse(enabled.allowsUnreadRemoval)
        XCTAssertTrue(enabled.protects(version(10)))
        XCTAssertFalse(enabled.protects(version(11)))
    }

    func testOldReleaseAndEnableSnapshotsCannotRollBackMonotoneVersions() throws {
        let current = try ICloudRetentionUnreadPolicy(generation: generation, protectedVersion: version(20), releasedVersion: version(15)).envelope()
        let old = try ICloudRetentionUnreadPolicy(generation: generation, protectedVersion: version(10), releasedVersion: version(5)).envelope()
        XCTAssertEqual(try current.merged(with: old), current)
        let off = try ICloudRetentionUnreadPolicy(generation: generation, releasedVersion: version(21)).envelope()
        let merged = try ICloudRetentionUnreadPolicy(envelope: current.merged(with: off), generation: generation)
        XCTAssertTrue(merged.allowsUnreadRemoval)
        XCTAssertFalse(try ICloudRetentionUnreadPolicy(envelope: merged.envelope().merged(with: old), generation: generation).protects(version(10)))
    }

    func testPolicyWireHasStrictIdentityWhitelistAndNoBody() throws {
        let envelope = try ICloudRetentionUnreadPolicy(generation: generation, protectedVersion: version(3)).envelope()
        let record = try ICloudRecordCodec.encode(envelope, systemFields: nil, generation: generation)
        XCTAssertEqual(Set(record.allKeys()), ["envelope"])
        XCTAssertEqual(try ICloudRecordCodec.decode(record, generation: generation), envelope)
        XCTAssertEqual(record.recordID.zoneID, try ICloudGenerationZone.id(.articles, generation: generation))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: record["envelope"] as! Data) as? [String: Any])
        json["private_url"] = "https://example.com/private"
        record["envelope"] = try JSONSerialization.data(withJSONObject: json) as NSData
        XCTAssertThrowsError(try ICloudRecordCodec.decode(record, generation: generation))
        XCTAssertThrowsError(try ICloudRetentionUnreadPolicy.validateWireData(Data(repeating: 1, count: 2_049)))
        XCTAssertThrowsError(try ICloudRecordEnvelope(kind: .retentionPolicy, recordName: "retention-policy-v1:wrong", fields: envelope.fields))
        XCTAssertThrowsError(try ICloudRecordCodec.encode(envelope, systemFields: nil, bodyData: Data([1]), generation: generation))
    }

    func testEnableCannotPublishLibraryBeforeServerProtectionReceipt() async throws {
        let repository = try await peer()
        try repository.setSyncUnreadContent(true)
        let guardRecord = try XCTUnwrap(record(repository, kind: .retentionPolicy))
        XCTAssertNil(try record(repository, kind: .settings))
        XCTAssertFalse(try XCTUnwrap(cache(repository)).allowsUnreadRemoval)
        try confirm(repository, guardRecord)
        let setting = try XCTUnwrap(record(repository, kind: .settings))
        XCTAssertEqual(setting.envelope.fields["sync_unread_content"]?.value, .flag(true))
        XCTAssertTrue(try XCTUnwrap(cache(repository)).protects(setting.envelope.fields["sync_unread_content"]!.version))
    }

    func testStampedPolicyReceiptDoesNotCauseAnEndlessResendOrKeepLibraryBlocked() async throws {
        let repository = try await peer()
        try repository.setSyncUnreadContent(true)
        let groups = try repository.outgoingRecordGroups()
        let batch = try ICloudSaveBatchPlanner.select(groups, generation: generation, requiresArticleGuards: true)
        let policy = try XCTUnwrap(batch.records.first { $0.envelope.kind == .retentionPolicy })
        XCTAssertNotEqual(policy.envelope.fields["writer_nonce"]?.value, .text(""))
        try confirm(repository, policy)
        XCTAssertNotNil(try record(repository, kind: .settings))
        XCTAssertNil(try record(repository, kind: .retentionPolicy))
        XCTAssertNil(try record(repository, kind: .retentionPolicy))
    }

    func testDefaultOffPolicyRequiresLibraryAcknowledgementEvenAtBootstrap() async throws {
        let repository = try await peer()
        let off = try XCTUnwrap(record(repository, kind: .settings))
        XCTAssertNil(try record(repository, kind: .retentionPolicy))
        try confirm(repository, off)
        let released = try XCTUnwrap(record(repository, kind: .retentionPolicy))
        XCTAssertEqual(released.envelope.fields["release_unread"]?.version, .bootstrap)
        XCTAssertTrue(try ICloudRetentionUnreadPolicy(envelope: released.envelope, generation: generation).allowsUnreadRemoval)
    }

    func testDisableReleasesOnlyAfterLibraryFalseAcknowledgement() async throws {
        let repository = try await peer()
        try repository.setSyncUnreadContent(true)
        try confirm(repository, XCTUnwrap(record(repository, kind: .retentionPolicy)))
        try confirm(repository, XCTUnwrap(record(repository, kind: .settings)))
        try repository.setSyncUnreadContent(false)
        let off = try XCTUnwrap(record(repository, kind: .settings))
        XCTAssertNil(try record(repository, kind: .retentionPolicy))
        XCTAssertFalse(try XCTUnwrap(cache(repository)).allowsUnreadRemoval)
        try confirm(repository, off)
        let release = try XCTUnwrap(record(repository, kind: .retentionPolicy))
        XCTAssertTrue(try ICloudRetentionUnreadPolicy(envelope: release.envelope, generation: generation).allowsUnreadRemoval)
    }

    func testLateOffReceiptCannotReleaseNewerLocalEnable() async throws {
        let repository = try await peer()
        try repository.setSyncUnreadContent(true)
        try confirm(repository, XCTUnwrap(record(repository, kind: .retentionPolicy)))
        try confirm(repository, XCTUnwrap(record(repository, kind: .settings)))
        try repository.setSyncUnreadContent(false)
        let oldOff = try XCTUnwrap(record(repository, kind: .settings))
        try repository.setSyncUnreadContent(true)
        XCTAssertNil(try record(repository, kind: .settings))
        try confirm(repository, oldOff)
        let policy = try XCTUnwrap(cache(repository))
        XCTAssertFalse(policy.allowsUnreadRemoval)
        XCTAssertGreaterThan(try XCTUnwrap(policy.protectedVersion), oldOff.envelope.fields["sync_unread_content"]!.version)
        XCTAssertTrue(try repository.syncUnreadContent())
        XCTAssertNotNil(try record(repository, kind: .retentionPolicy))
    }

    func testRestartBetweenGuardReceiptAndLibrarySendKeepsOrderingProof() async throws {
        let repository = try await peer()
        try repository.setSyncUnreadContent(true)
        try confirm(repository, XCTUnwrap(record(repository, kind: .retentionPolicy)))
        let reopened = try LibraryDatabase(databaseURL: directories.last!.appendingPathComponent("library.sqlite"))
        let resumed = ICloudRecordRepository(database: reopened, accountID: "cloud")
        XCTAssertNotNil(try record(resumed, kind: .settings))
        XCTAssertNil(try record(resumed, kind: .retentionPolicy))
    }

    func testMirrorAloneDoesNotChangeLibrarySwitchOrReaderProjection() async throws {
        let repository = try await peer()
        let policy = try ICloudRetentionUnreadPolicy(generation: generation, protectedVersion: version(50)).envelope()
        try repository.receive([.init(envelope: policy, systemFields: nil)], checkpoint: Data([4]))
        XCTAssertFalse(try repository.syncUnreadContent())
        XCTAssertEqual(try repository.engineState(), Data([4]))
        XCTAssertEqual(try repository.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 0)
    }

    func testLegacyWriterKeepsOldSendBehaviorAndRejectsMirrorWithPause() async throws {
        let repository = try await peer(protocolVersion: 2)
        try repository.setSyncUnreadContent(true)
        XCTAssertNotNil(try record(repository, kind: .settings))
        XCTAssertNil(try record(repository, kind: .retentionPolicy))
        let policy = try ICloudRetentionUnreadPolicy(generation: generation, protectedVersion: version(50)).envelope()
        XCTAssertThrowsError(try repository.receive([.init(envelope: policy, systemFields: nil)], checkpoint: Data([4])))
        XCTAssertEqual(try repository.database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }, "invalidCloudRoot")
        XCTAssertNil(try repository.database.read { try Data.fetchOne($0, sql: "SELECT engine_state FROM icloud_sync_scope") })
    }

    func testRemovedServerPolicyPausesAndKeepsLocalOrderingEvidence() async throws {
        let repository = try await peer()
        try repository.setSyncUnreadContent(true)
        try confirm(repository, XCTUnwrap(record(repository, kind: .retentionPolicy)))
        XCTAssertThrowsError(try repository.discardServerMetadata(recordName: ICloudRetentionUnreadPolicy.recordName, zone: .articles))
        XCTAssertEqual(try repository.database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }, "retentionFenceMissing")
        XCTAssertNotNil(try cache(repository))
    }
}
