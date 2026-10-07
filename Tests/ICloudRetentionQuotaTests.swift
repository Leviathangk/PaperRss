@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudRetentionQuotaTests: XCTestCase {
    private let generation = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var version: ICloudFieldVersion { .init(counter: 1, deviceID: device) }

    private func operation(_ index: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", index)
    }

    private func metadata(_ quota: ICloudRetentionQuota, serverDate: Date? = nil) throws -> ICloudCloudRecordMetadata {
        .init(envelope: try quota.envelope(version: version), creationDate: now.addingTimeInterval(-10),
              modificationDate: serverDate ?? now, systemFields: Data([1]), changeTag: "fixture-tag")
    }

    func testFourHundredIncludesAllAtomicCleanupMutationsAndCannotOverallocate() throws {
        let full = try ICloudRetentionQuota().allocating(400, operationID: operation(1), serverDate: now)
        XCTAssertThrowsError(try full.allocating(1, operationID: operation(2), serverDate: now)) { error in
            XCTAssertEqual(error as? ICloudRetentionError, .budgetExceeded)
        }
        XCTAssertEqual(full.reservations.count, 1)
        XCTAssertNil(full.reservations.first?.confirmedAt)
    }

    func testUnknownCommitDateIsNeverExpiredByADeviceClockOrLongGap() throws {
        let full = try ICloudRetentionQuota().allocating(400, operationID: operation(1), serverDate: now)
        // The first later server observation dates an unknown receipt at that
        // observation. It cannot assume that the reservation committed earlier.
        XCTAssertThrowsError(try full.allocating(1, operationID: operation(2), serverDate: now.addingTimeInterval(100 * 86_400)))
        XCTAssertNil(full.reservations.first?.confirmedAt)
    }

    func testRollingSevenDaysCannotDoubleSpendAtAWindowBoundary() throws {
        let first = try ICloudRetentionQuota().allocating(200, operationID: operation(1), serverDate: now)
        let second = try first.allocating(200, operationID: operation(2), serverDate: now.addingTimeInterval(6 * 86_400))
        // The first reservation was confirmed at day 6. A day-7 reset cannot
        // manufacture another 400-record allocation as a fixed week would.
        XCTAssertThrowsError(try second.allocating(1, operationID: operation(3), serverDate: now.addingTimeInterval(7 * 86_400)))
        XCTAssertEqual(second.reservations.first?.confirmedAt, now.addingTimeInterval(6 * 86_400))
    }

    func testVerifiedOlderReservationsExpireIndividuallyAfterSevenDays() throws {
        let one = try ICloudRetentionQuota().allocating(200, operationID: operation(1), serverDate: now)
        let two = try one.allocating(200, operationID: operation(2), serverDate: now.addingTimeInterval(1))
        let late = try two.allocating(200, operationID: operation(3), serverDate: now.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(late.reservations.map(\.operationID), [operation(2), operation(3)])
        XCTAssertEqual(late.reservations.first?.confirmedAt, now.addingTimeInterval(8 * 86_400))
        XCTAssertThrowsError(try late.allocating(1, operationID: operation(4), serverDate: now.addingTimeInterval(8 * 86_400)))
    }

    func testAmbiguousSuccessRetryDoesNotReserveTwiceAndCannotChangeCost() throws {
        let quota = try ICloudRetentionQuota().allocating(5, operationID: operation(1), serverDate: now)
        XCTAssertEqual(try quota.allocating(5, operationID: operation(1), serverDate: now.addingTimeInterval(1)), quota)
        XCTAssertThrowsError(try quota.allocating(4, operationID: operation(1), serverDate: now))
        XCTAssertTrue(quota.contains(operationID: operation(1), processedRecords: 5))
        XCTAssertFalse(quota.contains(operationID: operation(1), processedRecords: 4))
    }

    func testTimeProbeChangesOnlyStampAndNeverResetsReservations() throws {
        let quota = try ICloudRetentionQuota().allocating(399, operationID: operation(1), serverDate: now)
        let probe = try quota.clockProbe(stamp: operation(2))
        XCTAssertEqual(probe.reservations, quota.reservations)
        XCTAssertEqual(probe.lastServerDate, quota.lastServerDate)
        XCTAssertNotEqual(probe.clockStamp, quota.clockStamp)
        XCTAssertThrowsError(try quota.clockProbe(stamp: quota.clockStamp))
    }

    func testMalformedCountsIDsAndRegressingServerTimeRejectWithoutMutation() throws {
        let quota = try ICloudRetentionQuota().allocating(5, operationID: operation(1), serverDate: now)
        for count in [-1, 0, 401, Int.max] {
            XCTAssertThrowsError(try quota.allocating(count, operationID: operation(2), serverDate: now))
        }
        XCTAssertThrowsError(try quota.allocating(1, operationID: "private-url", serverDate: now))
        XCTAssertThrowsError(try quota.allocating(1, operationID: operation(2), serverDate: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try quota.allocating(1, operationID: operation(2), serverDate: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(quota.reservations.count, 1)
    }

    func testQuotaWireIsStrictBoundedAndBodyless() throws {
        let quota = try ICloudRetentionQuota().allocating(5, operationID: operation(1), serverDate: now)
        let envelope = try quota.envelope(version: version)
        let record = try ICloudRecordCodec.encode(envelope, systemFields: nil, generation: generation)
        XCTAssertEqual(Set(record.allKeys()), ["envelope"])
        XCTAssertEqual(try ICloudRecordCodec.decode(record, generation: generation), envelope)
        XCTAssertEqual(try ICloudRetentionQuota(envelope: envelope), quota)
        XCTAssertThrowsError(try ICloudRecordCodec.encode(envelope, systemFields: nil, bodyData: Data([1]), generation: generation))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(quota)) as? [String: Any])
        json["private_guid"] = "urn:private"
        XCTAssertThrowsError(try ICloudRetentionQuota.decode(String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self)))
        json.removeValue(forKey: "private_guid")
        var entries = try XCTUnwrap(json["reservations"] as? [[String: Any]])
        entries[0]["body"] = "private"
        json["reservations"] = entries
        XCTAssertThrowsError(try ICloudRetentionQuota.decode(String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self)))
        XCTAssertThrowsError(try ICloudRetentionQuota.decode(String(repeating: "x", count: 65_537)))
    }

    func testOneReservationPerRecordStillFitsWireBudget() throws {
        var quota = ICloudRetentionQuota()
        for index in 1...400 { quota = try quota.allocating(1, operationID: operation(index), serverDate: now) }
        let envelope = try quota.envelope(version: version)
        let encoded = try JSONEncoder().encode(envelope)
        XCTAssertLessThan(encoded.count, ICloudRetentionQuota.maximumBytes * 2 + 1_024)
        XCTAssertNoThrow(try ICloudRecordCodec.encode(envelope, systemFields: nil, generation: generation))
        XCTAssertEqual(try ICloudRetentionQuota(envelope: envelope).reservations.count, 400)
    }

    func testQuotaSnapshotUsesOnlyMatchingServerMetadataAndRejectsMissingProof() throws {
        let quota = try ICloudRetentionQuota().allocating(5, operationID: operation(1), serverDate: now)
        let snapshot = try ICloudRetentionQuotaSnapshot(metadata: metadata(quota), generation: generation)
        XCTAssertEqual(snapshot.serverDate, now)
        let allocated = try quota.allocating(1, operationID: operation(2), serverDate: now)
        let prepared = try snapshot.preparing(allocated, observedClock: 10, deviceID: device)
        XCTAssertEqual(prepared.envelope.fields["ledger"]?.version.counter, 11)
        XCTAssertEqual(prepared.systemFields, Data([1]))
        XCTAssertThrowsError(try snapshot.preparing(quota, observedClock: Int64.max, deviceID: device))
        let noProof = ICloudCloudRecordMetadata(envelope: try quota.envelope(version: version), creationDate: now, modificationDate: now)
        XCTAssertThrowsError(try ICloudRetentionQuotaSnapshot(metadata: noProof, generation: generation))
        XCTAssertThrowsError(try ICloudRetentionQuotaSnapshot(metadata: metadata(quota, serverDate: now.addingTimeInterval(-1)), generation: generation))
    }

    func testCASPreparationRejectsClearingUndatedOrUnexpiredReservations() throws {
        let quota = try ICloudRetentionQuota().allocating(5, operationID: operation(1), serverDate: now)
        let snapshot = try ICloudRetentionQuotaSnapshot(metadata: metadata(quota), generation: generation)
        XCTAssertThrowsError(try snapshot.preparing(ICloudRetentionQuota(), observedClock: 2, deviceID: device))
        XCTAssertThrowsError(try snapshot.preparing(quota, observedClock: 2, deviceID: device))
        let probe = try quota.clockProbe(stamp: operation(2))
        XCTAssertNoThrow(try snapshot.preparing(probe, observedClock: 2, deviceID: device))
        let allocated = try quota.allocating(5, operationID: operation(2), serverDate: now)
        XCTAssertNoThrow(try snapshot.preparing(allocated, observedClock: 2, deviceID: device))
    }

    func testCASPreparationRejectsPrematureDatesAndChangedReservationCosts() throws {
        let quota = try ICloudRetentionQuota().allocating(5, operationID: operation(1), serverDate: now)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(quota)) as? [String: Any])
        var entries = try XCTUnwrap(json["reservations"] as? [[String: Any]])
        entries[0]["confirmedAt"] = now.addingTimeInterval(-1).timeIntervalSinceReferenceDate
        json["reservations"] = entries
        let early = try ICloudRetentionQuota.decode(String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        XCTAssertThrowsError(try quota.validateTransition(to: early, serverDate: now))
        entries[0].removeValue(forKey: "confirmedAt")
        entries[0]["processedRecords"] = 1
        json["reservations"] = entries
        let undercharged = try ICloudRetentionQuota.decode(String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        XCTAssertThrowsError(try quota.validateTransition(to: undercharged, serverDate: now))
    }

    func testOrdinaryReceiveKeepsNewerQuotaWithoutReplayingItAsASave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionQuota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write { try AccountRecord(id: "cloud", type: "iCloud", displayName: "Fixture", createdAt: 1, updatedAt: 1).save($0) }
        let repository = ICloudRecordRepository(database: database, accountID: "cloud")
        try repository.activate()
        try await repository.acceptCloudRoot(.init(generation: generation, phase: .ready, protocolVersion: 3))
        let quota = try ICloudRetentionQuota().allocating(5, operationID: operation(1), serverDate: now)
        let latest = try quota.envelope(version: .init(counter: 100, deviceID: device))
        let old = try ICloudRetentionQuota().envelope(version: version)
        try repository.receive([.init(envelope: latest, systemFields: nil)])
        try repository.receive([.init(envelope: old, systemFields: nil)], checkpoint: Data([3]))
        XCTAssertEqual(try database.read { try repository.cached(ICloudRetentionQuota.recordName, zone: .articles, in: $0)?.envelope }, latest)
        XCTAssertFalse(try repository.outgoingRecordGroups().flatMap(\.records).contains { $0.envelope.kind == .retentionQuota })
        XCTAssertEqual(try repository.engineState(), Data([3]))
    }

    func testLegacyWriterRefusesQuotaBeforeApplyingCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionQuota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write { try AccountRecord(id: "cloud", type: "iCloud", displayName: "Fixture", createdAt: 1, updatedAt: 1).save($0) }
        let repository = ICloudRecordRepository(database: database, accountID: "cloud")
        try repository.activate()
        try await repository.acceptCloudRoot(.init(generation: generation, phase: .ready))
        let quota = try ICloudRetentionQuota().envelope(version: version)
        XCTAssertThrowsError(try repository.receive([.init(envelope: quota, systemFields: nil)], checkpoint: Data([3])))
        XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }, "invalidCloudRoot")
        XCTAssertNil(try database.read { try Data.fetchOne($0, sql: "SELECT engine_state FROM icloud_sync_scope") })
    }

    func testPointReadRequiresEveryRequestedResultAndAcceptsOnlyVerifiedUnknownItem() throws {
        let names: Set<String> = [ICloudRetentionQuota.recordName, ICloudRetentionUnreadPolicy.recordName]
        let expected = try ICloudRetentionPointSnapshot.requestedIDs(names, generation: generation)
        let missing = Dictionary(uniqueKeysWithValues: expected.keys.map { ($0, Result<CKRecord, any Error>.failure(CKError(.unknownItem))) })
        let snapshot = try ICloudRetentionPointSnapshot.decode(missing, requestedNames: names, generation: generation)
        XCTAssertEqual(snapshot.missingNames, names)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertThrowsError(try ICloudRetentionPointSnapshot.decode([:], requestedNames: names, generation: generation))
        let networkFailure = Dictionary(uniqueKeysWithValues: expected.keys.map { ($0, Result<CKRecord, any Error>.failure(CKError(.networkFailure))) })
        XCTAssertThrowsError(try ICloudRetentionPointSnapshot.decode(networkFailure, requestedNames: names, generation: generation))
        XCTAssertThrowsError(try ICloudRetentionPointSnapshot.requestedIDs(["https://example.com/private"], generation: generation))
        XCTAssertThrowsError(try ICloudRetentionPointSnapshot.requestedIDs(["feed-v1:" + String(repeating: "a", count: 64)], generation: generation))
        XCTAssertThrowsError(try ICloudRetentionPointSnapshot.requestedIDs([], generation: generation))
    }

    func testFreshCKRecordCannotPretendToProvideServerDateOrChangeTag() throws {
        let envelope = try ICloudRetentionQuota().envelope(version: version)
        let record = try ICloudRecordCodec.encode(envelope, systemFields: nil, generation: generation)
        XCTAssertThrowsError(try ICloudRetentionPointSnapshot.decode([record.recordID: .success(record)],
            requestedNames: [ICloudRetentionQuota.recordName], generation: generation))
    }
}
