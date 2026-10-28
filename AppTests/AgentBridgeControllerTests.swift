import Foundation
import GRDB
@testable import PaperRssCore
import XCTest
import PaperRssAgentProtocol
@testable import PaperRssDesktop

@MainActor
final class AgentBridgeControllerTests: XCTestCase {
    func testDefaultOffAndEnabledWithoutReadyAppFailClosed() async throws {
        let suite = "AgentBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = AgentBridgeController(defaults: defaults)
        do {
            _ = try await bridge.call(tool: "paperrss_list_feeds", arguments: [:])
            XCTFail("Default gate must reject")
        } catch let error as AgentFailure { XCTAssertEqual(error.code, "NOT_ENABLED") }
        defaults.set(true, forKey: AgentBridgeController.enableKey)
        do {
            _ = try await bridge.call(tool: "paperrss_status", arguments: [:])
            XCTFail("No app is attached")
        } catch let error as AgentFailure { XCTAssertEqual(error.code, "APP_NOT_RUNNING") }
        await bridge.stop()
    }
}

extension AgentBridgeControllerTests {
    func testAccountSnapshotsExposeOnlySafeFieldsForEveryAccountType() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let accounts = AccountType.allAgentFixtureTypes.enumerated().map { index, type in
            AccountRecord(id: "account-\(index)", type: type.rawValue, displayName: "RSS \(index)",
                endpointURL: "https://fixture-user:fixture-password@example.org:8443/private?token=fixture-secret",
                username: "fixture-user", isEnabled: index != 3, createdAt: 0, updatedAt: 0)
        }
        try database.write { db in
            for account in accounts { try account.insert(db) }
        }
        let provider = LocalAccountProvider(accountID: accounts[1].id, database: database)
        _ = try provider.addFeed(title: "Synthetic", feedURL: URL(string: "https://example.org/feed")!)
        let rows = try AgentBridgeController.accountSnapshots(database: database, accounts: accounts,
            syncStates: [accounts[1].id: AccountSyncStateRecord(accountID: accounts[1].id, lastSyncCompletedAt: 1_700_000_000)],
            canOpen: true)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0]["server_host"], .null)
        XCTAssertEqual(rows[1]["server_host"], .null)
        XCTAssertEqual(rows[2]["server_host"], .string("example.org:8443"))
        XCTAssertEqual(rows[3]["server_host"], .string("example.org:8443"))
        XCTAssertEqual(rows[1]["feed_count"], .number(1))
        XCTAssertEqual(rows[1]["unread_count"], .number(0))
        XCTAssertEqual(rows[1]["last_sync_at"], .string("2023-11-14T22:13:20Z"))
        XCTAssertEqual(rows[0]["last_sync_at"], .null)
        XCTAssertEqual(rows[3]["enabled"], .bool(false))
        XCTAssertEqual(rows[3]["capabilities"], .array([]))
        XCTAssertTrue(rows[2]["capabilities"]?.arrayValue?.contains(.string("ui.open")) == true)
        let text = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self).lowercased()
        for forbidden in ["password", "token", "secret", "cookie", "auth", "username", "fixture-user", "private", "https://", "@"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let defaults = try AgentBridgeController.accountSnapshots(database: database)
        XCTAssertEqual(defaults.count, 4)
        XCTAssertFalse(defaults[0]["capabilities"]?.arrayValue?.contains(.string("ui.open")) == true)
        XCTAssertNotNil(AgentBridgeController.appInfo()["debug"]?.boolValue)
        XCTAssertNotNil(AgentBridgeController.appInfo()["version"]?.stringValue)
        XCTAssertNotNil(AgentBridgeController.appInfo()["build"]?.stringValue)
    }
}

private extension AccountType {
    static let allAgentFixtureTypes: [AccountType] = [.local, .iCloud, .freshRSS, .miniflux]
}

/// Uses volatile defaults and repository-local fixtures; never reads the production library.
private final class AgentVolatileDefaults: UserDefaults, @unchecked Sendable {
    private var enabled = true
    override func bool(forKey defaultName: String) -> Bool { enabled }
    override func set(_ value: Bool, forKey defaultName: String) { enabled = value }
}

extension AgentBridgeControllerTests {
    func testApprovalRoutesToOwningSocketSessionAndRevocationClearsCenter() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/agent-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let provider = LocalAccountProvider(database: database)
        try provider.ensureAccountExists()
        let defaults = AgentVolatileDefaults()
        let center = AgentApprovalCenter(showPanel: false)
        let bridge = AgentBridgeController(defaults: defaults, directory: directory, approvalCenter: center)
        bridge.attachForTesting(database: database)
        let arguments: [String: AgentJSON] = ["account_id": .string("local-default"), "scope": .string("account")]
        let first = try await bridge.call(sessionID: "socket-a", tool: "paperrss_plan_mark_read", arguments: arguments)
        let planID = try XCTUnwrap(first["plan_id"]?.stringValue)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending.first?.sessionID, "socket-a")
        _ = try await bridge.call(sessionID: "socket-b", tool: "paperrss_status", arguments: [:])
        do {
            _ = try await bridge.confirmStatePlan(planID: planID, sessionID: "socket-b")
            XCTFail("Another session must not approve")
        } catch let error as AgentFailure { XCTAssertEqual(error.code, "CONFLICT") }
        await center.approve(try XCTUnwrap(center.pending.first))
        let status = try await bridge.call(sessionID: "socket-a", tool: "paperrss_status", arguments: ["plan_id": .string(planID)])
        XCTAssertEqual(status["plan_state"], .string("approved"))
        XCTAssertNotNil(status["approval_id"]?.stringValue)
        XCTAssertTrue(center.pending.isEmpty)
        _ = try await bridge.call(sessionID: "socket-a", tool: "paperrss_plan_mark_read", arguments: arguments)
        _ = try await bridge.call(sessionID: "socket-b", tool: "paperrss_plan_mark_read", arguments: arguments)
        await bridge.disconnect(sessionID: "socket-a")
        XCTAssertEqual(center.pending.map(\.sessionID), ["socket-b"])
        await center.deny(try XCTUnwrap(center.pending.first))
        XCTAssertTrue(center.pending.isEmpty)
        _ = try await bridge.call(sessionID: "socket-b", tool: "paperrss_plan_mark_read", arguments: arguments)
        defaults.set(false, forKey: AgentBridgeController.enableKey)
        try await bridge.refreshEnablement()
        XCTAssertTrue(center.pending.isEmpty)
        await bridge.stop()
    }
}
