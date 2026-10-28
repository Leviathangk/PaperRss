import Darwin
import Foundation
import GRDB
import XCTest
import PaperRssAgentProtocol
@testable import PaperRssCore
@testable import PaperRssDesktop

/// Real socket -> App controller -> App-owned isolated library. No GUI or production data.
@MainActor
final class AgentIPCIntegrationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let directory: URL
        let suite: String
        let defaults: UserDefaults
        let database: LibraryDatabase
        let provider: LocalAccountProvider
        let feed: Feed
        let controller: AgentBridgeController

        init(enabled: Bool, launchArguments: [String]) throws {
            directory = URL(fileURLWithPath: "/tmp/pr-agent-app-\(UUID().uuidString)")
            suite = "AgentIPCIntegration.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(enabled, forKey: AgentBridgeController.enableKey)
            database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
            provider = LocalAccountProvider(database: database)
            try provider.ensureAccountExists()
            feed = try provider.addFeed(title: "IPC synthetic feed", feedURL: URL(string: "https://example.org/feed")!)
            let feedID = feed.id.uuidString
            try database.write { db in
                for id in ["a", "b"] {
                    let timestamp = Date().timeIntervalSince1970
                    try ItemRecord(id: id, accountID: "local-default", externalID: id,
                                   feedID: feedID, createdAt: timestamp, updatedAt: timestamp).insert(db)
                    try ArticleRecord(itemID: id, title: "IPC article \(id)",
                                      url: "https://example.org/\(id)", publishedAt: timestamp,
                                      summary: "Synthetic metadata", contentHTML: "<p>IPC_STORED_BODY_\(id)</p>",
                                      contentUpdatedAt: timestamp).insert(db)
                    try ArticleStateRecord(itemID: id, isRead: false, isStarred: false,
                                           dateArrived: timestamp, updatedAt: timestamp).insert(db)
                }
            }
            controller = AgentBridgeController(defaults: defaults,
                directory: directory.appendingPathComponent("ipc"), launchArguments: launchArguments)
        }

        func client(enabled: Bool = true) -> AgentIPCClientBridge {
            AgentIPCClientBridge(enabled: enabled, directory: directory.appendingPathComponent("ipc"))
        }

        func state(_ id: String) throws -> ArticleStateRecord {
            try database.read { db in
                try XCTUnwrap(provider.stateRepository.fetchState(itemID: id, in: db))
            }
        }

        func close() async {
            await controller.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private let account: AgentJSON = .string("local-default")
    private let qaArguments = ["PaperRss", "--agent-qa-allow-content-egress", "--agent-qa-content-ids", "a"]

    private func withFixture(enabled: Bool = true, launchArguments: [String] = [],
                             _ operation: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(enabled: enabled, launchArguments: launchArguments)
        do {
            try await fixture.controller.attach(database: fixture.database)
            try await operation(fixture)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    private func expectFailure(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> AgentJSON) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch let error as AgentFailure {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Expected AgentFailure \(code), got \(error)", file: file, line: line)
        }
    }

    private func contentArguments(selection: String, article: String = "a") -> [String: AgentJSON] {
        ["account_id": account, "article_id": .string(article), "selection_id": .string(selection), "max_chars": .number(8_000)]
    }

    func testInjectedSnapshotAndOpenerRoundtrip() async throws {
        let fixture = try Fixture(enabled: true, launchArguments: [])
        var opened: AgentOpenRequest?
        do {
            try await fixture.controller.attach(database: fixture.database,
                accountSnapshotProvider: {
                    try AgentBridgeController.accountSnapshots(database: fixture.database, canOpen: true)
                }, opener: { opened = $0 })
            let status = try await fixture.controller.call(tool: "paperrss_status", arguments: [:])
            XCTAssertNotNil(status["app"]?["version"]?.stringValue)
            XCTAssertEqual(status["tools"], .array(AgentToolCatalog.names.map(AgentJSON.string)))
            XCTAssertTrue(status["capabilities"]?.arrayValue?.contains(.string("ui.open")) == true)
            let before = try fixture.state("a")
            let result = try await fixture.controller.call(tool: "paperrss_open", arguments: [
                "account_id": account, "article_id": .string("a")])
            XCTAssertEqual(opened, AgentOpenRequest(accountID: "local-default", feedID: fixture.feed.id, articleID: "a"))
            XCTAssertEqual(result["opened"], .string("article"))
            XCTAssertEqual(try fixture.state("a"), before)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testDisabledAppAndStoppedAppHaveDistinctErrors() async throws {
        try await withFixture(enabled: false) { fixture in
            let client = fixture.client()
            await expectFailure("NOT_ENABLED") {
                try await client.call(tool: "paperrss_status", arguments: [:])
            }
            fixture.defaults.set(true, forKey: AgentBridgeController.enableKey)
            try await fixture.controller.refreshEnablement()
            let enabled = try await client.call(tool: "paperrss_status", arguments: [:])
            XCTAssertEqual(enabled["enabled"], .bool(true))
            await fixture.controller.stop()
            await expectFailure("APP_NOT_RUNNING") {
                try await fixture.client().call(tool: "paperrss_status", arguments: [:])
            }
        }
    }

    func testMetadataRoundtripReadsAppLibraryWithoutChangingReadState() async throws {
        try await withFixture { fixture in
            let client = fixture.client()
            let before = try fixture.state("a")
            let status = try await client.call(tool: "paperrss_status", arguments: [:])
            XCTAssertEqual(status["accounts"]?.arrayValue?.first?["account_id"], account)
            let feeds = try await client.call(tool: "paperrss_list_feeds", arguments: ["account_id": account])
            XCTAssertEqual(feeds["feeds"]?.arrayValue?.first?["id"], .string(fixture.feed.id.uuidString))
            let articles = try await client.call(tool: "paperrss_list_articles", arguments: [
                "account_id": account, "scope": .string("unread"), "query": .string("IPC article a")])
            XCTAssertEqual(articles["articles"]?.arrayValue?.map { $0["id"] }, [.string("a")])
            let article = try await client.call(tool: "paperrss_get_article", arguments: ["account_id": account, "article_id": .string("a")])
            XCTAssertEqual(article["id"], .string("a"))
            XCTAssertNil(article["text"])
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(article), as: UTF8.self).contains("IPC_STORED_BODY"))
            XCTAssertEqual(try fixture.state("a"), before)
            await expectFailure("NOT_ENABLED") {
                try await fixture.client(enabled: false).call(tool: "paperrss_status", arguments: [:])
            }
        }
    }

    func testClientCannotAuthorizeItsOwnContentOrWriteState() async throws {
        try await withFixture { fixture in
            let client = fixture.client()
            let status = try await client.call(tool: "paperrss_status", arguments: [:])
            XCTAssertEqual(status["selection_ids"], .array([]))
            await expectFailure("UNAUTHORIZED") {
                try await client.call(tool: "paperrss_get_content", arguments: contentArguments(selection: "client-issued"))
            }
            await expectFailure("INVALID_ARGUMENT") {
                try await client.call(tool: "authorizeContent", arguments: ["article_ids": .array([.string("a")])])
            }
            // Planning is allowed, but only an App UI click can approve; a client-invented approval is rejected.
            let plan = try await client.call(tool: "paperrss_plan_state_change", arguments: ["account_id": account,
                "article_ids": .array([.string("a")]), "field": .string("read"), "value": .bool(true)])
            XCTAssertNil(plan["approval_id"])
            await expectFailure("CONFIRMATION_REQUIRED") {
                try await client.call(tool: "paperrss_apply_plan", arguments: ["plan_id": plan["plan_id"] ?? .null,
                    "approval_id": .string("client-issued"), "idempotency_key": .string("k1")])
            }
            XCTAssertFalse(try fixture.state("a").isRead)
        }
    }

    func testQAArticleIDsWithoutExplicitEgressConsentDoNotAuthorizeContent() async throws {
        try await withFixture(launchArguments: ["PaperRss", "--agent-qa-content-ids", "a"]) { fixture in
            let client = fixture.client()
            let status = try await client.call(tool: "paperrss_status", arguments: [:])
            XCTAssertEqual(status["selection_ids"], .array([]))
            await expectFailure("UNAUTHORIZED") {
                try await client.call(tool: "paperrss_get_content", arguments: contentArguments(selection: "a"))
            }
        }
    }

    func testAppLaunchQAGrantReadsOnlySelectedStoredContent() async throws {
        try await withFixture(launchArguments: qaArguments) { fixture in
            let client = fixture.client()
            let before = try fixture.state("a")
            let status = try await client.call(tool: "paperrss_status", arguments: [:])
            let selection = try XCTUnwrap(status["selection_ids"]?.arrayValue?.first?.stringValue)
            let content = try await client.call(tool: "paperrss_get_content", arguments: contentArguments(selection: selection))
            XCTAssertTrue(try XCTUnwrap(content["text"]?.stringValue).contains("IPC_STORED_BODY_a"))
            XCTAssertEqual(content["untrusted"], .bool(true))
            XCTAssertEqual(content["content_source"], .string("feed"))
            await expectFailure("UNAUTHORIZED") {
                try await client.call(tool: "paperrss_get_content", arguments: contentArguments(selection: selection, article: "b"))
            }
            XCTAssertEqual(try fixture.state("a"), before)
        }
    }

    func testQAGrantIsConsumedByOneSessionAndCannotCrossClients() async throws {
        try await withFixture(launchArguments: qaArguments) { fixture in
            let first = fixture.client()
            let status = try await first.call(tool: "paperrss_status", arguments: [:])
            let selection = try XCTUnwrap(status["selection_ids"]?.arrayValue?.first?.stringValue)
            let second = fixture.client()
            let otherStatus = try await second.call(tool: "paperrss_status", arguments: [:])
            XCTAssertEqual(otherStatus["selection_ids"], .array([]))
            await expectFailure("UNAUTHORIZED") {
                try await second.call(tool: "paperrss_get_content", arguments: contentArguments(selection: selection))
            }
        }
    }

    func testDisableRevokesSelectionAndReenableDoesNotRenewQAGrant() async throws {
        try await withFixture(launchArguments: qaArguments) { fixture in
            let client = fixture.client()
            let status = try await client.call(tool: "paperrss_status", arguments: [:])
            let selection = try XCTUnwrap(status["selection_ids"]?.arrayValue?.first?.stringValue)
            fixture.defaults.set(false, forKey: AgentBridgeController.enableKey)
            try await fixture.controller.refreshEnablement()
            await expectFailure("NOT_ENABLED") {
                try await client.call(tool: "paperrss_get_content", arguments: contentArguments(selection: selection))
            }
            fixture.defaults.set(true, forKey: AgentBridgeController.enableKey)
            try await fixture.controller.refreshEnablement()
            let newClient = fixture.client()
            let reopened = try await newClient.call(tool: "paperrss_status", arguments: [:])
            XCTAssertEqual(reopened["selection_ids"], .array([]))
            await expectFailure("UNAUTHORIZED") {
                try await newClient.call(tool: "paperrss_get_content", arguments: contentArguments(selection: selection))
            }
        }
    }

    /// Exercises the App authorization/library seam independently of socket availability.
    /// The listener is attached while disabled; these calls intentionally use the trusted
    /// in-process bridge. This is not evidence that a socket or helper can connect.
    func testInProcessAppQAGrantReadsStoredContentAndRevokesWithoutStateWrites() async throws {
        try await withFixture(enabled: false, launchArguments: qaArguments) { fixture in
            fixture.defaults.set(true, forKey: AgentBridgeController.enableKey)
            let bridge = fixture.controller
            let before = try fixture.state("a")
            let status = try await bridge.call(tool: "paperrss_status", arguments: [:])
            XCTAssertEqual(status["transport"], .string("in_process"))
            let selection = try XCTUnwrap(status["selection_ids"]?.arrayValue?.first?.stringValue)
            let feeds = try await bridge.call(tool: "paperrss_list_feeds", arguments: ["account_id": account])
            XCTAssertEqual(feeds["feeds"]?.arrayValue?.first?["id"], .string(fixture.feed.id.uuidString))
            let articles = try await bridge.call(tool: "paperrss_list_articles", arguments: [
                "account_id": account, "scope": .string("unread")])
            XCTAssertEqual(Set(articles["articles"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []), ["a", "b"])
            let article = try await bridge.call(tool: "paperrss_get_article", arguments: [
                "account_id": account, "article_id": .string("a")])
            XCTAssertNil(article["text"])
            let content = try await bridge.call(tool: "paperrss_get_content", arguments: contentArguments(selection: selection))
            XCTAssertTrue(try XCTUnwrap(content["text"]?.stringValue).contains("IPC_STORED_BODY_a"))
            XCTAssertEqual(content["content_source"], .string("feed"))
            XCTAssertEqual(content["untrusted"], .bool(true))
            await expectFailure("UNAUTHORIZED") {
                try await bridge.call(tool: "paperrss_get_content", arguments: contentArguments(selection: selection, article: "b"))
            }
            XCTAssertEqual(try fixture.state("a"), before)
            fixture.defaults.set(false, forKey: AgentBridgeController.enableKey)
            await expectFailure("NOT_ENABLED") {
                try await bridge.call(tool: "paperrss_status", arguments: [:])
            }
            fixture.defaults.set(true, forKey: AgentBridgeController.enableKey)
            let reopened = try await bridge.call(tool: "paperrss_status", arguments: [:])
            XCTAssertEqual(reopened["selection_ids"], .array([]))
            await expectFailure("UNAUTHORIZED") {
                try await bridge.call(tool: "paperrss_get_content", arguments: contentArguments(selection: selection))
            }
            XCTAssertEqual(try fixture.state("a"), before)
        }
    }

    func testInProcessAppRequiresExplicitEgressConsentForQAContent() async throws {
        try await withFixture(enabled: false, launchArguments: ["PaperRss", "--agent-qa-content-ids", "a"]) { fixture in
            fixture.defaults.set(true, forKey: AgentBridgeController.enableKey)
            let bridge = fixture.controller
            let status = try await bridge.call(tool: "paperrss_status", arguments: [:])
            XCTAssertEqual(status["selection_ids"], .array([]))
            await expectFailure("UNAUTHORIZED") {
                try await bridge.call(tool: "paperrss_get_content", arguments: contentArguments(selection: "client-issued"))
            }
            XCTAssertFalse(try fixture.state("a").isRead)
        }
    }

    func testBuiltHelperWithoutFixtureReadsAppLibraryOverStdioAndSocket() async throws {
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/paperrss-agent").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw XCTSkip("Build paperrss-agent before the product smoke test.")
        }
        try await withFixture { fixture in
            let directory = fixture.directory.appendingPathComponent("ipc").path
            let responses = try await Task.detached {
                try Self.runHelperSmoke(helper: helper, directory: directory)
            }.value
            XCTAssertEqual(responses.count, 5)
            XCTAssertEqual(responses[0]["result"]?["protocolVersion"], .string("2025-11-25"))
            for response in responses.dropFirst() {
                XCTAssertEqual(response["result"]?["isError"], .bool(false))
            }
            XCTAssertEqual(responses[1]["result"]?["structuredContent"]?["data"]?["accounts"]?.arrayValue?.first?["account_id"], account)
            XCTAssertEqual(responses[2]["result"]?["structuredContent"]?["data"]?["feeds"]?.arrayValue?.first?["id"], .string(fixture.feed.id.uuidString))
            XCTAssertEqual(responses[3]["result"]?["structuredContent"]?["data"]?["articles"]?.arrayValue?.count, 2)
            XCTAssertEqual(responses[4]["result"]?["structuredContent"]?["data"]?["id"], .string("a"))
            XCTAssertFalse(try fixture.state("a").isRead)
        }
    }

    nonisolated private static func runHelperSmoke(helper: String, directory: String) throws -> [AgentJSON] {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["serve", "--stdio", "--client", "app-ipc-product-smoke"]
        var environment = ProcessInfo.processInfo.environment
        environment["PAPERRSS_AGENT_ENABLED"] = "1"
        environment["PAPERRSS_AGENT_SOCKET_DIR"] = directory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        let calls: [(String, [String: AgentJSON])] = [
            ("paperrss_status", [:]),
            ("paperrss_list_feeds", ["account_id": .string("local-default")]),
            ("paperrss_list_articles", ["account_id": .string("local-default"), "scope": .string("unread")]),
            ("paperrss_get_article", ["account_id": .string("local-default"), "article_id": .string("a")])
        ]
        var requests: [AgentJSON] = [.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("app-ipc-smoke"), "version": .string("1")])])
        ])]
        requests += calls.enumerated().map { index, call in .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(index + 2)), "method": .string("tools/call"),
            "params": .object(["name": .string(call.0), "arguments": .object(call.1)])
        ]) }
        var responses: [AgentJSON] = []
        for request in requests {
            var bytes = try JSONEncoder().encode(request)
            bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
            let deadline = Date().addingTimeInterval(10)
            var frame = Data()
            while true {
                guard Date() < deadline, frame.count < 1_048_576 else {
                    throw AgentFailure("SMOKE_TIMEOUT", "Helper did not finish a bounded response.")
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let result = Darwin.poll(&descriptor, 1, 100)
                if result < 0 && errno == EINTR { continue }
                guard result >= 0 else { throw AgentFailure("SMOKE_IO", "Could not poll helper stdout.") }
                if result == 0 { continue }
                var byte: UInt8 = 0
                guard Darwin.read(descriptor.fd, &byte, 1) == 1 else {
                    throw AgentFailure("SMOKE_EOF", "Helper closed stdout before its response.")
                }
                if byte == 10 { break }
                frame.append(byte)
            }
            responses.append(try JSONDecoder().decode(AgentJSON.self, from: frame))
        }
        return responses
    }
}
