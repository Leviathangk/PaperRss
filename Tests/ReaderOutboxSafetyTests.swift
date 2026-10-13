import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

extension FreshRSSIntegrationTests {
    func testProjectionRegistrationKeepsExistingReaderProvider() async throws {
        let coordinator = SyncCoordinator()
        func provider() -> ReaderAccountProvider {
            ReaderAccountProvider(accountID: "same-account", endpointURL: URL(string: "https://example.com")!,
                                  username: "test", database: database, credentialStore: inMemoryCredentialStore, session: mockSession)
        }
        let original = provider()
        await coordinator.registerProvider(original)
        await coordinator.registerProviderIfNeeded(provider())
        let registered = await coordinator.provider(for: "same-account") as? ReaderAccountProvider
        XCTAssertTrue(registered === original)
        await coordinator.unregisterProvider(accountID: "same-account")
        let resumed = provider()
        await coordinator.registerProviderIfNeeded(resumed)
        let replacement = await coordinator.provider(for: "same-account") as? ReaderAccountProvider
        XCTAssertTrue(replacement === resumed)
    }

    private func seedOutbox(count: Int, type: AccountType = .freshRSS, enabled: Bool = true) throws -> ArticleStateOutboxProcessor {
        let accountID = "batch-test"
        try inMemoryCredentialStore.savePassword("pwd", for: type == .miniflux ? .miniflux : .freshRSS, accountID: accountID)
        try database.write { db in
            try AccountRecord(id: accountID, type: type.rawValue, displayName: "Test", isEnabled: enabled, createdAt: 0, updatedAt: 0).save(db)
            try FeedRecord(id: "batch-feed", accountID: accountID, title: "Test", feedURL: "https://example.com/feed", updatedAt: 0).save(db)
            for index in 0..<count {
                let id = "batch-\(index)"
                try ItemRecord(id: id, accountID: accountID, externalID: String(index + 1), feedID: "batch-feed", createdAt: 0, updatedAt: 0).save(db)
                try ArticleStateRecord(itemID: id, isRead: false, isStarred: false, updatedAt: 0).save(db)
                try ArticleStateOutboxRecord(accountID: accountID, itemID: id, stateKey: "read", desiredValue: true, revision: 1, updatedAt: Double(index)).save(db)
            }
        }
        let client = ReaderAPIClient(endpointURL: URL(string: "https://example.com")!, username: "test", accountID: accountID,
                                     credentialStore: inMemoryCredentialStore, session: mockSession,
                                     variant: type == .miniflux ? .miniflux : .freshRSS)
        return ArticleStateOutboxProcessor(accountID: accountID, database: database, apiClient: client)
    }

    private func stubBatchRequests(_ onEdit: @escaping @Sendable (URLRequest) throws -> Void) {
        MockFreshRSSURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch request.url!.lastPathComponent {
            case "ClientLogin": return (response, Data("Auth=test".utf8))
            case "token": return (response, Data("token".utf8))
            case "edit-tag": try onEdit(request); return (response, Data("OK".utf8))
            default: throw URLError(.badURL)
            }
        }
    }

    func testOutboxBatchesBothReaderServices() async throws {
        for type in [AccountType.freshRSS, .miniflux] {
            let processor = try seedOutbox(count: 120, type: type)
            let sizes = TestStateBox<[Int]>([])
            stubBatchRequests { request in
                let body = String(decoding: MockFreshRSSURLProtocol.requestBody(from: request), as: UTF8.self)
                var components = URLComponents()
                components.percentEncodedQuery = body
                sizes.mutate { $0.append(components.queryItems!.filter { $0.name == "i" }.count) }
            }
            let result = try await processor.processOutbox()
            XCTAssertEqual(result.successCount, 120)
            XCTAssertEqual(sizes.value, [50, 50, 20])
        }
    }

    func testMarkAllReadExcludesDisabledAccountsAndCreatesNoDeferredRead() throws {
        for type in [AccountType.freshRSS, .miniflux] {
            _ = try seedOutbox(count: 2, type: type, enabled: false)
            try database.write { db in
                try ArticleStateOutboxRecord.deleteAll(db)
                try ArticleStateRepository(database: database).markAllRead(in: db)
                XCTAssertEqual(try ArticleStateRecord.filter(Column("is_read") == false).fetchCount(db), 2)
                XCTAssertEqual(try ArticleStateOutboxRecord.fetchCount(db), 0)
                // Re-enabling later must not resurrect a hidden mark-all-read operation.
                try db.execute(sql: "UPDATE accounts SET is_enabled = 1 WHERE id = 'batch-test'")
                XCTAssertEqual(try ArticleStateOutboxRecord.fetchCount(db), 0)
            }
        }
    }

    func testOutboxStopsAfterAccountDisabledDuringRequest() async throws {
        let processor = try seedOutbox(count: 120)
        let dbStore = database!
        let calls = TestStateBox(0)
        stubBatchRequests { _ in
            calls.mutate { $0 += 1 }
            try dbStore.write { db in
                try db.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id = 'batch-test'")
            }
        }
        let result = try await processor.processOutbox()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(result.successCount, 50)
        XCTAssertEqual(try database.read { try ArticleStateOutboxRecord.fetchCount($0) }, 70)
        _ = try await processor.processOutbox(forceAll: true)
        XCTAssertEqual(calls.value, 1)
    }

    func testOutboxBatchFailureRetainsOnlyFailedBatch() async throws {
        let processor = try seedOutbox(count: 120)
        let calls = TestStateBox(0)
        stubBatchRequests { _ in
            calls.mutate { $0 += 1 }
            if calls.value == 2 { throw URLError(.notConnectedToInternet) }
        }
        let result = try await processor.processOutbox()
        XCTAssertEqual(result.successCount, 70)
        XCTAssertEqual(result.failureCount, 50)
        let pending = try database.read { try ArticleStateOutboxRecord.fetchAll($0) }
        XCTAssertEqual(pending.count, 50)
        XCTAssertTrue(pending.allSatisfy { $0.attemptCount == 1 && $0.nextAttemptAt != nil })
    }

    func testOutboxCoalescesConcurrentPushAndPreservesNewIntent() async throws {
        let processor = try seedOutbox(count: 1)
        let started = expectation(description: "First request suspended")
        let release = DispatchSemaphore(value: 0)
        let calls = TestStateBox(0)
        stubBatchRequests { _ in
            calls.mutate { $0 += 1 }
            if calls.value == 1 {
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            }
        }
        let first = Task { try await processor.processOutbox() }
        await fulfillment(of: [started], timeout: 3)
        try await ArticleStateRepository(database: database).markRead(itemID: "batch-0", isRead: false)
        _ = try await processor.processOutbox(forceAll: true)
        XCTAssertEqual(calls.value, 1, "Reentrant push must not race the in-flight request")
        release.signal()
        _ = try await first.value
        XCTAssertEqual(calls.value, 2, "New local intent must be sent after the original request")
        XCTAssertEqual(try database.read { try ArticleStateOutboxRecord.fetchCount($0) }, 0)
        XCTAssertEqual(try database.read { try ArticleStateRecord.fetchOne($0, key: "batch-0")?.isRead }, false)
    }
}
