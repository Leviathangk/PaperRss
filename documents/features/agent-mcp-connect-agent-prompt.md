# PaperRss 本地 MCP 一键接入（粘贴给 Codex / Cursor Agent）

设置 → 常规 → 外部助手现已提供开关和「复制 MCP 配置与提示词」；下方长 prompt 作为备用。

把下面「PROMPT」整段复制给 Codex / Cursor Agent / Claude Code。它会：找到本机 PaperRss 工程 → 编译 helper → 开闸启动 App → 写入 Cursor / Claude / Codex 的 MCP 配置。

---

## PROMPT

```text
你是我的本机工程助手。请把 PaperRss 的本地 Agent MCP 接到我正在用的客户端上，做完直接汇报，少问问题。

## 目标
让 Cursor / Claude Desktop / Codex 能通过 stdio MCP 读我本机 PaperRss 里的订阅与文章（真实库，不要 fixture）。

## 仓库位置（按顺序找，找到就用）
1. ~/Desktop/code/paper-rss-workspace/PaperRss
2. 若没有，在 ~/Desktop/code 下找叫 PaperRss 的 git 根目录

## 硬性约束
- 不要 git push / 不要发版 / 不要改远程
- helper 启动参数不要加 --fixture
- App 必须先开着，且开闸：-PaperRss.agentMCPEnabled YES
- helper 环境变量必须有：PAPERRSS_AGENT_ENABLED=1
- 等 App 窗口出现后再测 MCP（过早会 APP_NOT_RUNNING）
- 本轮只接 metadata：status / list_feeds / list_articles / get_article；不要折腾 get_content 授权，除非我另说

## 步骤
1. cd 到仓库根；确认当前在 main（或已含 Agent MCP 的提交）。
2. 编译：
   - swift build --product paperrss-agent
   - ./scripts/dev.sh --build-only
3. 退出旧 PaperRss 进程（若有）。
4. 后台启动 App（注意：裸 ./scripts/dev.sh 不会带开闸参数，必须用编译产物）：
   ./build/Build/Products/Debug/PaperRss.app/Contents/MacOS/PaperRss -PaperRss.agentMCPEnabled YES
   （若没有 .app，改用 .build/debug/PaperRssDesktop 同样参数）
5. 确认存在 socket 目录：/tmp/paperrss-agent-$(id -u)/bridge.sock
6. 把 HELPER 绝对路径记下来：
   <REPO>/.build/debug/paperrss-agent
7. 按我当前客户端写入 MCP 配置（存在就合并 paperrss 条目，不要抹掉其它 server）：

### Cursor
文件通常是：
- ~/.cursor/mcp.json
或项目内 .cursor/mcp.json
写入：
{
  "mcpServers": {
    "paperrss": {
      "command": "<HELPER绝对路径>",
      "args": ["serve", "--stdio", "--client", "oliver-qa"],
      "env": { "PAPERRSS_AGENT_ENABLED": "1" }
    }
  }
}

### Claude Desktop
~/Library/Application Support/Claude/claude_desktop_config.json
结构同上 mcpServers.paperrss。

### Codex
~/.codex/config.toml 追加：
[mcp_servers.paperrss]
command = "<HELPER绝对路径>"
args = ["serve", "--stdio", "--client", "oliver-qa"]

[mcp_servers.paperrss.env]
PAPERRSS_AGENT_ENABLED = "1"

8. 冒烟：用 MCP 调 paperrss_status，期望 enabled=true、transport=unix_socket、fixture 不为 true。再 list_feeds 一次。

## 回报给我（简短）
- 用的仓库路径与 helper 路径
- 改了哪个配置文件
- status 是否成功；失败就贴错误码（APP_NOT_RUNNING / NOT_ENABLED 等）和下一步
```

---

## 产品上更省事的后续（给自己记）

短期靠上面粘贴 prompt 就够开发/自用。对普通用户更合适的顺序：

1. **设置页开关与复制配置**已实现；一键写入 Cursor 尚未实现
2. **`paperrss-agent setup-mcp --client cursor|claude|codex`**：自动解析 App 内嵌 helper 路径并写配置
3. **把 helper 打进 App bundle**（签名），用户不必自己 `swift build`
4. 正式配对 UI 后再开放正文 `get_content`

设置开关与启动参数 / defaults 使用同一个偏好键。
