import Foundation
import XCTest
@testable import PaperRssCore

final class ICloudMaintenanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000_000)
    private let device = "11111111-1111-1111-1111-111111111111"

    private func article(
        _ source: String, read: Bool? = false, starred: Bool? = false,
        content: ICloudFieldValue? = .text(String(repeating: "a", count: 64)),
        date: Date? = Date(timeIntervalSince1970: 1)
    ) throws -> [ICloudCloudRecordMetadata] {
        let url = URL(string: "https://example.com/rss")!
        let identity = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: source))
        var fields: [(ICloudRecordKind, String, ICloudFieldValue)] = []
        if let read { fields.append((.read, "value", .flag(read))) }
        if let starred { fields.append((.starred, "value", .flag(starred))) }
        if let content { fields.append((.content, "payload_hash", content)) }
        return try fields.map { kind, field, value in
            let envelope = try ICloudRecordEnvelope(kind: kind,
                recordName: "\(kind.rawValue)-v1:" + identity.dropFirst("article-v1:".count),
                feedURL: url.absoluteString, sourceItemID: source,
                fields: [field: .init(value: value, version: .init(counter: 1, deviceID: device))])
            return .init(envelope: envelope, creationDate: date, modificationDate: date)
        }
    }

    private func inventory(
        _ records: [ICloudCloudRecordMetadata], complete: Bool = true, unread: Bool = false,
        protection: ICloudMaintenanceProtection = .init(), limit: Int = 400
    ) -> ICloudCloudInventory {
        ICloudMaintenancePlanner.inventory(records: records, isComplete: complete,
            reachedSafetyLimit: false, syncUnreadContent: unread, protection: protection, now: now, limit: limit)
    }

    func testCountsClassifyBodiesFromIndependentStateRecordsAndKeepStars() throws {
        let records = try article("star", read: true, starred: true) +
            article("unread") + article("read", read: true) +
            article("orphan", read: nil, starred: nil) +
            article("incomplete", starred: nil) + article("tombstone", content: .null)
        let result = inventory(records)
        XCTAssertEqual(result.recordCount, 15)
        XCTAssertEqual(result.starredBodies, 1)
        XCTAssertEqual(result.unreadBodies, 1)
        XCTAssertEqual(result.readBodies, 1)
        XCTAssertEqual(result.orphanedBodies, 1)
        XCTAssertEqual(result.bodiesWithIncompleteStatus, 1)
        XCTAssertEqual(result.contentTombstones, 1)
        XCTAssertEqual(result.cleanupPreview?.removableBodies, 3)
        XCTAssertEqual(result.cleanupPreview?.staleStateRecords, 6)
    }

    func testPartialScanCannotDeclareOrphansOrProduceCleanupPreview() throws {
        let records = try article("later-status", read: nil, starred: nil)
        let result = inventory(records, complete: false)
        XCTAssertEqual(result.orphanedBodies, 0)
        XCTAssertEqual(result.bodiesWithIncompleteStatus, 1)
        XCTAssertNil(result.cleanupPreview)
    }

    func testPendingIntentProtectsEveryRecordOfItsArticleAndFeedIntentProtectsChildren() throws {
        let records = try article("pending", read: true)
        let protection = ICloudMaintenanceProtection(recordNames: [records[0].envelope.recordName])
        let result = inventory(records, protection: protection)
        XCTAssertEqual(result.cleanupPreview?.protectedArticles, 1)
        XCTAssertEqual(result.cleanupPreview?.removableBodies, 0)
        XCTAssertEqual(result.cleanupPreview?.staleStateRecords, 0)
        let feed = try ICloudSyncIdentity.feedRecordName(feedURL: URL(string: "https://example.com/rss")!)
        let protectedFeed = inventory(records, protection: .init(recordNames: [feed]))
        XCTAssertEqual(protectedFeed.cleanupPreview?.proposedRecordCount, 0)
    }

    func testMissingLocalIdentityOrUnconfirmedSettingsHoldTheEntirePreview() throws {
        let result = inventory(try article("hold", read: true),
            protection: .init(hasUnresolvedChanges: true))
        XCTAssertEqual(result.cleanupPreview?.proposedRecordCount, 0)
        XCTAssertEqual(result.cleanupPreview?.protectedArticles, 1)
        XCTAssertEqual(result.cleanupPreview?.hasUnresolvedLocalChanges, true)
    }

    func testEligibleUnreadAndStarsSurviveAgeAndUnknownDatesAreNeverExpired() throws {
        let records = try article("unread") + article("star", starred: true) +
            article("unknown-date", read: true, date: nil) +
            article("new-state", read: true, date: now)
        let result = inventory(records, unread: true)
        XCTAssertEqual(result.cleanupPreview?.staleStateRecords, 0)
        XCTAssertEqual(result.cleanupPreview?.removableBodies, 2)
    }

    func testRecentlyChangedOldStatusAndMissingModificationDateCannotExpire() throws {
        let recent = try article("recent-change", read: true, content: nil).map {
            ICloudCloudRecordMetadata(envelope: $0.envelope, creationDate: $0.creationDate, modificationDate: now)
        }
        let unknown = try article("unknown-modification", read: true, content: nil).map {
            ICloudCloudRecordMetadata(envelope: $0.envelope, creationDate: $0.creationDate)
        }
        XCTAssertEqual(inventory(recent + unknown).cleanupPreview?.staleStateRecords, 0)
    }

    func testBudgetIsDeterministicAndNeverSplitsAStatePair() throws {
        let records = try article("first", read: true)
        XCTAssertEqual(inventory(records, limit: 2).cleanupPreview?.proposedRecordCount, 1)
        XCTAssertEqual(inventory(records, limit: 3).cleanupPreview?.proposedRecordCount, 3)
        XCTAssertEqual(inventory(records, limit: 0).cleanupPreview?.proposedRecordCount, 0)
        let many = try (0..<200).flatMap { try article("item-\($0)", read: true) }
        let forward = inventory(many)
        let backward = inventory(Array(many.reversed()))
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.cleanupPreview?.proposedRecordCount, 400)
    }

    private actor Pages: ICloudInventoryPageFetching {
        var requests: [(ICloudRecordZone, Data?, Int)] = []
        var pages: [ICloudInventoryPage]
        var failure = false
        init(_ pages: [ICloudInventoryPage]) { self.pages = pages }
        func failNext() { failure = true }
        func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
            requests.append((zone, cursor, limit))
            if failure { failure = false; throw ICloudEngineError.temporarilyUnavailable }
            return pages.removeFirst()
        }
    }

    private actor BlockingPage: ICloudInventoryPageFetching {
        private var gate: CheckedContinuation<Void, Never>?
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }
        func release() { gate?.resume(); gate = nil }
        func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
            await withCheckedContinuation { continuation in
                gate = continuation
                started = true
                for waiter in startWaiters { waiter.resume() }
                startWaiters.removeAll()
            }
            return .init(records: [], cursor: nil, envelopeBytes: 0)
        }
    }

    func testConcurrentRequestIsRejectedAndCancelledInFlightPageCannotAdvanceScan() async throws {
        let source = BlockingPage()
        let scanner = ICloudInventoryScanner(source: source)
        let running = Task { try await scanner.scan() }
        await source.waitUntilStarted()
        do {
            _ = try await scanner.scan()
            XCTFail("Expected concurrent request rejection")
        } catch { XCTAssertEqual(error as? ICloudInventoryError, .alreadyScanning) }
        await scanner.cancel()
        await source.release()
        do {
            _ = try await running.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let complete = await scanner.isComplete
        XCTAssertFalse(complete)
    }

    func testPaginationContinuesAcrossBudgetedCallsWithoutRepeatingPages() async throws {
        let metadata = try article("pages")
        let source = Pages([
            .init(records: [], cursor: Data([1]), envelopeBytes: 0),
            .init(records: [], cursor: nil, envelopeBytes: 0),
            .init(records: metadata, cursor: nil, envelopeBytes: 100)
        ])
        let scanner = ICloudInventoryScanner(source: source)
        var budget = ICloudInventoryBudget()
        budget.pageLimit = 1
        let first = try await scanner.scan(budget: budget)
        XCTAssertEqual(first.count, 0)
        let incomplete = await scanner.isComplete
        XCTAssertFalse(incomplete)
        _ = try await scanner.scan(budget: budget)
        let third = try await scanner.scan(budget: budget)
        XCTAssertEqual(third.count, 3)
        let complete = await scanner.isComplete
        XCTAssertTrue(complete)
        let requests = await source.requests
        XCTAssertEqual(requests.map(\.0), [.library, .library, .articles])
        XCTAssertEqual(requests.map(\.1), [nil, Data([1]), nil])
    }

    func testRecordAndByteLimitsNeverClaimACompleteScan() async throws {
        let metadata = try article("limits", read: nil, starred: nil)
        let source = Pages([
            .init(records: [], cursor: nil, envelopeBytes: 0),
            .init(records: metadata, cursor: Data([2]), envelopeBytes: 100)
        ])
        let scanner = ICloudInventoryScanner(source: source)
        var budget = ICloudInventoryBudget()
        budget.recordLimit = 1
        let records = try await scanner.scan(budget: budget)
        XCTAssertEqual(records.count, 1)
        let limited = await scanner.didReachSafetyLimit
        let complete = await scanner.isComplete
        XCTAssertTrue(limited)
        XCTAssertFalse(complete)
        let byteSource = Pages([.init(records: [], cursor: nil, envelopeBytes: 101)])
        let byteScanner = ICloudInventoryScanner(source: byteSource)
        budget.envelopeByteLimit = 100
        let dropped = try await byteScanner.scan(budget: budget)
        XCTAssertEqual(dropped.count, 0)
        let byteLimited = await byteScanner.didReachSafetyLimit
        XCTAssertTrue(byteLimited)
    }

    func testConditionalMetadataSharesTheByteCeilingIncludingUTF8Tags() async throws {
        let value = try article("proof-budget")[0]
        let metadata = ICloudCloudRecordMetadata(envelope: value.envelope, creationDate: value.creationDate,
            modificationDate: value.modificationDate, systemFields: Data([1,2]), changeTag: "标")
        for limit in [14,15] {
            let scanner = ICloudInventoryScanner(source: Pages([
                .init(records: [], cursor: nil, envelopeBytes: 0),
                .init(records: [metadata], cursor: nil, envelopeBytes: 10)
            ]))
            var budget = ICloudInventoryBudget(); budget.envelopeByteLimit = limit
            let records = try await scanner.scan(budget: budget)
            let complete = await scanner.isComplete, limited = await scanner.didReachSafetyLimit
            XCTAssertEqual(records.count, limit == 15 ? 1 : 0)
            XCTAssertEqual(complete, limit == 15); XCTAssertEqual(limited, limit == 14)
        }
    }
    func testOversizedPageDeclarationCannotOverflowWithConditionalMetadata() async throws {
        let value = try article("proof-overflow")[0]
        let metadata = ICloudCloudRecordMetadata(envelope: value.envelope, creationDate: value.creationDate,
            systemFields: Data([1]), changeTag: "tag")
        let scanner = ICloudInventoryScanner(source: Pages([
            .init(records: [], cursor: nil, envelopeBytes: 0),
            .init(records: [metadata], cursor: nil, envelopeBytes: Int.max)
        ]))
        let records = try await scanner.scan()
        let complete = await scanner.isComplete, limited = await scanner.didReachSafetyLimit
        XCTAssertTrue(records.isEmpty); XCTAssertFalse(complete); XCTAssertTrue(limited)
    }

    func testForeignEpochRecordsCountTowardTheScanBudgetWithoutEnteringCleanup() async throws {
        let source = Pages([.init(records: [], cursor: Data([1]), envelopeBytes: 100, otherGenerationRecords: 3)])
        let scanner = ICloudInventoryScanner(source: source)
        var budget = ICloudInventoryBudget()
        budget.recordLimit = 3
        let records = try await scanner.scan(budget: budget)
        let foreign = await scanner.foreignRecordCount
        let limited = await scanner.didReachSafetyLimit
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(foreign, 3)
        XCTAssertTrue(limited)
        let snapshot = ICloudMaintenancePlanner.inventory(records: [], isComplete: true,
            reachedSafetyLimit: false, syncUnreadContent: false, protection: .init(), otherGenerationRecords: foreign)
        XCTAssertEqual(snapshot.recordCount, 3)
        XCTAssertEqual(snapshot.otherGenerationRecords, 3)
        XCTAssertEqual(snapshot.cleanupPreview?.proposedRecordCount, 0)
    }

    func testQueryFailureRetainsCursorForRetryAndCancellationRejectsFurtherWork() async throws {
        let source = Pages([
            .init(records: [], cursor: Data([8]), envelopeBytes: 0),
            .init(records: [], cursor: nil, envelopeBytes: 0),
            .init(records: [], cursor: nil, envelopeBytes: 0)
        ])
        let scanner = ICloudInventoryScanner(source: source)
        var budget = ICloudInventoryBudget()
        budget.pageLimit = 1
        _ = try await scanner.scan(budget: budget)
        await source.failNext()
        do {
            _ = try await scanner.scan(budget: budget)
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? ICloudEngineError, .temporarilyUnavailable) }
        _ = try await scanner.scan(budget: budget)
        let requests = await source.requests
        XCTAssertEqual(requests.map(\.1), [nil, Data([8]), Data([8])])
        await scanner.cancel()
        do {
            _ = try await scanner.scan()
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testUnexpectedZoneAndRepeatedCursorCannotBecomeSuccessfulTotals() async throws {
        let metadata = try article("wrong-zone")
        let wrong = ICloudInventoryScanner(source: Pages([.init(records: metadata, cursor: nil, envelopeBytes: 100)]))
        do {
            _ = try await wrong.scan()
            XCTFail("Expected invalid zone")
        } catch { XCTAssertEqual(error as? ICloudInventoryError, .malformedPage) }
        let repeated = ICloudInventoryScanner(source: Pages([
            .init(records: [], cursor: Data([1]), envelopeBytes: 0),
            .init(records: [], cursor: Data([1]), envelopeBytes: 0)
        ]))
        do {
            _ = try await repeated.scan()
            XCTFail("Expected repeated cursor failure")
        } catch { XCTAssertEqual(error as? ICloudInventoryError, .malformedPage) }
    }
}
