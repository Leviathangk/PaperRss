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
        XCTAssertTrue(result.contains("设置 → AI → MCP"))
        XCTAssertTrue(result.contains("重新复制配置"))
        let missing = AgentMCPConnectCopy.text(path: nil, english: true)
        XCTAssertTrue(missing.contains(AgentMCPConnectCopy.placeholder))
        XCTAssertTrue(missing.contains("swift build --product paperrss-agent"))
        for english in [false, true] {
            let release = AgentMCPConnectCopy.text(path: nil, english: english, isDebug: false)
            XCTAssertTrue(release.contains(english ? "Please reinstall PaperRss" : "请重新安装 PaperRss"))
            XCTAssertFalse(release.contains("swift build"))
        }
        let english = AgentMCPConnectCopy.text(path: path, english: true)
        XCTAssertTrue(english.contains("Settings → AI → MCP"))
        XCTAssertTrue(english.contains("copy the configuration again"))
    }
}
