# 本地 Agent / MCP：UDS MVP 验收

2026-10-27；在 `codex/agent-mcp-spike` / `8c78350` 上继续实现。研究依据：只读参考 `documents/research/paperrss-agent-integration-cli-mcp.md` §10–§12，该未跟踪副本不提交。

**helper 不带 `--fixture` 时已接入 App 的 Unix domain socket；App 使用自己已打开的 LibraryDatabase 提供查询。** 默认关闭。自动化使用隔离库和真实 socket，不等同于日常库、GUI 客户端或签名安装包验收。当前交付优先满足本地账户的 status、Feed 列表、文章列表、元数据及显式授权的已有正文。

## 数据与安全边界

- helper 仅依赖 `PaperRssAgentProtocol`、`PaperRssAgentMCP`；不链接 PaperRssCore、SQLite、CloudKit，不持有 RSS 凭据或 AI Key。App → LibraryDatabase 是唯一数据所有者。
- 默认目录为 `/tmp/paperrss-agent-$(id -u)`（macOS `/tmp` 指向 `/private/tmp`），socket 为该目录的 `bridge.sock`。目录 0700，socket、`token`、`owner`、`state` 文件 0600；检查当前 UID、文件类型、权限，拒绝符号链接凭据与不安全目录。双端检查 Unix peer UID。
- 开启后 App 生成随机 token；helper 从同目录读取，token 不进 argv、MCP 配置或日志。握手包含协议版本，App 返回实例 ID。每次重新开启轮换 token；不支持匿名读取。
- 这是**当前 macOS 用户范围的信任**，并非代码签名绑定或逐客户端人工配对。同用户能读取 token 的进程也能连接；`--client` 只是标签，不是身份。每个已认证连接独立授权、预算、游标；断开撤销。不要把任意同用户进程视为已隔离的安全主体。
- App 初始化库成功后取得 `owner` 排他锁。OFF 保留 owner 锁和 disabled 状态，移除数据 listener/token，并撤销已有会话；进程退出释放锁。helper 据此区分 `NOT_ENABLED` 与 `APP_NOT_RUNNING`。崩溃留下的 socket 只有在持有 owner 锁且确认无活跃 listener 后才清理；拒绝覆盖活跃实例。OFF 只留下状态文件，不提供库查询端口。
- UDS 采用长度前缀 JSON；请求上限 64 KiB、响应上限 1 MiB，有限连接数、15 秒阻塞读写超时；认证后空闲等待不主动断开，阻塞 I/O 在后台队列。stdio stdout 只输出 JSON-RPC。无 TCP/HTTP 端口、launchd、云连接、自动打开 App 或全库导出。
- 元数据允许本地账户 unread/starred/selection；正文最多选 20 篇，每篇最多 20,000 字符，默认 8,000，selection 有效 15 分钟。每会话共享默认 100,000 字符预算及每分钟 60 个业务调用。正文仅用已存内容，不抓网页、不写缓存、不隐式标已读。文章文本全部视为不可信输入。
- 真实 App 的 state.write 仍关闭，Feed CRUD 为 stub；未实现 #57 滚动标已读。本轮没有更改同步、保留或清理策略。

## 构建与启用

以下均在本 worktree 执行。构建本身不启动 App：

```sh
cd /Users/yangbukun/.codex/worktrees/b9dd/PaperRss
swift build --product paperrss-agent
./scripts/dev.sh --build-only
```

原生 App：`build/Build/Products/Debug/PaperRss.app`。如果本机 Xcode 签名/构建环境受限，可用 `swift build --product PaperRssDesktop`，然后使用 `.build/debug/PaperRssDesktop` 做 Debug QA；这不证明原生 bundle 签名/分发成功。

启动真实库实例前正常退出旧 PaperRss，并按 [开发数据备份](../../.agents/docs/dev-data-backup.md) 保存一致快照。不要同时启动第二个使用同一库的 App。App 正常初始化本身可能执行原有迁移、同步和刷新，因此不能把“Agent 查询只读”理解成整个 App 启动只读。

本次进程启用（推荐 QA，不保存全局偏好）：

```sh
./build/Build/Products/Debug/PaperRss.app/Contents/MacOS/PaperRss \
  -PaperRss.agentMCPEnabled YES
# SwiftPM 备选：
# .build/debug/PaperRssDesktop -PaperRss.agentMCPEnabled YES
```

持久偏好方式（原生 bundle ID）：

```sh
defaults write com.yangbukun.PaperRss PaperRss.agentMCPEnabled -bool YES
```

退出再启动本次构建产物。关闭时退出，再以 `-PaperRss.agentMCPEnabled NO` 启动；或 `defaults write ... -bool NO` 后重启。启动参数优先于持久 defaults；外部 `defaults write` 的跨进程实时通知不作为本轮保证。App 内同一 defaults 对象变更会驱动 listener 关闭，每次业务调用也再次检查开关。

**helper 还有独立进程开关** `PAPERRSS_AGENT_ENABLED=1`，两个开关都必需。helper 不会自动打开 App。`PAPERRSS_AGENT_SOCKET_DIR` 仅供隔离 socket 冒烟测试覆盖 helper 目录；日常 QA 不设置，App 使用固定默认目录。

## 客户端配置（真实 App，无 --fixture）

将 command 换成本 worktree 编译产物的绝对路径。Claude Desktop 开发者配置 `claude_desktop_config.json` / Cursor `mcp.json` 示例：

```json
{
  "mcpServers": {
    "paperrss-local": {
      "command": "/Users/yangbukun/.codex/worktrees/b9dd/PaperRss/.build/debug/paperrss-agent",
      "args": ["serve", "--stdio", "--client", "oliver-qa"],
      "env": {"PAPERRSS_AGENT_ENABLED": "1"}
    }
  }
}
```

Codex 本地 `config.toml` 示例：

```toml
[mcp_servers.paperrss_local]
command = "/Users/yangbukun/.codex/worktrees/b9dd/PaperRss/.build/debug/paperrss-agent"
args = ["serve", "--stdio", "--client", "oliver-qa"]

[mcp_servers.paperrss_local.env]
PAPERRSS_AGENT_ENABLED = "1"
```

保存后重新连接对应 MCP server。这里没有修改任何全局客户端配置，也没有验收三个客户端 GUI。stdio 支持 initialize、ping、tools/list、tools/call、cancelled 通知；工具数 10，失败包含 `isError: true` 与结构化错误码。协议版本覆盖 2025-11-25、2025-06-18、2024-11-05；不是完整 MCP conformance 声明。

## Debug 正文授权路径

正式确认 UI 尚未接入。本轮提供**App 侧、仅 Debug、显式篇目、一次启动一次**的 QA consent。**不能热授权**：必须先 metadata 拿真实 `article_id` → 退出 App → 带 QA argv 重启 → 同一 MCP 连接再用 `selection_ids[0]` 调 `get_content`（详见下方「验收说明」置顶）。等 App **窗体就绪**再连 helper。

1. 先用 metadata 工具取得真实文章 ID，人工检查并选 1–20 篇。正文可能被客户端送到它配置的模型服务；仅选择同意外发的篇目。
2. 断开所有测试 MCP 客户端，正常退出 App，再在终端启动 App，指定所选 ID：

```sh
./build/Build/Products/Debug/PaperRss.app/Contents/MacOS/PaperRss \
  -PaperRss.agentMCPEnabled YES \
  --agent-qa-allow-content-egress \
  --agent-qa-content-ids 'ARTICLE_ID_1,ARTICLE_ID_2'
```

SwiftPM 备选将可执行文件替换为 `.build/debug/PaperRssDesktop`。不能把这些 App 参数放到 helper args。

3. 启动后 15 分钟内只连接预期的一个 MCP helper，首先调用 `paperrss_status {}`。App 将固定篇目授予第一个发起业务调用的连接；读取返回的 `selection_ids[0]`。该 selection 自签发起有效 15 分钟，不自动续期。
4. 使用同一个 MCP 连接调用 `paperrss_get_content`，传入 account_id、article_id、selection_id。selection 不跨连接共享；只读列表不会标已读。未指定双重 QA 参数、Release 构建、任意伪造 selection 均不会获得正文授权。
5. 关闭 App 开关、断开该 helper 或退出 App 都会撤销授权；重新连接不会自动领取第二份 QA grant。要重新授权须重新人工启动 App。验证完退出并去掉上述 QA 参数，勿保存为日常启动配置。

这条路径没有 MCP 自批准工具。它是临时 QA 入口：首个连接领取意味着测试时必须控制同用户其他 helper；正式版本仍需要可见的逐客户端配对、篇目确认和撤销 UI。

## 验收说明（可直接发 Bro / Oliver）

**置顶（明早真库冒烟必读）**

1. **可执行文件**：本 worktree 若尚无原生 `PaperRss.app`，用 SwiftPM 产物 `.build/debug/PaperRssDesktop`。先编：`./scripts/dev.sh --build-only`，或 `swift build --product PaperRssDesktop` 与 `swift build --product paperrss-agent`。有 `build/Build/Products/Debug/PaperRss.app` 时优先用原生 bundle；两者均须本分支 Debug。
2. **开闸**：App `-PaperRss.agentMCPEnabled YES`（或 Desktop 等价）；helper 环境 `PAPERRSS_AGENT_ENABLED=1`；MCP args **不带 `--fixture`**。
3. **等窗体就绪再连 helper**：App 的 Agent attach / UDS listen 在库初始化后异步完成。窗体已出现、库可浏览后再连 MCP；过早连接可能短暂 `APP_NOT_RUNNING`，稍后再试即可。
4. **QA 两段式（不能热授权）**：
   - **第一段（仅 metadata）**：开闸启动 App（**不要**带 `--agent-qa-*`）→ 连 helper → `status` / `list_feeds` / `list_articles(unread)` / `get_article`，记下真实 `article_id`。
   - **退出**：断开所有 MCP，正常退出 App。
   - **第二段（正文）**：用同一批 ID 重启 App，加上 `--agent-qa-allow-content-egress --agent-qa-content-ids 'ID1,ID2'`（参数在 **App** argv，不是 helper）→ **等窗体就绪** → 再开**同一个** MCP 连接 → `paperrss_status` 取 `selection_ids[0]` → 同一连接 `get_content`。客户端不能自签 approval；不能在已运行进程上热加 QA 参数。

本轮已补上 helper → Unix socket → App-owned library。请用本分支 Debug App + helper。

**逐步核对**

1. `paperrss_status {}`：应返回 `enabled: true`、`paired: true`、`transport: "unix_socket"`，从 `accounts` 读取允许的本地 account_id（通常 `local-default`）。不能出现 `fixture: true`。
2. `paperrss_list_feeds {"account_id":"local-default","limit":20}`：返回 App 本地账户的真实订阅和计数。只有远端/iCloud账户时本地列表可能为空；本轮不开放这些账户。
3. `paperrss_list_articles {"account_id":"local-default","scope":"unread","limit":20}`：与 App 的本地未读文章核对。可加 feed_id、since、query；query 只搜索标题/摘要。再试 scope=starred。列表响应不含正文，不改变已读。
4. 从列表取真实 ID，`paperrss_get_article {"account_id":"local-default","article_id":"REAL_ID"}`：核对标题、状态和 content_available；无正文。超出 unread/starred/selection 范围的已读未星标文章应 UNAUTHORIZED。
5. 按置顶「QA 两段式」从 **App 终端参数**授权所选篇目，再从 status 取 `selection_ids[0]`，调用 `paperrss_get_content {"account_id":"local-default","article_id":"REAL_ID","selection_id":"STATUS_RETURNED_ID","max_chars":8000}`。应返回已存文本；检查原文章已读状态没变。没有已有正文时可能报内容不可用，不会隐式抓网页。
6. 同一连接伪造 selection 必须 UNAUTHORIZED；业务错误后有效 selection 仍可使用。另开 helper 不能复用该 selection。
7. helper 不设置启用环境变量 → NOT_ENABLED；App 运行但 flag OFF → NOT_ENABLED；App 退出/无 listener/崩溃残留 socket → APP_NOT_RUNNING。再次打开 App 后可重新连接；旧 selection 失效。过早连 helper 的短暂 `APP_NOT_RUNNING` 见置顶第 3 条。
8. 检查目录 0700、socket/token 0600（只查看权限，不把 token 内容贴群）。普通关闭 App 后应移除 socket/token；owner 文件可能保留但不再持锁。再次启动不得覆盖其它活跃实例。
9. Feed 写工具应明确 UNSUPPORTED；真实 App 的状态写工具应拒绝，不把 Core fixture 的写入测试当成真实写入能力。

离线 smoke 仍支持：

```sh
PAPERRSS_AGENT_ENABLED=1 .build/debug/paperrss-agent serve --stdio --fixture --client offline-qa
```

fixture 是纯合成数据；不能用它代替上面真实库验收。验收反馈请包含构建提交、客户端版本、调用参数（不含 token/正文秘密）、结构化错误码。

## 自动化与当前交付证据

常规入口：

```sh
./scripts/verify.sh --filter 'AgentLibraryServiceTests|AgentMCPTests|AgentBridgeControllerTests|AgentIPCTests|AgentIPCIntegrationTests'
```

当前执行环境默认 Clang 缓存位于沙箱外，普通入口在 manifest 编译阶段失败；使用同一报告/锁入口，将缓存限制在本 worktree，并关闭 SwiftPM 内层 sandbox（外层权限仍有效）：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/build/agent-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/agent-module-cache" \
PAPERRSS_RUN_GUI_TESTS=0 PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS=0 \
python3 scripts/build-support.py --lane tests --temporary -- \
  swift test --disable-sandbox --scratch-path "$PWD/.build" --skip-update \
  --filter 'AgentLibraryServiceTests|AgentMCPTests|AgentBridgeControllerTests|AgentIPCTests|AgentIPCIntegrationTests'
```

本轮最终结果（2026-10-27 Asia/Shanghai）：

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| SwiftPM / verify 相关测试 | **48 通过 / 0 失败**（Core 17 + App bridge 1 + IPC integration 10 + AgentIPC 11 + MCP 9） | `build/reports/agent-ipc-unsandboxed-verify.log` |
| Codex sandbox 曾阻断 UDS bind | 当时 31 通过 / 17 失败（环境 EPERM，非逻辑回归） | `build/reports/run-93rrh250.log`、`agent-ipc-sandbox-probe.json` |
| 普通终端 UDS bind 探针 | `bind_ok=true` | 本机补跑记录 |
| helper 产品子进程 smoke | 含 without `--fixture` / disabled / missing App / fixture | IPC / product smoke 日志 |
| 本地 commit | `c32854d`（及文档证据修正 commit，见 git log）在 `codex/agent-mcp-spike`；**未 push** | `git log -1` |
| 研究副本 | 仍 untracked，未 stage | `documents/research/paperrss-agent-integration-cli-mcp.md` |

**结论：** helper ↔ App UDS IPC 在普通本机自动化已跑通（隔离库 + temp socket）。这仍**不等于**日常生产库 + Claude/Cursor/Codex GUI 三端已验收；请按上方「验收说明」人工走真实库。未 merge/push/PR/tag/release。

交接文件：`build/reports/agent-mcp-ipc-handoff.md`；审阅补丁：`build/reports/agent-mcp-ipc.patch`。

## 剩余缺口

- 正式配对/确认/撤销 UI、签名 helper bundle、安装与升级链路尚未完成；只验证当前用户 token 信任模型，不保证 Mac App Store sandbox 可用。
- 真实 App/Claude Desktop/Cursor/Codex GUI 三端尚需按上述步骤人工验收。自动化使用 App 相同 controller/service 和隔离 SQLite 库，不是生产阅读库验收。
- 只支持本地账户；Feed CRUD、真实状态写入仍未开放。没有跨设备/iCloud/远端同步验收。
- 会话/selection/游标不持久化；断开或重启失效。预算为每连接，重新连接可获得新预算；正式版需要跨连接全局配额与可见授权管理。
- 分页是查询/会话绑定的短期 live-offset cursor，非冻结快照；并发增删可能重复或遗漏，每次最多扫描 500 候选。正文现有的会话限量不等于不可绕过的永久出库上限。
- URL 已过滤 userinfo/query/fragment，但无法识别所有 path 内秘密；正文授权仍需人工审查隐私和内容使用范围。本地传输不等于外部模型处理在本机。
- 未覆盖睡眠/恢复、升级重启竞争、故意慢速传输的完整压力测试，也未宣称正式生产安全验收完成。

## 普通终端补跑（2026-10-27 22:49 Asia/Shanghai）

Codex `workspace-write` 沙箱曾禁止 Unix socket `bind`（当时完整相关用例 31 通过 / 17 失败）。随后在**普通本机终端**（非 Codex sandbox）补跑：

- UDS bind 探针：`bind_ok=true`
- `./scripts/verify.sh --filter 'AgentLibraryServiceTests|AgentMCPTests|AgentBridgeControllerTests|AgentIPCTests|AgentIPCIntegrationTests'` → **exit 0**
- 日志：`build/reports/agent-ipc-unsandboxed-verify.log`
- 覆盖含真实 temp socket roundtrip、disabled/missing App、token/version 拒绝、stale reclaim、helper product without `--fixture`、App 隔离库正文授权路径等。

status DTO 已对齐：fixture / Core / App overlay 均提供 `paired` + `pair_state` + `transport`（fixture 另带 `fixture=true`；真实 UDS 连接 `transport=unix_socket`、`pair_state=local_user_token`）。

Bro 硬要求（UDS-only 非 fixture、enable gate listen/revoke、0700/0600+peer UID+token、QA-only 受信授权、status 字段统一、研究 `??` 不提交）已并入本轮实现。
