import Foundation
import XCTest
@testable import PaperRssDesktop

final class AgentMCPInstallTargetsTests: XCTestCase {
    let path = "/Applications/Paper Rss's.app/Contents/MacOS/paperrss-agent"

    func assertServer(_ server: [String: Any], label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(server["command"] as? String, path, file: file, line: line)
        XCTAssertEqual(server["args"] as? [String], ["serve", "--stdio", "--client", label], file: file, line: line)
        XCTAssertEqual(server["env"] as? [String: String], ["PAPERRSS_AGENT_ENABLED": "1"], file: file, line: line)
    }
    func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
    func testCursorLink() throws {
        let raw = try XCTUnwrap(AgentMCPInstallTarget.cursor.url(path: path)?.absoluteString)
        XCTAssertTrue(raw.hasPrefix("cursor://anysphere.cursor-deeplink/mcp/install?name=paperrss&config="))
        let encoded = try XCTUnwrap(raw.components(separatedBy: "config=").last)
        XCTAssertFalse(encoded.contains("+")); XCTAssertFalse(encoded.contains("/")); XCTAssertFalse(encoded.contains("="))
        let base64 = try XCTUnwrap(encoded.removingPercentEncoding)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        assertServer(try object(String(decoding: data, as: UTF8.self)), label: "cursor")
    }
    func testVSCodeLinks() throws {
        for target in [AgentMCPInstallTarget.vscode, .vscodeInsiders] {
            let raw = try XCTUnwrap(target.url(path: path)?.absoluteString)
            let scheme = target == .vscode ? "vscode" : "vscode-insiders"
            XCTAssertTrue(raw.hasPrefix("\(scheme):mcp/install?"))
            XCTAssertFalse(raw.hasPrefix("\(scheme)://"))
            let query = try XCTUnwrap(raw.components(separatedBy: "?").last?.removingPercentEncoding)
            let value = try object(query)
            XCTAssertEqual(value["name"] as? String, "paperrss")
            XCTAssertEqual(value["type"] as? String, "stdio")
            assertServer(value, label: target.label)
            XCTAssertTrue(raw.contains("'"))
        }
    }
    func testCommands() {
        let quoted = "'/Applications/Paper Rss'\\''s.app/Contents/MacOS/paperrss-agent'"
        XCTAssertEqual(AgentMCPInstallTarget.claudeCode.command(path: path), "claude mcp add --scope user --env PAPERRSS_AGENT_ENABLED=1 --transport stdio paperrss -- \(quoted) serve --stdio --client claude-code")
        XCTAssertEqual(AgentMCPInstallTarget.codex.command(path: path), "codex mcp add paperrss --env PAPERRSS_AGENT_ENABLED=1 -- \(quoted) serve --stdio --client codex")
    }
    func testSnippetsAndLabels() throws {
        XCTAssertEqual(Set(AgentMCPInstallTarget.allCases.map(\.label)).count, AgentMCPInstallTarget.allCases.count)
        for (target, configPath) in [(AgentMCPInstallTarget.claudeDesktop, "~/Library/Application Support/Claude/claude_desktop_config.json"), (.windsurf, "~/.config/devin/mcp_config.json"), (.geminiCLI, "~/.gemini/settings.json")] {
            let snippet = try XCTUnwrap(target.snippet(path: path))
            let servers = try XCTUnwrap(try object(snippet)["mcpServers"] as? [String: Any])
            assertServer(try XCTUnwrap(servers["paperrss"] as? [String: Any]), label: target.label)
            let note = try XCTUnwrap(target.configNote(english: true))
            XCTAssertTrue(note.contains(configPath))
            XCTAssertTrue(note.contains("keep other servers"))
        }
    }
}
