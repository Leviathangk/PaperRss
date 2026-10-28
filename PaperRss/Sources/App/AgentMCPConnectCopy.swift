#if os(macOS)
import Foundation

struct AgentMCPConnectCopy {
    static let placeholder = "/ABS/PATH/TO/paperrss-agent"

    static func helperPath(bundleURL: URL = Bundle.main.bundleURL,
                           homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        var candidates = [
            bundleURL.appendingPathComponent("Contents/MacOS/paperrss-agent"),
            bundleURL.appendingPathComponent("Contents/Resources/paperrss-agent")
        ]
        var directory = bundleURL
        while directory.path != "/" {
            candidates.append(directory.appendingPathComponent(".build/debug/paperrss-agent"))
            directory.deleteLastPathComponent()
        }
        candidates.append(homeURL.appendingPathComponent("Desktop/code/paper-rss-workspace/PaperRss/.build/debug/paperrss-agent"))
        return candidates.map { $0.standardizedFileURL.path }.first(where: isExecutable)
    }

    static func text(path: String?, english: Bool) -> String {
        let command = path ?? placeholder
        // JSON string escaping also produces a valid TOML basic string for file paths.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let quoted = String(data: try! encoder.encode(command), encoding: .utf8)!
        let intro = english
            ? "Connect PaperRss MCP to this client. Keep PaperRss open and enable Settings → General → Connect External Assistants. Merge the configuration below without removing other servers. Reconnect and call paperrss_status; expect transport=unix_socket."
            : "请将 PaperRss MCP 接入当前客户端。保持 PaperRss 运行，并打开设置 → 常规 →「连接外部助手」。合并以下配置，保留其他 server。重连后调用 paperrss_status，期望 transport=unix_socket。"
        let buildHint = path == nil
            ? (english ? "\nFirst run swift build --product paperrss-agent in the PaperRss repository and replace the placeholder with its absolute path." : "\n请先在 PaperRss 仓库运行 swift build --product paperrss-agent，并将占位符替换为产物绝对路径。")
            : ""
        return """
        \(intro)\(buildHint)

        ### Cursor / Claude (mcp.json)
        {
          "mcpServers": {
            "paperrss": {
              "command": \(quoted),
              "args": ["serve", "--stdio", "--client", "paper-rss-settings"],
              "env": {"PAPERRSS_AGENT_ENABLED": "1"}
            }
          }
        }

        ### Codex (config.toml)
        [mcp_servers.paperrss]
        command = \(quoted)
        args = ["serve", "--stdio", "--client", "paper-rss-settings"]

        [mcp_servers.paperrss.env]
        PAPERRSS_AGENT_ENABLED = "1"
        """
    }
}
#endif
