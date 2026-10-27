# 本地 Agent / MCP：可编译 spike 验收

2026-10-27，基线 `9360d39`。实现依据是 Oliver 提供的 `documents/research/paperrss-agent-integration-cli-mcp.md` §10–§12；该研究文件目前仅存在主 checkout 的未提交资料中，本 worktree 未修改它。

**这是安全边界和业务核心的技术 spike，尚不能用 MCP 客户端操作真实阅读库。** 交付 Core + 可替换 `AgentBridge` + stdio helper；生产 UDS、配对、确认界面与签名打包留待下一步。未做 #57 滚动标已读。没有 HTTP 端口、launchd、云连接、自动抓取、导出或自动删文。

## 已实现与责任边界

- `PaperRssAgentProtocol` 位于 Core/AgentProtocol，只依赖 Foundation，定义 JSON DTO 和桥接口。helper 依赖此模块及 MCP 模块，**不依赖 PaperRssCore/SQLite/CloudKit**，没有数据库路径、RSS 凭据和 AI Key。
- `AgentLibraryService` 由 App 注入已初始化的 LibraryDatabase，复用 LocalAccountProvider、TimelineQueryService、ArticleStateRepository、ArticlePreparationEngine。不会自行创建库或启动同步。
- Core 支持允许账户内的 Feed 分页/未读计数、unread/starred/selection 元数据、Feed/时间/标题与截断摘要筛选、单篇详情。没有全文搜索、刷新、隐式已读；正文、标题、摘要均标记不可信。
- 正文必须经过 App-only `authorizeContent` 钩子生成 selection（最多 20 篇，15 分钟）；每次一篇，最多 20,000 Unicode scalar，默认 8,000。固定 `.storedContent`，不抓网页，不写缓存。标题/摘要/正文共用默认 100,000 字符的会话账本；每分钟最多 60 个业务调用。分页最多 50 条。
- Core 状态命令先冻结 ID/前置状态，App-only `approve` 签发 approval，再单事务校验并设置 read/starred。过期、错误审批、冲突、数据库失败不返回成功；相同幂等键重试返回原 receipt。只支持 local 类型账户，iCloud/FreshRSS/Miniflux 均拒绝写入；receipt 的 `sync=not_applicable` 不冒充远端同步成功。
- `AgentBridgeController.shared` 在 App 初始化挂接一次，不在窗口出现时创建。真实 App 会话仅允许本地未读元数据和显式 selection 内容，**暂不启用 state.write**。确认钩子未接入 UI，外部工具不能签发审批。
- 10 个 MCP 工具均注册、严格校验参数（含 additionalProperties:false）。三个 Feed 写工具是明确的可编译契约 stub：Core 返回 `UNSUPPORTED`，fixture 返回 `CONFIRMATION_REQUIRED`，均不执行写入、不能完成审批。工具执行结果包含 `api_version: "1"`，失败带 `isError: true`、结构化错误码；不会吞掉数据库错误后假装成功。

## 开启方式与构建

默认两个入口都关闭，不自动安装任何系统服务或修改客户端配置。

**独立 helper 冒烟**使用环境变量 `PAPERRSS_AGENT_ENABLED=1`，仅对本次进程生效。必须加 `--fixture` 才能读纯内存的合成数据；无 fixture 时即使启用也只会返回 `APP_NOT_RUNNING`（说明 IPC 尚未实现），绝不退回直接开库。

```sh
cd /absolute/path/to/PaperRss
swift build --product paperrss-agent
PAPERRSS_AGENT_ENABLED=1 .build/debug/paperrss-agent serve --stdio --fixture --client oliver-qa
```

stdio stdout 只输出协议消息。没有额外 Node/Python runtime 依赖。使用最小手写 JSON-RPC，避免 spike 新增 MCP SDK 依赖；支持 initialize、ping、tools/list、tools/call、cancelled 通知，64 KiB 请求帧上限和并发上限。协议版本协商覆盖 2025-11-25、2025-06-18、2024-11-05；未宣称完整 MCP conformance。客户端应发送 `notifications/initialized`；当前服务端兼容地容忍 initialize 后、该通知前的工具调用，不主动向客户端发请求。

**App 内部 enable gate** 是 `UserDefaults` 的 `PaperRss.agentMCPEnabled`，缺省 false。隔离测试可向独立 defaults suite 写 true；隔离 App 手动 QA 可用启动参数 `-PaperRss.agentMCPEnabled YES`。这只打开进程内桥接 seam，**不会让外部 helper 连通**。实际传输接入前需要完成配对和确认 UI。关闭 flag 后每次桥调用拒绝访问，`stop()` 撤销会话。这里没有执行上述 App 启动，也没有改写日常 App 偏好。

## 客户端 stdio 配置（仅合成数据 QA）

将 command 换成这次构建产物的绝对路径；不要填写数据库路径或任何 Key。以下配置由 Oliver 自行加入本地客户端，本文不安装配置。

Claude Desktop 的开发者配置 `claude_desktop_config.json` 和 Cursor 的用户级 `mcp.json` 使用：

```json
{
  "mcpServers": {
    "paperrss-spike": {
      "command": "/absolute/path/to/PaperRss/.build/debug/paperrss-agent",
      "args": ["serve", "--stdio", "--fixture", "--client", "oliver-qa"],
      "env": {"PAPERRSS_AGENT_ENABLED": "1"}
    }
  }
}
```

Codex 本地 `config.toml` 示例：

```toml
[mcp_servers.paperrss_spike]
command = "/absolute/path/to/PaperRss/.build/debug/paperrss-agent"
args = ["serve", "--stdio", "--fixture", "--client", "oliver-qa"]

[mcp_servers.paperrss_spike.env]
PAPERRSS_AGENT_ENABLED = "1"
```

配置字段参考 [Cursor 官方 MCP 文档](https://prod.cursor.com/docs/mcp)、[OpenAI 官方 Codex MCP 文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)。[Claude Desktop 当前官方说明](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)主要介绍扩展安装；上面的 JSON 是手动开发者配置，需在实际客户端版本核验。尚未运行三个 GUI 客户端，不把示例当作客户端兼容性已验收。

## Oliver 冒烟清单

1. 构建后配置 helper，工具列表应恰好 10 项。调用 `paperrss_status {}`，应显示 fixture、允许账户 `fixture-local`、只读元数据能力。
2. `paperrss_list_feeds {"account_id":"fixture-local"}` 返回一个合成 Feed；`paperrss_list_articles {"account_id":"fixture-local","scope":"unread","query":"Swift","limit":20}` 返回一个合成文章。
3. `paperrss_get_article {"account_id":"fixture-local","article_id":"fixture-article"}` 没有正文；伪造 selection 调用 get_content 必须 UNAUTHORIZED；写工具返回错误，不产生真实操作。
4. 加未知字段、limit=51、scope=all、重复 article_ids，应 INVALID_ARGUMENT；换账户应 UNAUTHORIZED。
5. 去掉环境变量并重启 helper，应 NOT_ENABLED。保留环境变量但移除 --fixture，应 APP_NOT_RUNNING，任何时候都不读取日常库。
6. Core 的审批→原子提交→冲突/幂等闭环由下面隔离库测试验证；不能以 fixture 成功替代真实 App/双窗口/同步验收。

## 自动化证据

常规入口：

```sh
./scripts/verify.sh --filter 'AgentLibraryServiceTests|AgentMCPTests|AgentBridgeControllerTests'
```

本次运行环境限制写入默认 Clang 缓存且不允许 SwiftPM 嵌套 sandbox，因此通过同一报告/锁入口运行等价命令（外层工作区沙箱仍有效）：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/build/agent-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/agent-module-cache" \
PAPERRSS_RUN_GUI_TESTS=0 PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS=0 \
python3 scripts/build-support.py --lane tests --temporary -- \
  swift test --disable-sandbox --scratch-path "$PWD/.build" --skip-update \
  --filter 'AgentLibraryServiceTests|AgentMCPTests|AgentBridgeControllerTests'
```

测试使用临时 SQLite fixture，不启动真实 GUI App。完整日志在 `build/reports/`，最终执行结果见下方交付记录。

## 相对调研 MVP 的已知缺口

- **没有真实 IPC/配对/签名 bundle helper/启动安装链路**。App 内确认 UI 和会话管理尚未完成；外部客户端目前只能 smoke 合成只读数据。
- Feed CRUD 三个写工具为 stub；未实现 URL 重定向/私网源授权，绝不发起 Feed 网络请求。未做到完整业务 MVP。
- App 实际写入关闭；Core 写入只验证 local 隔离库。无跨设备服务、双窗口并发验收；无撤销或清理保留期，审批 DTO 明确提示读/星标变化可能触发既有保留策略。
- 前置状态使用现有完整 ArticleStateRecord（含 updatedAt）保守比较：另一字段变更也会冲突，不支持可靠单调 revision/ABA 保证。进入生产需改善字段独立版本。
- 计划、selection、幂等 receipt 仅保存在同一服务会话内；重启后旧计划不可执行，不提供跨进程崩溃后的持久审计/receipt 恢复。
- 分页是绑定查询和会话的短期 opaque **live-offset cursor**，不是冻结快照/稳定 keyset；并发增删可能产生遗漏或重复。每次最多扫描 500 候选，未命中时也可能返回可继续扫描的 cursor。
- 仅允许本地账户；status 能力、配额为单会话。跨客户端全局限额、正式撤销通知、睡眠/升级生命周期还未接入。
- 隐去 Feed URL，文章 URL 带 userinfo/query/fragment 时拒绝提供。不能自动识别所有 URL path 内秘密，正式对外接入前还需来源级出库策略。文章纯文本可能包含敏感内容；selection 确认需明确“助手可能将其发给自己的模型服务”，并遵守 CONTENT_NOTICE / PRIVACY；本地 stdio 不等于模型处理只在本机。

## 本次交付记录

- 最终 SwiftPM 编译与测试退出码 0：**58 项，0 失败**（Agent Core 17、正文准备引擎 31、App gate 1、MCP 9）。同时编译 PaperRssCore、PaperRssDesktop 和 paperrss-agent。日志：`build/reports/run-rx2h9s9a.log`。
- 编译产物真实 stdio 子进程 3 场景通过：默认关闭、启用无 IPC、fixture 查询；正常 EOF 退出。日志：`build/reports/agent-mcp-product-smoke.log`。这是协议冒烟，不是 Claude/Cursor/Codex GUI 客户端验收。
- `git diff --check`、Xcode 工程 plist 语法校验通过。helper 的动态依赖没有 SQLite/CloudKit。
- Xcode 原生工程构建**未通过环境阶段**：SwiftPM manifest diagnostics 尝试写入沙箱外 `~/Library/Caches/org.swift.swiftpm` 被拒绝；完整日志 `build/reports/run-7kf74x95.log`。不能据 SwiftPM 编译结果声称已验证 Xcode bundle 构建/签名/打包。
- 没有启动日常 App、打开生产阅读库或执行真实服务写入；没有修改全局 MCP 配置。
- worktree：`/Users/yangbukun/.codex/worktrees/b9dd/PaperRss`。
- Git：仍为 **detached HEAD @ 9360d39**；创建 `codex/agent-mcp-spike` 时，共享 `.git` 位于沙箱外，写入 ref lock 被拒绝。因此没有新分支或本地 commit；改动完整保留在本 worktree。未 stage、merge、push、PR、tag 或 release，也未修改其他 worktree。
- 审阅补丁：`build/reports/agent-mcp-spike.patch`（包括新增文件）；Git 清单与关键绝对路径：`build/reports/agent-mcp-handoff.txt`。在允许写共享 Git 元数据的环境中再创建分支并提交即可，不要清理此 worktree。
