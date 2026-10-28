#if os(macOS)
import Foundation

enum AgentMCPInstallTarget: String, CaseIterable, Identifiable {
    case cursor, vscode, vscodeInsiders, claudeCode, codex
    enum Kind { case deeplink, command }
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vscodeInsiders: return "vscode-insiders"
        case .claudeCode: return "claude-code"
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
        }
    }
    var kind: Kind {
        switch self {
        case .cursor, .vscode, .vscodeInsiders: return .deeplink
        case .claudeCode, .codex: return .command
        }
    }
    var bundleIdentifier: String? {
        switch self {
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .vscode: return "com.microsoft.VSCode"
        case .vscodeInsiders: return "com.microsoft.VSCodeInsiders"
        case .claudeCode, .codex: return nil
        }
    }
    var iconAssetName: String {
        switch self {
        case .cursor: return "AgentMCPCursor"
        case .vscode, .vscodeInsiders: return "AgentMCPVSCode"
        case .claudeCode: return "AgentMCPClaude"
        case .codex: return "AgentMCPCodex"
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
}
#endif
