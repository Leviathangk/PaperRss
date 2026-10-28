import Foundation
import XCTest
@testable import PaperRssDesktop

final class AgentMCPConnectCopyTests: XCTestCase {
    func testPathResolutionPrefersBundleThenDevelopmentAndHandlesMissing() {
        let bundle = URL(fileURLWithPath: "/work/PaperRss/build/PaperRss.app")
        let home = URL(fileURLWithPath: "/home/test")
        let embedded = "/work/PaperRss/build/PaperRss.app/Contents/MacOS/paperrss-agent"
        let development = "/work/PaperRss/.build/debug/paperrss-agent"
        XCTAssertEqual(AgentMCPConnectCopy.helperPath(bundleURL: bundle, homeURL: home, isExecutable: { [embedded, development].contains($0) }), embedded)
        XCTAssertEqual(AgentMCPConnectCopy.helperPath(bundleURL: bundle, homeURL: home, isExecutable: { $0 == development }), development)
        XCTAssertNil(AgentMCPConnectCopy.helperPath(bundleURL: bundle, homeURL: home, isExecutable: { _ in false }))
    }

    func testConfigurationContainsEscapedPathAndRequiredFields() throws {
        let path = "/tmp/a \"quoted\"/paperrss-agent"
        let result = AgentMCPConnectCopy.text(path: path, english: false)
        let json = try XCTUnwrap(result.components(separatedBy: "### Cursor / Claude (mcp.json)\n").last?.components(separatedBy: "\n\n### Codex").first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["paperrss"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, path)
        XCTAssertEqual(server["args"] as? [String], ["serve", "--stdio", "--client", "paper-rss-settings"])
        XCTAssertEqual((server["env"] as? [String: String])?["PAPERRSS_AGENT_ENABLED"], "1")
        XCTAssertTrue(result.contains("[mcp_servers.paperrss.env]"))
        XCTAssertFalse(result.contains("--fixture"))
        XCTAssertFalse(result.contains("swift build"))
        let missing = AgentMCPConnectCopy.text(path: nil, english: true)
        XCTAssertTrue(missing.contains(AgentMCPConnectCopy.placeholder))
        XCTAssertTrue(missing.contains("swift build --product paperrss-agent"))
    }
}
