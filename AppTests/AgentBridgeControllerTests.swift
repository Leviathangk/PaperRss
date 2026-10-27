import Foundation
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
