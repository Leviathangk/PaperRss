import Foundation
import XCTest
import PaperRssAgentProtocol
import PaperRssAgentMCP

@MainActor
final class AgentMCPTests: XCTestCase {
    private func request(_ method: String, id: Int = 1, params: [String: AgentJSON] = [:]) -> AgentJSON {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)])
    }

    private func initialize(_ server: AgentMCPServer) async {
        let reply = await server.handle(request("initialize", params: [
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("tests"), "version": .string("1")])
        ]))
        XCTAssertEqual(reply?["result"]?["protocolVersion"], .string("2025-11-25"))
    }

    private func call(_ name: String, arguments: [String: AgentJSON] = [:], id: Int = 2) -> AgentJSON {
        request("tools/call", id: id, params: ["name": .string(name), "arguments": .object(arguments)])
    }

    func testToolsListPaginationParameters() async throws {
        let server = AgentMCPServer(bridge: AgentUnavailableBridge())
        await initialize(server)
        let baseline = await server.handle(request("tools/list"))
        let tools = try XCTUnwrap(baseline?["result"]?["tools"])
        for params: [String: AgentJSON] in [
            ["cursor": .null], ["cursor": .string("x")],
            ["_meta": .object(["progressToken": .number(1)])]
        ] {
            let reply = await server.handle(request("tools/list", params: params))
            XCTAssertEqual(reply?["result"]?["tools"], tools)
            XCTAssertNil(reply?["result"]?["nextCursor"])
        }
        for params: [String: AgentJSON] in [
            ["bogus": .number(1)], ["cursor": .number(5)], ["_meta": .null]
        ] {
            let reply = await server.handle(request("tools/list", params: params))
            XCTAssertEqual(reply?["error"]?["code"], .number(-32602))
            XCTAssertEqual(reply?["error"]?["message"], .string("Invalid tools/list parameters."))
        }
    }

    func testInitializeEchoes20250326() async {
        let server = AgentMCPServer(bridge: AgentUnavailableBridge())
        let reply = await server.handle(request("initialize", params: [
            "protocolVersion": .string("2025-03-26"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("tests"), "version": .string("1")])
        ]))
        XCTAssertEqual(reply?["result"]?["protocolVersion"], .string("2025-03-26"))
    }

    func testRegistrationHasElevenStrictToolsAndSecurityAnnotations() async throws {
        let server = AgentMCPServer(bridge: AgentUnavailableBridge())
        await initialize(server)
        let reply = await server.handle(request("tools/list"))
        let tools = try XCTUnwrap(reply?["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.stringValue }), Set([
            "paperrss_status", "paperrss_open", "paperrss_list_feeds", "paperrss_list_articles", "paperrss_get_article",
            "paperrss_get_content", "paperrss_plan_state_change", "paperrss_apply_state_change",
            "paperrss_add_feed", "paperrss_rename_feed", "paperrss_remove_feed"
        ]))
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.stringValue }), Set(AgentToolCatalog.names))
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["additionalProperties"], .bool(false))
        }
        let content = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "paperrss_get_content" })
        XCTAssertEqual(content["inputSchema"]?["properties"]?["max_chars"]?["maximum"], .number(20_000))
        XCTAssertEqual(content["annotations"]?["openWorldHint"], .bool(false))
        XCTAssertTrue(content["description"]!.stringValue!.contains("untrusted"))
        let apply = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "paperrss_apply_state_change" })
        XCTAssertEqual(apply["annotations"]?["destructiveHint"], .bool(true))
        XCTAssertEqual(apply["annotations"]?["idempotentHint"], .bool(true))
    }

    func testOpenHasReadOnlyAnnotationsAndExactlyOneTarget() async throws {
        let definition = try XCTUnwrap(AgentMCPTools.definitions.first { $0["name"] == .string("paperrss_open") })
        XCTAssertEqual(definition["annotations"]?["readOnlyHint"], .bool(true))
        XCTAssertEqual(definition["annotations"]?["idempotentHint"], .bool(true))
        XCTAssertEqual(definition["annotations"]?["openWorldHint"], .bool(false))
        XCTAssertEqual(definition["inputSchema"]?["oneOf"]?.arrayValue?.count, 2)
        let bridge = RecordingBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        for key in ["article_id", "feed_id"] {
            let arguments: [String: AgentJSON] = ["account_id": .string("allowed"), key: .string("target")]
            let reply = await server.handle(call("paperrss_open", arguments: arguments))
            XCTAssertEqual(reply?["result"]?["isError"], .bool(false))
            let recorded = await bridge.lastCall
            XCTAssertEqual(recorded?.0, "paperrss_open")
            XCTAssertEqual(recorded?.1, arguments)
        }
        for extra: [String: AgentJSON] in [[:], ["article_id": .string("a"), "feed_id": .string("f")],
                                          ["article_id": .null], ["feed_id": .string("")]] {
            var arguments: [String: AgentJSON] = ["account_id": .string("allowed")]
            arguments.merge(extra) { _, new in new }
            let reply = await server.handle(call("paperrss_open", arguments: arguments))
            XCTAssertEqual(reply?["result"]?["structuredContent"]?["error"]?["code"], .string("INVALID_ARGUMENT"))
        }
    }

    func testRequestMapsExactlyToBridgeAndResultHasBothRepresentations() async throws {
        let bridge = RecordingBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        let arguments: [String: AgentJSON] = ["account_id": .string("allowed"), "scope": .string("unread"),
            "limit": .number(12), "query": .string("Swift"), "since": .string("2026-10-26T08:00:00Z")]
        let reply = await server.handle(call("paperrss_list_articles", arguments: arguments))
        let recorded = await bridge.lastCall
        XCTAssertEqual(recorded?.0, "paperrss_list_articles")
        XCTAssertEqual(recorded?.1, arguments)
        XCTAssertEqual(reply?["result"]?["isError"], .bool(false))
        let structured = try XCTUnwrap(reply?["result"]?["structuredContent"])
        XCTAssertEqual(structured["api_version"], .string("1"))
        let text = try XCTUnwrap(reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(try JSONDecoder().decode(AgentJSON.self, from: Data(text.utf8)), structured)
    }

    func testInvalidParametersNeverReachBridge() async {
        let bridge = RecordingBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        let invalid: [[String: AgentJSON]] = [
            ["account_id": .string("a"), "scope": .string("all")],
            ["account_id": .string("a"), "scope": .string("unread"), "limit": .number(51)],
            ["account_id": .string("a"), "scope": .string("unread"), "limit": .number(1.5)],
            ["account_id": .string("a"), "scope": .string("selection")],
            ["account_id": .string("a"), "scope": .string("unread"), "selection_id": .string("s")],
            ["account_id": .string("a"), "scope": .string("unread"), "fetch": .bool(true)],
            ["account_id": .string("a"), "scope": .string("unread"), "query": .string(String(repeating: "a", count: 201))],
            ["account_id": .string("a"), "scope": .string("unread"), "since": .string("tomorrow")]
        ]
        for arguments in invalid {
            let reply = await server.handle(call("paperrss_list_articles", arguments: arguments))
            XCTAssertEqual(reply?["result"]?["isError"], .bool(true))
            XCTAssertEqual(reply?["result"]?["structuredContent"]?["error"]?["code"], .string("INVALID_ARGUMENT"))
        }
        let count = await bridge.callCount
        XCTAssertEqual(count, 0)
    }

    func testWriteSchemasRejectDuplicateIDsCredentialsAndUnboundApproval() throws {
        XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_plan_state_change", arguments: [
            "account_id": .string("a"), "article_ids": .array([.string("1"), .string("1")]),
            "field": .string("read"), "value": .bool(true)
        ]))
        for url in ["file:///tmp/feed.xml", "https://user:password@example.org/feed"] {
            XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_add_feed", arguments: [
                "account_id": .string("a"), "url": .string(url)
            ]))
        }
        XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_remove_feed", arguments: [
            "account_id": .string("a"), "feed_id": .string("f"), "approval_id": .string("unbound")
        ]))
        XCTAssertThrowsError(try AgentMCPTools.validate(name: "paperrss_apply_state_change", arguments: [
            "plan_id": .string("p"), "approval_id": .string("a"), "idempotency_key": .string(String(repeating: "x", count: 129))
        ]))
    }

    func testDefaultOffAndEnabledUnavailableAreStructuredFailures() async {
        for (enabled, code) in [(false, "NOT_ENABLED"), (true, "APP_NOT_RUNNING")] {
            let server = AgentMCPServer(bridge: AgentUnavailableBridge(enabled: enabled))
            await initialize(server)
            let reply = await server.handle(call("paperrss_status"))
            XCTAssertEqual(reply?["result"]?["isError"], .bool(true))
            XCTAssertEqual(reply?["result"]?["structuredContent"]?["api_version"], .string("1"))
            XCTAssertEqual(reply?["result"]?["structuredContent"]?["error"]?["code"], .string(code))
        }
    }

    func testProtocolErrorsAreSeparateFromToolErrors() async throws {
        let server = AgentMCPServer(bridge: AgentUnavailableBridge())
        let before = await server.handle(request("tools/list"))
        XCTAssertEqual(before?["error"]?["code"], .number(-32002))
        let rawParse = await server.handle(data: Data("{invalid".utf8))
        let parse = try JSONDecoder().decode(AgentJSON.self, from: XCTUnwrap(rawParse))
        XCTAssertEqual(parse["error"]?["code"], .number(-32700))
        let rawOversized = await server.handle(data: Data(repeating: 32, count: AgentMCPServer.maximumRequestBytes + 1))
        let oversized = try JSONDecoder().decode(AgentJSON.self, from: XCTUnwrap(rawOversized))
        XCTAssertEqual(oversized["error"]?["code"], .number(-32600))
        await initialize(server)
        let unknown = await server.handle(request("resources/list"))
        XCTAssertEqual(unknown?["error"]?["code"], .number(-32601))
        let notification = await server.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        XCTAssertNil(notification)
    }

    func testCancellationReachesInFlightBridge() async {
        let bridge = WaitingBridge()
        let server = AgentMCPServer(bridge: bridge)
        await initialize(server)
        let pending = Task { await server.handle(call("paperrss_status", id: 42)) }
        await bridge.waitUntilStarted()
        let notification = await server.handle(.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .number(42)])
        ]))
        XCTAssertNil(notification)
        let reply = await pending.value
        XCTAssertEqual(reply?["result"]?["structuredContent"]?["error"]?["code"], .string("CANCELLED"))
    }

    func testFixtureNeverIssuesContentOrWriteApproval() async throws {
        let server = AgentMCPServer(bridge: AgentFixtureBridge(enabled: true))
        await initialize(server)
        let status = await server.handle(call("paperrss_status"))
        XCTAssertEqual(status?["result"]?["structuredContent"]?["data"]?["fixture"], .bool(true))
        XCTAssertEqual(status?["result"]?["structuredContent"]?["data"]?["tools"], .array(AgentToolCatalog.names.map(AgentJSON.string)))
        let open = await server.handle(call("paperrss_open", arguments: [
            "account_id": .string("fixture-local"), "article_id": .string("fixture-article")
        ]))
        XCTAssertEqual(open?["result"]?["structuredContent"]?["error"]?["code"], .string("UNSUPPORTED"))
        let content = await server.handle(call("paperrss_get_content", arguments: [
            "account_id": .string("fixture-local"), "article_id": .string("fixture-article"), "selection_id": .string("invented")
        ]))
        XCTAssertEqual(content?["result"]?["structuredContent"]?["error"]?["code"], .string("UNAUTHORIZED"))
        let apply = await server.handle(call("paperrss_apply_state_change", arguments: [
            "plan_id": .string("invented"), "approval_id": .string("invented"), "idempotency_key": .string("k")
        ]))
        XCTAssertEqual(apply?["result"]?["structuredContent"]?["error"]?["code"], .string("CONFIRMATION_REQUIRED"))
    }

    func testFixtureHonorsTimeFilterAndRejectsUnknownCursor() async throws {
        let server = AgentMCPServer(bridge: AgentFixtureBridge(enabled: true))
        await initialize(server)
        for (since, expectedCount) in [("2026-10-26T00:00:00Z", 1), ("2026-10-28T00:00:00.000Z", 0)] {
            let response = await server.handle(call("paperrss_list_articles", arguments: [
                "account_id": .string("fixture-local"), "scope": .string("unread"), "since": .string(since)
            ]))
            XCTAssertEqual(response?["result"]?["structuredContent"]?["data"]?["articles"]?.arrayValue?.count, expectedCount)
        }
        let cursor = await server.handle(call("paperrss_list_feeds", arguments: [
            "account_id": .string("fixture-local"), "cursor": .string("fabricated")
        ]))
        XCTAssertEqual(cursor?["result"]?["structuredContent"]?["error"]?["code"], .string("INVALID_ARGUMENT"))
    }
}

private actor RecordingBridge: AgentBridge {
    var lastCall: (String, [String: AgentJSON])?
    var callCount = 0
    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        callCount += 1
        lastCall = (tool, arguments)
        return .object(["articles": .array([]), "next_cursor": .null])
    }
}

private actor WaitingBridge: AgentBridge {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func call(tool: String, arguments: [String: AgentJSON]) async throws -> AgentJSON {
        started = true
        waiter?.resume()
        waiter = nil
        try await Task.sleep(for: .seconds(30))
        return .null
    }
}
