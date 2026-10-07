import Foundation
import XCTest
@testable import PaperRssCore

private actor RetentionDiscoveryPages: ICloudInventoryPageFetching {
    let pages: [ICloudInventoryPage]
    private var calls: [Int] = []
    private var failOnceAt: Int?
    init(_ pages: [ICloudInventoryPage], failOnceAt: Int? = nil) {
        self.pages = pages; self.failOnceAt = failOnceAt
    }
    func requested() -> [Int] { calls }
    func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
        let index = cursor.map { Int($0.first!) } ?? 0
        calls.append(index)
        if failOnceAt == index { failOnceAt = nil; throw URLError(.networkConnectionLost) }
        return pages[index]
    }
}

private actor LargeRetentionDiscoverySource: ICloudInventoryPageFetching {
    private var calls = 0
    func count() -> Int { calls }
    func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
        let page = cursor.map { Int($0.first!) } ?? 0
        calls += 1
        let records = try (0..<limit).map { index -> ICloudCloudRecordMetadata in
            let url = URL(string: "https://example.com/rss")!, source = "fixture:\(page):\(index)"
            let name = try ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: source)!
            let envelope = try ICloudRecordEnvelope(kind: .read, recordName: "read-v1:" + name.dropFirst("article-v1:".count),
                feedURL: url.absoluteString, sourceItemID: source,
                fields: ["value": .init(value: .flag(page == 200), version: .init(counter: 1, deviceID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))])
            return .init(envelope: envelope, creationDate: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 1))
        }
        return .init(records: records, cursor: page == 200 ? nil : Data([UInt8(page + 1)]), envelopeBytes: records.count * 1_024)
    }
}

final class ICloudRetentionDiscoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func record(_ source: String, read: Bool = true) throws -> ICloudCloudRecordMetadata {
        let url = URL(string: "https://example.com/rss")!
        let name = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: source))
        let envelope = try ICloudRecordEnvelope(kind: .read, recordName: "read-v1:" + name.dropFirst("article-v1:".count),
            feedURL: url.absoluteString, sourceItemID: source,
            fields: ["value": .init(value: .flag(read), version: .init(counter: 1, deviceID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))])
        return .init(envelope: envelope, creationDate: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 1))
    }
    private func page(_ records: [ICloudCloudRecordMetadata], next: UInt8? = nil) -> ICloudInventoryPage {
        .init(records: records, cursor: next.map { Data([$0]) }, envelopeBytes: 1_024)
    }
    private func name(_ record: ICloudCloudRecordMetadata) -> String {
        "article-v1:" + ICloudMaintenancePlanner.articleKey(record.envelope.recordName)
    }

    func testDiscoveryIsBoundedAndPreservesNextPageWithoutRequiringGlobalCompletion() async throws {
        let first = try record("first"), second = try record("second")
        let source = RetentionDiscoveryPages([page([first], next: 1), page([second])])
        let scanner = ICloudRetentionDiscoveryScanner(source: source)
        let budget = ICloudRetentionDiscoveryBudget(pageLimit: 1)
        let one = try await scanner.scan(protection: .init(), now: now, budget: budget)
        XCTAssertEqual(one, [name(first)])
        let two = try await scanner.scan(protection: .init(), now: now, budget: budget)
        XCTAssertEqual(two, [name(second)])
        let calls = await source.requested(); XCTAssertEqual(calls, [0, 1])
    }

    func testDiscoveryReachesCandidatesBeyondTwentyThousandRecordsInBoundedPasses() async throws {
        let source = LargeRetentionDiscoverySource(), scanner = ICloudRetentionDiscoveryScanner(source: source)
        let budget = ICloudRetentionDiscoveryBudget(pageLimit: 50, recordLimit: 5_000)
        for _ in 0..<4 {
            let names = try await scanner.scan(protection: .init(), now: now, budget: budget)
            XCTAssertTrue(names.isEmpty)
        }
        let names = try await scanner.scan(protection: .init(), now: now, budget: budget)
        XCTAssertEqual(names.count, 100); XCTAssertEqual(names, names.sorted())
        let calls = await source.count(); XCTAssertEqual(calls, 201)
    }

    func testFinalPageOverflowRetainsOnlyRemainingHashesAndDoesNotRepeatQuery() async throws {
        let records = try [record("a"), record("b"), record("c")]
        let source = RetentionDiscoveryPages([page(records)]), scanner = ICloudRetentionDiscoveryScanner(source: source)
        let budget = ICloudRetentionDiscoveryBudget(articleLimit: 2)
        let first = try await scanner.scan(protection: .init(), now: now, budget: budget)
        let second = try await scanner.scan(protection: .init(), now: now, budget: budget)
        XCTAssertEqual(first + second, records.map(name).sorted())
        let calls = await source.requested(); XCTAssertEqual(calls, [0])
    }

    func testFailureKeepsEarlierHintsAndRetriesTheUncommittedPage() async throws {
        let first = try record("first"), second = try record("second")
        let source = RetentionDiscoveryPages([page([first], next: 1), page([second])], failOnceAt: 1)
        let scanner = ICloudRetentionDiscoveryScanner(source: source)
        do { _ = try await scanner.scan(protection: .init(), now: now); XCTFail("Network failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let restored = try await scanner.scan(protection: .init(), now: now)
        XCTAssertEqual(restored, [name(first), name(second)].sorted())
        let calls = await source.requested(); XCTAssertEqual(calls, [0, 1, 1])
    }

    func testPendingArticleAndFeedProtectionFilterHintsWithoutUsingQueryAbsence() async throws {
        let record = try record("pending")
        let feedName = try ICloudSyncIdentity.feedRecordName(feedURL: XCTUnwrap(URL(string: XCTUnwrap(record.envelope.feedURL))))
        for protection in [ICloudMaintenanceProtection(recordNames: [record.envelope.recordName]),
                           ICloudMaintenanceProtection(recordNames: [feedName])] {
            let source = RetentionDiscoveryPages([page([record])]), scanner = ICloudRetentionDiscoveryScanner(source: source)
            let names = try await scanner.scan(protection: protection, now: now)
            XCTAssertTrue(names.isEmpty)
        }
        let source = RetentionDiscoveryPages([page([record])]), scanner = ICloudRetentionDiscoveryScanner(source: source)
        do { _ = try await scanner.scan(protection: .init(hasUnresolvedChanges: true), now: now); XCTFail("Unresolved local intents") }
        catch { XCTAssertEqual(error as? ICloudRetentionError, .unresolvedChanges) }
        let calls = await source.requested(); XCTAssertTrue(calls.isEmpty)
    }

    func testMalformedPageCannotAdvanceCursorOrProduceHints() async throws {
        let record = try record("same")
        let invalid = page([record, record], next: 1)
        let source = RetentionDiscoveryPages([invalid]), scanner = ICloudRetentionDiscoveryScanner(source: source)
        for _ in 0..<2 {
            do { _ = try await scanner.scan(protection: .init(), now: now); XCTFail("Duplicate page IDs") }
            catch { XCTAssertEqual(error as? ICloudInventoryError, .malformedPage) }
        }
        let calls = await source.requested(); XCTAssertEqual(calls, [0, 0])
    }

    func testCursorAndSystemMetadataAreIncludedInTheByteBudget() async throws {
        let record = try record("large")
        let conditional = ICloudCloudRecordMetadata(envelope: record.envelope, creationDate: record.creationDate,
            modificationDate: record.modificationDate, systemFields: Data(repeating: 1, count: 100), changeTag: "tag")
        let source = RetentionDiscoveryPages([.init(records: [conditional], cursor: Data([1]), envelopeBytes: 100)]),
            scanner = ICloudRetentionDiscoveryScanner(source: source)
        do { _ = try await scanner.scan(protection: .init(), now: now,
            budget: .init(envelopeByteLimit: 200)); XCTFail("Cursor/fields/tag share the budget") }
        catch { XCTAssertEqual(error as? ICloudInventoryError, .malformedPage) }
    }
}
