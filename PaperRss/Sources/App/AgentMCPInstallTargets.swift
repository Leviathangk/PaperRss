#if os(macOS)
import Foundation

enum AgentMCPInstallTarget: String, CaseIterable, Identifiable {
    case cursor, vscode, vscodeInsiders, claudeCode, codex, claudeDesktop, windsurf, geminiCLI
    enum Kind { case deeplink, command, jsonSnippet }
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vscodeInsiders: return "vscode-insiders"
        case .claudeCode: return "claude-code"
        case .claudeDesktop: return "claude-desktop"
        case .geminiCLI: return "gemini-cli"
        default: return rawValue
        }
    }
    var name: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .vscodeInsiders: return "VS Code Insiders"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .claudeDesktop: return "Claude Desktop"
        case .windsurf: return "Windsurf / Devin Desktop"
        case .geminiCLI: return "Gemini CLI"
        }
    }
    var kind: Kind {
        switch self {
        case .cursor, .vscode, .vscodeInsiders: return .deeplink
        case .claudeCode, .codex: return .command
        case .claudeDesktop, .windsurf, .geminiCLI: return .jsonSnippet
        }
    }
    private func server(path: String) -> [String: Any] {
        ["command": path, "args": ["serve", "--stdio", "--client", label], "env": ["PAPERRSS_AGENT_ENABLED": "1"]]
    }
    private func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    private func encode(_ value: String, allowed: String) -> String {
        value.utf8.map { byte in
            if allowed.utf8.contains(byte) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    private var uriAllowed: String { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()" }
    func url(path: String) -> URL? {
        switch self {
        case .cursor:
            let base64 = Data(json(server(path: path)).utf8).base64EncodedString()
            return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=paperrss&config=\(encode(base64, allowed: uriAllowed))")
        case .vscode, .vscodeInsiders:
            var object = server(path: path)
            object["name"] = "paperrss"
            object["type"] = "stdio"
            let scheme = self == .vscode ? "vscode" : "vscode-insiders"
            return URL(string: "\(scheme):mcp/install?\(encode(json(object), allowed: uriAllowed))")
        default: return nil
        }
    }
    func command(path: String) -> String? {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch self {
        case .claudeCode: return "claude mcp add --scope user --env PAPERRSS_AGENT_ENABLED=1 --transport stdio paperrss -- \(quoted) serve --stdio --client \(label)"
        case .codex: return "codex mcp add paperrss --env PAPERRSS_AGENT_ENABLED=1 -- \(quoted) serve --stdio --client \(label)"
        default: return nil
        }
    }
    func snippet(path: String) -> String? {
        guard kind == .jsonSnippet else { return nil }
        let data = try! JSONSerialization.data(withJSONObject: ["mcpServers": ["paperrss": server(path: path)]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    func configNote(english: Bool) -> String? {
        let note: String
        switch self {
        case .claudeDesktop:
            note = english ? "Merge into ~/Library/Application Support/Claude/claude_desktop_config.json (Claude menu → Settings… → Developer → Edit Config); keep other servers and fully quit and relaunch Claude." : "合并到 ~/Library/Application Support/Claude/claude_desktop_config.json（Claude 菜单 → Settings… → Developer → Edit Config）；保留其他服务器，完全退出并重新打开 Claude。"
        case .windsurf:
            note = english ? "Merge into ~/.config/devin/mcp_config.json (legacy Windsurf: ~/.codeium/windsurf/mcp_config.json); keep other servers and refresh the MCP list in Cascade or restart." : "合并到 ~/.config/devin/mcp_config.json（旧版 Windsurf：~/.codeium/windsurf/mcp_config.json）；保留其他服务器，在 Cascade 刷新 MCP 列表或重启。"
        case .geminiCLI:
            note = english ? "Merge under mcpServers in ~/.gemini/settings.json (user scope); keep other servers and restart the app." : "合并到 ~/.gemini/settings.json（用户级）的 mcpServers 中；保留其他服务器并重启应用。"
        default: return nil
        }
        return note
    }
}
#endif
