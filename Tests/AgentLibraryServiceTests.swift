import Foundation
import XCTest
import GRDB
import PaperRssAgentProtocol
@testable import PaperRssCore

@MainActor
final class AgentLibraryServiceTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let database: LibraryDatabase
        let provider: LocalAccountProvider
        let feed: Feed

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentLibraryTests-\(UUID().uuidString)")
            database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
            provider = LocalAccountProvider(database: database)
            try provider.ensureAccountExists()
            feed = try provider.addFeed(title: "Fixture feed", feedURL: URL(string: "https://example.org/feed?token=private")!)
            try database.write { db in
                for (index, id) in ["a", "b", "c"].enumerated() {
                    let timestamp = 1_700_000_000.0 + Double(index)
                    try ItemRecord(id: id, accountID: "local-default", externalID: id,
                        feedID: feed.id.uuidString, createdAt: timestamp, updatedAt: timestamp).insert(db)
                    try ArticleRecord(itemID: id, title: id == "a" ? "Swift concurrency" : "Article \(id)",
                        author: id == "a" ? "Fixture author" : nil,
                        url: id == "a" ? "https://example.org/a?token=secret" : "https://example.org/\(id)",
                        publishedAt: timestamp, summary: id == "a" ? "Actor metadata summary" : "Short summary",
                        contentHTML: "<p>BODY_ONLY_SENTINEL \(id)</p>", contentUpdatedAt: timestamp).insert(db)
                    try ArticleStateRecord(itemID: id, isRead: id == "c", isStarred: id == "c",
                        dateArrived: timestamp, updatedAt: timestamp).insert(db)
                }
            }
        }

        func service(enabled: Bool = true, starred: Bool = false, writes: Bool = true,
                     budget: Int = 100_000, loader: MockPageLoader = MockPageLoader(),
                     clock: @escaping @Sendable () -> Date = { Date() }) -> AgentLibraryService {
            AgentLibraryService(database: database,
                policy: AgentAccessPolicy(enabled: enabled, accountIDs: ["local-default"],
                    allowStarred: starred, allowStateChanges: writes, outputCharacterBudget: budget),
                engine: ArticlePreparationEngine(pageLoader: loader), clock: clock)
        }

        func state(_ id: String) throws -> ArticleStateRecord {
            try database.read { db in
                try XCTUnwrap(provider.stateRepository.fetchState(itemID: id, in: db))
            }
        }
        func remove() throws { try FileManager.default.removeItem(at: directory) }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
    }

    private let account: AgentJSON = .string("local-default")
    private var unread: [String: AgentJSON] { ["account_id": account, "scope": .string("unread")] }

    private func expectFailure(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch let error as AgentFailure {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Expected AgentFailure \(code), got \(error)", file: file, line: line)
        }
    }

    private func makePlan(_ service: AgentLibraryService, ids: [String] = ["a", "b"], field: String = "read") async throws -> String {
        let result = try await service.call(tool: "paperrss_plan_state_change", arguments: [
            "account_id": account, "article_ids": .array(ids.map { .string($0) }),
            "field": .string(field), "value": .bool(true)
        ])
        return try XCTUnwrap(result["plan_id"]?.stringValue)
    }

    private func applyArguments(plan: String, approval: String, key: String = "test-request") -> [String: AgentJSON] {
        ["plan_id": .string(plan), "approval_id": .string(approval), "idempotency_key": .string(key)]
    }

    func testDefaultOffRejectsLibraryAccessAndHidesAccounts() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = AgentLibraryService(database: fixture.database)
        let status = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(status["enabled"], .bool(false))
        XCTAssertEqual(status["accounts"], .array([]))
        await expectFailure("NOT_ENABLED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: unread)
        }
        await expectFailure("NOT_ENABLED") {
            _ = try await service.authorizeContent(accountID: "local-default", articleIDs: ["a"])
        }
    }

    func testMetadataDoesNotReturnBodyRefreshOrMarkReadAndRedactsSensitiveURL() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let loader = MockPageLoader()
        let service = fixture.service(loader: loader)
        let before = try fixture.state("a")
        let result = try await service.call(tool: "paperrss_list_articles", arguments: unread)
        let articles = try XCTUnwrap(result["articles"]?.arrayValue)
        XCTAssertEqual(Set(articles.compactMap { $0["id"]?.stringValue }), ["a", "b"])
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("BODY_ONLY_SENTINEL"))
        XCTAssertFalse(encoded.contains("token=secret"))
        let article = try XCTUnwrap(articles.first { $0["id"] == .string("a") })
        XCTAssertEqual(article["content_available"], .bool(true))
        XCTAssertEqual(article["authors"], .array([.string("Fixture author")]))
        XCTAssertEqual(article["source_url_unavailable_reason"], .string("missing_or_sensitive_url"))
        XCTAssertNil(article["text"])
        XCTAssertEqual(try fixture.state("a"), before)
        XCTAssertEqual(loader.requestCount, 0)
        let feeds = try await service.call(tool: "paperrss_list_feeds", arguments: ["account_id": account])
        XCTAssertEqual(feeds["feeds"]?.arrayValue?.first?["unread_count"], .number(2))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(feeds), as: UTF8.self).contains("private"))
    }

    func testMetadataSearchOnlyUsesTitleAndExcerptAndRespectsFeedAndTime() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        var query = unread
        query["query"] = .string("Actor metadata")
        query["feed_id"] = .string(fixture.feed.id.uuidString)
        query["since"] = .string("2023-11-14T00:00:00Z")
        let matching = try await service.call(tool: "paperrss_list_articles", arguments: query)
        XCTAssertEqual(matching["articles"]?.arrayValue?.map { $0["id"] }, [.string("a")])
        query["query"] = .string("BODY_ONLY_SENTINEL")
        let bodyOnly = try await service.call(tool: "paperrss_list_articles", arguments: query)
        XCTAssertEqual(bodyOnly["articles"], .array([]))
        query["query"] = .string("Swift")
        query["since"] = .string("2024-01-01T00:00:00Z")
        let tooOld = try await service.call(tool: "paperrss_list_articles", arguments: query)
        XCTAssertEqual(tooOld["articles"], .array([]))
    }

    func testPaginationCursorIsBoundToQueryAndCannotCrossSessions() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        var query = unread; query["limit"] = .number(1)
        let first = try await service.call(tool: "paperrss_list_articles", arguments: query)
        let cursor = try XCTUnwrap(first["next_cursor"]?.stringValue)
        query["cursor"] = .string(cursor)
        let second = try await service.call(tool: "paperrss_list_articles", arguments: query)
        XCTAssertNotEqual(first["articles"], second["articles"])
        XCTAssertEqual(second["next_cursor"], .null)
        var changed = query; changed["query"] = .string("Swift")
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: changed)
        }
        let anotherSession = fixture.service()
        await expectFailure("CONFLICT") {
            _ = try await anotherSession.call(tool: "paperrss_list_articles", arguments: query)
        }
    }

    func testScopeAndAccountCannotBeExpandedByClient() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: ["account_id": .string("other-account"), "scope": .string("unread")])
        }
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: ["account_id": account, "scope": .string("starred")])
        }
        await expectFailure("INVALID_ARGUMENT") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: ["account_id": account, "scope": .string("all")])
        }
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_get_article", arguments: ["account_id": account, "article_id": .string("c")])
        }
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["c"])
        let selected = try await service.call(tool: "paperrss_list_articles", arguments: [
            "account_id": account, "scope": .string("selection"), "selection_id": .string(selection)
        ])
        XCTAssertEqual(selected["articles"]?.arrayValue?.map { $0["id"] }, [.string("c")])
    }

    func testContentRequiresExactSelectionAndUsesStoredFeedWithoutNetworkOrCacheWrite() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let loader = MockPageLoader()
        let service = fixture.service(loader: loader)
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["b"])
        let args: [String: AgentJSON] = ["account_id": account, "article_id": .string("b"), "selection_id": .string(selection), "max_chars": .number(10)]
        let before = try fixture.state("b")
        let result = try await service.call(tool: "paperrss_get_content", arguments: args)
        XCTAssertEqual(result["untrusted"], .bool(true))
        XCTAssertLessThanOrEqual(try XCTUnwrap(result["text"]?.stringValue).unicodeScalars.count, 10)
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertNil(try fixture.provider.fetchCache(entryID: "b"))
        XCTAssertEqual(try fixture.state("b"), before)
        var wrong = args; wrong["article_id"] = .string("a")
        await expectFailure("UNAUTHORIZED") { _ = try await service.call(tool: "paperrss_get_content", arguments: wrong) }
    }

    func testStaleStoredCacheIsNotUpgradedOrRewritten() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let loader = MockPageLoader()
        let prose = String(repeating: "Cached scientific article discusses measurements and their implications. ", count: 40)
        let cache = ArticleCache(entryID: "b", text: prose, html: "<article><p>\(prose)</p></article>",
            fetchedAt: Date(timeIntervalSince1970: 1_600_000_000), sourceURL: URL(string: "https://example.org/b"),
            isSanitized: true, normalizationRevision: 0)
        try fixture.provider.saveCache(cache)
        let service = fixture.service(loader: loader)
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["b"])
        let result = try await service.call(tool: "paperrss_get_content", arguments: [
            "account_id": account, "article_id": .string("b"), "selection_id": .string(selection)
        ])
        XCTAssertEqual(result["content_source"], .string("web_cache"))
        XCTAssertTrue(result["text"]?.stringValue?.contains("Cached scientific article") == true)
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertEqual(try fixture.provider.fetchCache(entryID: "b"), cache)
    }

    func testSharedOutputBudgetCannotBeBypassedByChangingTool() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service(budget: 100)
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["b"])
        _ = try await service.call(tool: "paperrss_get_article", arguments: ["account_id": account, "article_id": .string("a")])
        await expectFailure("CONTENT_BUDGET_EXCEEDED") {
            _ = try await service.call(tool: "paperrss_get_content", arguments: [
                "account_id": account, "article_id": .string("b"), "selection_id": .string(selection)
            ])
        }
    }

    func testFailedMultiArticleResponseDoesNotConsumeOutputBudget() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        // Either article fits alone, but the two-article response exceeds the session allowance.
        let service = fixture.service(budget: 80)
        let before = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(before["remaining_characters"], .number(80))
        await expectFailure("CONTENT_BUDGET_EXCEEDED") {
            _ = try await service.call(tool: "paperrss_list_articles", arguments: unread)
        }
        let after = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(after["remaining_characters"], before["remaining_characters"],
                       "A rejected whole response must not charge an undelivered first article")
    }

    func testFailedContentResponseDoesNotChargeUndeliveredMetadata() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        // Metadata fits, while the same response's metadata plus stored text does not.
        let service = fixture.service(budget: 40)
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["b"])
        let before = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(before["remaining_characters"], .number(40))
        await expectFailure("CONTENT_BUDGET_EXCEEDED") {
            _ = try await service.call(tool: "paperrss_get_content", arguments: [
                "account_id": account, "article_id": .string("b"), "selection_id": .string(selection)
            ])
        }
        let after = try await service.call(tool: "paperrss_status", arguments: [:])
        XCTAssertEqual(after["remaining_characters"], before["remaining_characters"],
                       "Metadata and body must reserve their output allowance together")
    }

    func testSelectionAndPlansExpireAndRevocationRejectsExistingAccess() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let clock = TestClock()
        let service = fixture.service(clock: { clock.now() })
        let selection = try await service.authorizeContent(accountID: "local-default", articleIDs: ["a"])
        let plan = try await makePlan(service)
        let approval = try await service.approve(planID: plan)
        clock.advance(901)
        await expectFailure("UNAUTHORIZED") {
            _ = try await service.call(tool: "paperrss_get_content", arguments: [
                "account_id": account, "article_id": .string("a"), "selection_id": .string(selection)
            ])
        }
        await expectFailure("CONFLICT") {
            _ = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: approval))
        }
        await service.revoke()
        await expectFailure("NOT_ENABLED") { _ = try await service.call(tool: "paperrss_list_articles", arguments: unread) }
        XCTAssertFalse(try fixture.state("a").isRead)
    }

    func testPlanHasNoSideEffectsAndApplyRequiresAppApproval() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let beforeA = try fixture.state("a"), beforeB = try fixture.state("b")
        let plan = try await makePlan(service)
        XCTAssertEqual(try fixture.state("a"), beforeA)
        XCTAssertEqual(try fixture.state("b"), beforeB)
        await expectFailure("CONFIRMATION_REQUIRED") {
            _ = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: "self-signed"))
        }
        let approval = try await service.approve(planID: plan)
        let receipt = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: approval))
        XCTAssertEqual(receipt["local_commit"], .string("committed"))
        XCTAssertEqual(receipt["sync"], .string("not_applicable"))
        XCTAssertEqual(receipt["applied_count"], .number(2))
        XCTAssertTrue(try fixture.state("a").isRead)
        XCTAssertTrue(try fixture.state("b").isRead)
    }

    func testConflictRejectsEntireBatch() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let plan = try await makePlan(service)
        let approval = try await service.approve(planID: plan)
        try fixture.provider.markRead(entryID: "b", read: true)
        await expectFailure("CONFLICT") {
            _ = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: approval))
        }
        XCTAssertFalse(try fixture.state("a").isRead, "The unaffected first item must not be partially committed")
        XCTAssertTrue(try fixture.state("b").isRead)
    }

    func testIdempotencyReturnsSameReceiptAndRejectsRebinding() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let clock = TestClock()
        let service = fixture.service(clock: { clock.now() })
        let plan = try await makePlan(service, field: "starred")
        let approval = try await service.approve(planID: plan)
        let args = applyArguments(plan: plan, approval: approval)
        let first = try await service.call(tool: "paperrss_apply_state_change", arguments: args)
        let committed = try fixture.state("a")
        clock.advance(901)
        let replay = try await service.call(tool: "paperrss_apply_state_change", arguments: args)
        XCTAssertEqual(first, replay)
        XCTAssertEqual(try fixture.state("a"), committed)
        await expectFailure("CONFLICT") {
            _ = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: "another-plan", approval: approval))
        }
        let status = try await service.call(tool: "paperrss_status", arguments: ["operation_id": try XCTUnwrap(first["operation_id"])])
        XCTAssertEqual(status["receipt"], first)
    }

    func testDatabaseFailureRollsBackAndDoesNotProduceReceipt() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        let plan = try await makePlan(service)
        let approval = try await service.approve(planID: plan)
        try fixture.database.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER agent_fixture_write_failure BEFORE UPDATE ON article_states
                WHEN NEW.item_id = 'b'
                BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
                """)
        }
        do {
            _ = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: approval))
            XCTFail("Database errors must propagate, never become a successful receipt")
        } catch is DatabaseError {
            // The transport converts this into a generic internal error without leaking SQL.
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(try fixture.state("a").isRead)
        XCTAssertFalse(try fixture.state("b").isRead)
        let status = try await service.call(tool: "paperrss_status", arguments: ["plan_id": .string(plan)])
        XCTAssertNil(status["receipt"])
        XCTAssertEqual(status["plan_state"], .string("approved"))
        try fixture.database.write { db in try db.execute(sql: "DROP TRIGGER agent_fixture_write_failure;") }
        let retry = try await service.call(tool: "paperrss_apply_state_change", arguments: applyArguments(plan: plan, approval: approval))
        XCTAssertEqual(retry["local_commit"], .string("committed"))
    }

    func testStateCapabilityAndSyncedAccountsAreRejected() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let readOnly = fixture.service(writes: false)
        await expectFailure("UNAUTHORIZED") { _ = try await makePlan(readOnly) }
        let service = fixture.service()
        try fixture.database.write { db in
            try db.execute(sql: "UPDATE accounts SET type = ? WHERE id = ?", arguments: [AccountType.iCloud.rawValue, "local-default"])
        }
        await expectFailure("UNSUPPORTED") { _ = try await makePlan(service) }
    }

    func testFeedMutationStubsNeverReportSuccessOrChangeFeeds() async throws {
        let fixture = try Fixture(); defer { try? fixture.remove() }
        let service = fixture.service()
        for tool in ["paperrss_add_feed", "paperrss_rename_feed", "paperrss_remove_feed"] {
            await expectFailure("UNSUPPORTED") {
                _ = try await service.call(tool: tool, arguments: ["account_id": account, "feed_id": .string(fixture.feed.id.uuidString)])
            }
        }
        let feeds = try fixture.provider.fetchFeeds()
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds.first?.title, "Fixture feed")
    }
}
