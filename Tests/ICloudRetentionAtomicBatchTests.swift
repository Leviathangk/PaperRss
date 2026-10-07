import Foundation
import XCTest
@testable import PaperRssCore

final class ICloudRetentionAtomicBatchTests: XCTestCase {
    private let generation = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let operationID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let url = "https://example.com/feed"

    private func state(_ kind: ICloudRecordKind, value: Bool, counter: Int64 = 10) throws -> ICloudRecordEnvelope {
        let article = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: URL(string: url)!, sourceItemID: "urn:fixture:entry"))
        return try .init(kind: kind, recordName: "\(kind.rawValue)-v1:" + article.dropFirst("article-v1:".count),
                         feedURL: url, sourceItemID: "urn:fixture:entry",
                         fields: ["value": .init(value: .flag(value), version: .init(counter: counter, deviceID: device))])
    }
    private var articleName: String { get throws { try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: URL(string: url)!, sourceItemID: "urn:fixture:entry")) } }

    private func snapshot(read: Bool = true, starred: Bool = false, policyEnabled: Bool = false,
                          quota: ICloudRetentionQuota = .init(), old: Bool = true, bodyOnly: Bool = false) throws -> ICloudRetentionPointSnapshot {
        let readRecord = try state(.read, value: read), starRecord = try state(.starred, value: starred)
        let content = try ICloudRecordEnvelope(kind: .content, recordName: "content-v1:" + articleName.dropFirst("article-v1:".count),
            feedURL: url, sourceItemID: "urn:fixture:entry", fields: ["payload_hash": .init(value: .text(String(repeating: "a", count: 64)), version: .init(counter: 10, deviceID: device))])
        let marker = try ICloudRetentionFence(generation: generation, article: readRecord).envelope().stampedRetentionSave()
        let policy = try ICloudRetentionUnreadPolicy(generation: generation,
            protectedVersion: policyEnabled ? .init(counter: 20, deviceID: device) : nil,
            releasedVersion: policyEnabled ? nil : .bootstrap).envelope().stampedRetentionSave()
        let budget = try quota.envelope(version: .init(counter: 30, deviceID: device))
        let date = old ? now.addingTimeInterval(-184 * 86_400) : now
        var records: [String: ICloudCloudRecordMetadata] = [:]
        for record in [readRecord, starRecord, content, marker, policy, budget] {
            if bodyOnly && [.read, .starred].contains(record.kind) { continue }
            let timestamp = [.read, .starred, .content].contains(record.kind) ? date : now
            records[record.recordName] = .init(envelope: record, creationDate: timestamp, modificationDate: timestamp,
                                             systemFields: Data([1]), changeTag: "fixture-tag")
        }
        let names = try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: articleName)
        return .init(generation: generation, requestedNames: names, records: records, missingNames: names.subtracting(records.keys))
    }

    private func decision(_ snapshot: ICloudRetentionPointSnapshot, protection: ICloudMaintenanceProtection = .init()) throws -> ICloudRetentionBatchDecision {
        try ICloudRetentionAtomicBatchPlanner.prepare(snapshot: snapshot, articleRecordName: articleName, protection: protection,
            operationID: operationID, observedClock: 50, deviceID: device)
    }

    func testOldPairAndBodyProduceOneAtomicFiveRecordReservation() throws {
        guard case .prepared(let batch) = try decision(snapshot()) else { return XCTFail("Expected a complete cleanup batch") }
        XCTAssertEqual(batch.recordNamesToDelete.count, 3)
        XCTAssertEqual(Set(batch.recordsToSave.map(\.envelope.kind)), [.retention, .retentionQuota])
        XCTAssertEqual(batch.processedRecordCount, 5)
        let quotaRecord = try XCTUnwrap(batch.recordsToSave.first { $0.envelope.kind == .retentionQuota })
        XCTAssertTrue(try ICloudRetentionQuota(envelope: quotaRecord.envelope).contains(operationID: operationID, processedRecords: 5))
        let marker = try XCTUnwrap(batch.recordsToSave.first { $0.envelope.kind == .retention }).envelope
        let fence = try ICloudRetentionFence(envelope: marker, generation: generation)
        XCTAssertEqual(fence.readFloor?.counter, 10)
        XCTAssertEqual(fence.starredFloor?.counter, 10)
        XCTAssertEqual(fence.contentFloor?.counter, 10)
        XCTAssertNotEqual(marker.fields["writer_nonce"]?.value, .text(""))
    }

    func testUnreadBodyRemovalIncludesPolicyAndQuotaConditionalSaves() throws {
        guard case .prepared(let batch) = try decision(snapshot(read: false, old: false)) else { return XCTFail("Expected unqualified unread body") }
        XCTAssertEqual(batch.recordNamesToDelete.count, 1)
        XCTAssertEqual(Set(batch.recordsToSave.map(\.envelope.kind)), [.retention, .retentionPolicy, .retentionQuota])
        XCTAssertEqual(batch.processedRecordCount, 4)
        XCTAssertTrue(batch.recordNamesToDelete[0].hasPrefix("content-v1:"))
    }

    func testStarEnabledUnreadAndLocalPendingProtectTheirWholeArticle() throws {
        for point in [try snapshot(starred: true), try snapshot(read: false, policyEnabled: true)] {
            guard case .noCandidate = try decision(point) else { return XCTFail("Protected article cannot be removed") }
        }
        let protected = ICloudMaintenanceProtection(recordNames: [try state(.read, value: true).recordName])
        guard case .noCandidate = try decision(snapshot(), protection: protected) else { return XCTFail("Pending record must protect the group") }
        XCTAssertThrowsError(try decision(snapshot(), protection: .init(hasUnresolvedChanges: true)))
    }

    func testUnprovenMissingResultCannotBecomeAnOrphanCandidate() throws {
        let good = try snapshot(bodyOnly: true)
        var records = good.records
        let bodyName = try XCTUnwrap(records.keys.first { $0.hasPrefix("content-v1:") })
        records.removeValue(forKey: bodyName)
        let incomplete = ICloudRetentionPointSnapshot(generation: generation, requestedNames: good.requestedNames,
            records: records, missingNames: good.missingNames)
        XCTAssertThrowsError(try decision(incomplete))
        guard case .prepared(let batch) = try decision(good) else { return XCTFail("Verified orphan may be planned") }
        XCTAssertEqual(batch.processedRecordCount, 4)
        XCTAssertEqual(batch.recordNamesToDelete, [bodyName])
    }

    func testUnknownPolicyBlocksOrphanAndUnreadCleanupWithoutGuessingOff() throws {
        let good = try snapshot(bodyOnly: true)
        var records = good.records
        records.removeValue(forKey: ICloudRetentionUnreadPolicy.recordName)
        let unknown = ICloudRetentionPointSnapshot(generation: generation, requestedNames: good.requestedNames,
            records: records, missingNames: good.missingNames.union([ICloudRetentionUnreadPolicy.recordName]))
        XCTAssertThrowsError(try decision(unknown))
    }

    func testMissingQuotaOrBrokenWriterMarkerCannotAuthorizeCleanup() throws {
        let good = try snapshot()
        for name in [ICloudRetentionQuota.recordName, try XCTUnwrap(good.records.keys.first { $0.hasPrefix("retention-v1:") })] {
            var records = good.records; records.removeValue(forKey: name)
            let unknown = ICloudRetentionPointSnapshot(generation: generation, requestedNames: good.requestedNames,
                records: records, missingNames: [name])
            XCTAssertThrowsError(try decision(unknown))
        }
    }

    func testSharedQuotaCannotSplitArticleWhenOnlyFourRecordsRemain() throws {
        let quota = try ICloudRetentionQuota().allocating(396, operationID: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", serverDate: now)
        XCTAssertThrowsError(try decision(snapshot(quota: quota))) { error in
            XCTAssertEqual(error as? ICloudRetentionError, .budgetExceeded)
        }
    }

    func testAcceptedOperationIsRecognizedWithoutRepeatingItsDeletes() throws {
        let quota = try ICloudRetentionQuota().allocating(5, operationID: operationID, serverDate: now)
        guard case .alreadyAccepted(let count) = try decision(snapshot(quota: quota)) else { return XCTFail("Expected idempotent accepted receipt") }
        XCTAssertEqual(count, 5)
    }

    func testOnlyBoundedHashedArticleAddressesCanBeRequested() throws {
        let names = try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: articleName)
        XCTAssertEqual(names.count, 6)
        XCTAssertEqual(try ICloudRetentionPointSnapshot.requestedIDs(names, generation: generation).count, 6)
        XCTAssertThrowsError(try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: url))
        XCTAssertThrowsError(try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: "article-v1:" + String(repeating: "G", count: 64)))
    }
}
