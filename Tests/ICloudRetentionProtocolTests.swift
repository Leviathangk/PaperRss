import Foundation
import XCTest
@testable import PaperRssCore

final class ICloudRetentionProtocolTests: XCTestCase {
    private let generation = "00000000-0000-0000-0000-000000000001"
    private let device = "11111111-1111-1111-1111-111111111111"
    private let otherDevice = "22222222-2222-2222-2222-222222222222"
    private let now = Date(timeIntervalSince1970: 20_000_000)

    private func article(_ source: String = "private-guid-opaque", read: Bool? = true, star: Bool? = false,
        body: ICloudFieldValue? = .text(String(repeating: "a", count: 64)), created: Date? = Date(timeIntervalSince1970: 1),
        modified: Date? = Date(timeIntervalSince1970: 1), counter: Int64 = 10) throws -> [ICloudCloudRecordMetadata] {
        let url = URL(string: "https://example.com/rss?token=secret-feed-value")!
        let identity = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: source))
        var fields: [(ICloudRecordKind, String, ICloudFieldValue)] = []
        if let read { fields.append((.read, "value", .flag(read))) }
        if let star { fields.append((.starred, "value", .flag(star))) }
        if let body { fields.append((.content, "payload_hash", body)) }
        return try fields.map { kind, key, value in
            let envelope = try ICloudRecordEnvelope(kind: kind, recordName: "\(kind.rawValue)-v1:" + identity.dropFirst("article-v1:".count),
                feedURL: url.absoluteString, sourceItemID: source,
                fields: [key: .init(value: value, version: .init(counter: counter, deviceID: counter == 0 ? "" : device))])
            return .init(envelope: envelope, creationDate: created, modificationDate: modified,
                         systemFields: Data([1,2,3]), changeTag: "fake-tag-\(kind.rawValue)")
        }
    }
    private func plan(_ records: [ICloudCloudRecordMetadata], unread: Bool = false,
        protection: ICloudMaintenanceProtection = .init(), fences: [ICloudRetentionFence] = [],
        limit: Int = 400, complete: Bool = true) throws -> [ICloudRetentionCandidate] {
        try ICloudRetentionPlanner.candidates(records: records, generation: generation,
            isComplete: complete, syncUnreadContent: unread, protection: protection,
            existingFences: fences, serverNow: now, remainingRecords: limit)
    }
    private func fence(_ records: [ICloudCloudRecordMetadata]) throws -> ICloudRetentionFence {
        try ICloudRetentionFence(generation: generation, article: records[0].envelope).retiring(records.map(\.envelope))
    }
    private func mutatedJSON(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testFenceRoundTripContainsOnlyHashesVersionsAndGeneration() throws {
        let value = try fence(article()), data = try value.encoded()
        XCTAssertEqual(try ICloudRetentionFence.decode(data, generation: generation), value)
        XCTAssertLessThan(data.count, ICloudRetentionFence.maximumBytes)
        let encoded = String(decoding: data, as: UTF8.self)
        for forbidden in ["https://", "example.com", "token", "secret-feed-value", "private-guid-opaque",
                          "feedURL", "sourceItemID", "fingerprint", "body", "AI"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }
    func testFenceRejectsUnknownFieldsNestedSecretsFutureProtocolAndWrongGeneration() throws {
        let data = try fence(article()).encoded()
        for changed in [
            try mutatedJSON(data) { $0["privateURL"] = "https://secret.invalid" },
            try mutatedJSON(data) { $0["readFloor"] = ["counter": 10, "deviceID": device, "credential": "private"] },
            try mutatedJSON(data) { $0["schemaVersion"] = true },
            try mutatedJSON(data) { $0["recordName"] = "retention-v1:private-guid-opaque" },
            Data(repeating: 1, count: ICloudRetentionFence.maximumBytes + 1)
        ] { XCTAssertThrowsError(try ICloudRetentionFence.decode(changed, generation: generation)) }
        XCTAssertThrowsError(try ICloudRetentionFence.decode(try mutatedJSON(data) { $0["schemaVersion"] = 2 }, generation: generation)) {
            XCTAssertEqual($0 as? ICloudRetentionError, .unsupportedProtocol)
        }
        XCTAssertThrowsError(try ICloudRetentionFence.decode(data, generation: UUID().uuidString)) {
            XCTAssertEqual($0 as? ICloudRetentionError, .wrongGeneration)
        }
    }
    func testFloorsOnlyAdvanceAndRejectAnotherArticleOrGeneration() throws {
        let older = try fence(article(counter: 5)), newer = try fence(article(counter: 10))
        XCTAssertEqual(try older.merged(with: newer), newer)
        XCTAssertEqual(try newer.merged(with: older), newer)
        XCTAssertEqual(try newer.retiring(article(counter: 1).map(\.envelope)), newer)
        XCTAssertThrowsError(try newer.retiring(article("different-guid").map(\.envelope)))
        let wrong = try ICloudRetentionFence(generation: UUID().uuidString, article: article()[0].envelope)
        XCTAssertThrowsError(try newer.merged(with: wrong))
        var invalid = newer; invalid.readFloor = .init(counter: -1, deviceID: device)
        XCTAssertThrowsError(try newer.merged(with: invalid))
    }
    func testBootstrapIsLiveUntilAnExplicitFloorExistsAndIndependentKindsDoNotExpireTogether() throws {
        let records = try article(counter: 0)
        let initial = try ICloudRetentionFence(generation: generation, article: records[0].envelope)
        XCTAssertFalse(try initial.suppresses(records[0].envelope))
        let retired = try initial.retiring([records[0].envelope])
        XCTAssertTrue(try retired.suppresses(records[0].envelope))
        XCTAssertFalse(try retired.suppresses(records[1].envelope))
        XCTAssertFalse(try retired.suppresses(records[2].envelope))
    }
    func testAcknowledgedReplayIsSuppressedButAnActualPendingIntentGetsANewVersion() throws {
        let old = try article(counter: 5), value = try fence(article(counter: 10))
        XCTAssertTrue(try value.suppresses(old[1].envelope))
        let rebased = try value.versionForPendingIntent(kind: .starred, current: old[1].envelope.fields["value"]!.version,
            observedClock: 100, deviceID: otherDevice)
        XCTAssertEqual(rebased, .init(counter: 101, deviceID: otherDevice))
        var pending = old[1].envelope; pending.fields["value"] = .init(value: .flag(true), version: rebased)
        XCTAssertFalse(try value.suppresses(pending))
        XCTAssertEqual(try value.versionForPendingIntent(kind: .starred, current: rebased,
            observedClock: 200, deviceID: otherDevice), rebased)
    }
    func testPendingRebaseRejectsOverflowInvalidVersionsAndStructuralKinds() throws {
        var value = try fence(article())
        value.readFloor = .init(counter: Int64.max, deviceID: device)
        XCTAssertThrowsError(try value.versionForPendingIntent(kind: .read, current: .bootstrap, observedClock: 1, deviceID: device)) {
            XCTAssertEqual($0 as? ICloudRetentionError, .clockOverflow)
        }
        XCTAssertThrowsError(try value.versionForPendingIntent(kind: .feed, current: .bootstrap, observedClock: 1, deviceID: device))
        XCTAssertThrowsError(try value.versionForPendingIntent(kind: .read, current: .init(counter: 1, deviceID: "private-user"), observedClock: 1, deviceID: device))
    }
    func testWeeklyQuotaUsesASevenDayServerWindowAndCannotExceed400() throws {
        let full = ICloudRetentionWeek(startedAt: now, processedRecords: 395)
        let last = try full.allocating(5, serverNow: now.addingTimeInterval(10))
        XCTAssertEqual(last.processedRecords, 400); XCTAssertEqual(last.startedAt, now)
        XCTAssertThrowsError(try last.allocating(1, serverNow: now.addingTimeInterval(ICloudRetentionWeek.duration - 1))) {
            XCTAssertEqual($0 as? ICloudRetentionError, .budgetExceeded)
        }
        let next = now.addingTimeInterval(ICloudRetentionWeek.duration)
        XCTAssertEqual(try last.allocating(400, serverNow: next), .init(startedAt: next, processedRecords: 400))
        XCTAssertThrowsError(try full.allocating(1, serverNow: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try full.allocating(Int.max, serverNow: now))
        XCTAssertThrowsError(try full.allocating(0, serverNow: now))
    }
    func testAgedStatePairAndBodyAreOneCandidateWithGuardOverheadIncluded() throws {
        let records = try article(), result = try XCTUnwrap(plan(records).first)
        XCTAssertEqual(Set(result.recordsToRemove), Set(records.map { $0.envelope.recordName }))
        XCTAssertEqual(result.processedRecordCount, 5)
        XCTAssertFalse(result.requiresUnreadPolicyGuard)
        XCTAssertEqual(result.observedRecords.count, 3)
        XCTAssertTrue(try result.fence.suppresses(records[0].envelope))
        XCTAssertTrue(try result.fence.suppresses(records[1].envelope))
        XCTAssertTrue(try plan(records, limit: 4).isEmpty)
        XCTAssertEqual(try plan(records, limit: 5).count, 1)
        XCTAssertTrue(try plan(records, limit: 0).isEmpty)
    }
    func testStarsEligibleUnreadAndPendingArticleOrParentNeverBecomeCandidates() throws {
        XCTAssertTrue(try plan(article(star: true)).isEmpty)
        XCTAssertTrue(try plan(article(read: false), unread: true).isEmpty)
        let records = try article()
        XCTAssertTrue(try plan(records, protection: .init(recordNames: [records[1].envelope.recordName])).isEmpty)
        let parent = try fence(records).feedRecordName
        XCTAssertTrue(try plan(records, protection: .init(recordNames: [parent])).isEmpty)
        XCTAssertThrowsError(try plan(records, protection: .init(hasUnresolvedChanges: true))) {
            XCTAssertEqual($0 as? ICloudRetentionError, .unresolvedChanges)
        }
    }
    func testUnreadWithOptionOffAndOrphansRequireAnAdditionalPolicyGuard() throws {
        let unread = try XCTUnwrap(plan(article(read: false)).first)
        XCTAssertTrue(unread.requiresUnreadPolicyGuard); XCTAssertEqual(unread.processedRecordCount, 6)
        let orphan = try XCTUnwrap(plan(article(read: nil, star: nil)).first)
        XCTAssertEqual(orphan.recordsToRemove.count, 1)
        XCTAssertTrue(orphan.requiresUnreadPolicyGuard); XCTAssertEqual(orphan.processedRecordCount, 4)
        XCTAssertTrue(try plan(article(read: true, star: nil)).isEmpty)
    }
    func testMissingDatesRecentChangesAndExactAgeBoundaryDoNotExpireStatePairs() throws {
        let cutoff = now.addingTimeInterval(-ICloudMaintenancePlanner.proposedRetention)
        for records in [try article(modified: nil), try article(created: nil),
                        try article(modified: now), try article(created: cutoff, modified: cutoff)] {
            let result = try XCTUnwrap(plan(records).first)
            XCTAssertEqual(result.recordsToRemove, [records[2].envelope.recordName])
            XCTAssertNil(result.fence.readFloor); XCTAssertNil(result.fence.starredFloor)
        }
        XCTAssertEqual(try plan(article(created: cutoff.addingTimeInterval(-1), modified: cutoff.addingTimeInterval(-1))).first?.recordsToRemove.count, 3)
    }
    func testIncompleteQueryAndMissingOrOversizedCASMetadataStayNonExecutable() throws {
        let records = try article()
        XCTAssertThrowsError(try plan(records, complete: false)) {
            XCTAssertEqual($0 as? ICloudRetentionError, .incompleteSnapshot)
        }
        for invalid in [
            ICloudCloudRecordMetadata(envelope: records[0].envelope, creationDate: now, modificationDate: now),
            ICloudCloudRecordMetadata(envelope: records[0].envelope, creationDate: now, modificationDate: now, systemFields: Data([1]), changeTag: ""),
            ICloudCloudRecordMetadata(envelope: records[0].envelope, creationDate: now, modificationDate: now, systemFields: Data(repeating: 1, count: 65 * 1_024), changeTag: "tag")
        ] { XCTAssertTrue(try plan([invalid] + Array(records.dropFirst())).isEmpty) }
    }
    func testIdenticalPageOverlapIsDeduplicatedButChangedDuplicateRequiresAnotherSnapshot() throws {
        let records = try article()
        XCTAssertEqual(try plan(records + records).count, 1)
        let changed = ICloudCloudRecordMetadata(envelope: records[0].envelope, creationDate: records[0].creationDate,
            modificationDate: records[0].modificationDate, systemFields: records[0].systemFields, changeTag: "different-tag")
        XCTAssertThrowsError(try plan(records + [changed])) {
            XCTAssertEqual($0 as? ICloudRetentionError, .malformedSnapshot)
        }
    }
    func test400CeilingIsStableAcrossPageOrderAndDoesNotSplitPairs() throws {
        let records = try (0..<110).flatMap { try article("guid-\($0)") }
        let forward = try plan(records), reverse = try plan(Array(records.reversed()))
        XCTAssertEqual(forward.map(\.recordsToRemove), reverse.map(\.recordsToRemove))
        XCTAssertEqual(forward.reduce(0) { $0 + $1.processedRecordCount }, 400)
        XCTAssertEqual(forward.count, 80)
        XCTAssertTrue(forward.allSatisfy { $0.recordsToRemove.count == 3 })
        XCTAssertThrowsError(try plan(records, limit: 401))
    }
    func testRecentlyReplayedExpiredTrueStarCannotRevivePreviouslyRetiredHistory() throws {
        let retired = try fence(article(counter: 10))
        let replay = try article(star: true, created: now, modified: now, counter: 5)
        let result = try XCTUnwrap(plan(replay, unread: true, fences: [retired]).first)
        XCTAssertEqual(result.recordsToRemove.count, 3)
        XCTAssertEqual(result.fence, retired)
        XCTAssertFalse(result.requiresUnreadPolicyGuard)
    }
    func testNewStarAboveTheFloorSurvivesWhileAnOlderRetiredBodyRemainsRetired() throws {
        let old = try article(), retired = try fence(old)
        let newerStar = try article(star: true, counter: 11)[1]
        let result = try XCTUnwrap(plan([old[0], newerStar, old[2]], fences: [retired]).first)
        XCTAssertFalse(result.recordsToRemove.contains(newerStar.envelope.recordName))
        XCTAssertEqual(result.recordsToRemove.count, 2)
        XCTAssertFalse(try result.fence.suppresses(newerStar.envelope))
    }
    func testExpiredPairCanRemoveItsCompactContentTombstoneWithoutInventingANewBody() throws {
        let records = try article(body: .null)
        let result = try XCTUnwrap(plan(records).first)
        XCTAssertEqual(result.recordsToRemove.count, 3)
        XCTAssertNotNil(result.fence.contentFloor)
        XCTAssertEqual(result.processedRecordCount, 5)
    }
    func testStructuralTombstonesAreNeverCleanupTargets() throws {
        let envelope = try ICloudRecordEnvelope(kind: .folder, recordName: "folder-v1:" + UUID().uuidString,
            fields: ["name": .init(value: .text("Retained"), version: .bootstrap),
                     "sort_order": .init(value: .integer(0), version: .bootstrap),
                     "deleted": .init(value: .flag(true), version: .bootstrap)])
        XCTAssertTrue(try plan([.init(envelope: envelope, creationDate: Date(timeIntervalSince1970: 1))]).isEmpty)
        XCTAssertThrowsError(try ICloudRetentionFence(generation: generation, article: envelope))
    }
}
