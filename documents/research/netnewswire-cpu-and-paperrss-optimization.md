# NetNewsWire 低 CPU 占用机制与 PaperRss 优化方向

> 调研日期：2026-10-13
>
> 适用范围：macOS 静止阅读、轻量 Feed 切换与批量刷新
>
> 状态：调研完成，待计划实施；本文不代表优化已经落地或达到性能目标。
>
> 待办入口：[每周想法与待办](../../weekly.md)

## 1. 结论与证据边界

NetNewsWire 值得借鉴的机制是：在进入解析、数据库写入和界面更新之前尽早跳过无变化的工作，变化发生后也尽量只更新受影响内容。源码不能证明它在所有负载下都低于某个固定 CPU 百分比。

PaperRss 本轮最明确的两个优化方向是：

1. **音频波形的持续计算与桥接成本**：运行采样已观察到频谱计算、音频缓冲处理和逐帧字符串格式化。
2. **无内容变化的刷新仍触发重查与发布**：源码确认 304 结果仍可能引发全局计数查询、列表版本更新和整轮状态重载。

前者是本轮持续 CPU 占用的显著热点；后者是已确认的重复工作路径，但其实际 CPU 贡献尚未单独测量。其余标读、解析与批量读库建议属于源码支持的优化候选。

### 调研对象

| 对象 | 本轮确认的信息 | 使用边界 |
| --- | --- | --- |
| NetNewsWire 安装包 | 7.1.1 / build 7108，原生 arm64 运行 | REA 检查安装包身份；系统工具采样运行进程 |
| NetNewsWire 本地源码 | `NetNewsWire-main` 快照，7.1.3b4 / build 7205，没有 `.git` | 不能核实提交身份，也不能把全部源码机制直接归因于已装 7.1.1 |
| PaperRss 运行实例 | 1.4.5 / build 41，Debug-iCloud；采样包含 `PaperRss.debug.dylib` | 对应配置使用 `SWIFT_OPTIMIZATION_LEVEL = -Onone`，不能直接与竞品发布版计算性能差距 |
| PaperRss 源码 | 调研时的工作区代码，存在未提交修改 | 文件与符号定位仅代表调研时点，后续实施前需核对当前实现 |

本轮使用 REA 的 Mach-O、plist 检查，普通源码阅读，以及系统 `sample` / `top`。没有进行函数反编译、控制两端执行相同操作、切换功能做 A/B，或触发真实数据刷新。

## 2. 运行证据摘要

### 主进程 CPU 快照

2026-10-13 10:10:09–10:10:26（UTC+8），`top` 约每秒采集一次，剔除首个读数后保留 15 次：

| 应用 | 平均 CPU | 中位数 | 最小值 | 最大值 |
| --- | ---: | ---: | ---: | ---: |
| NetNewsWire | 0.02% | 0.0% | 0.0% | 0.1% |
| PaperRss | 32.83% | 33.3% | 20.2% | 37.0% |

PaperRss 原始百分比序列：`20.2, 33.3, 28.7, 31.3, 33.5, 32.9, 33.3, 34.7, 33.0, 32.3, 34.8, 35.8, 37.0, 35.6, 36.0`。

NetNewsWire 原始百分比序列：`0, 0, 0.1, 0.1, 0, 0, 0, 0, 0, 0, 0.1, 0, 0, 0, 0`。

这些读数仅描述当时两个主进程，没有统一数据量、前后台状态和交互，也没有汇总 WebKit 辅助进程。采集窗口与 NetNewsWire 的栈采样部分重叠，因此不能把它当作严格基准，更不能据此计算两者的架构效率倍数。

### 栈采样观察

- NetNewsWire：10:10:09 开始，以 10 ms 间隔采样约 6 秒；主线程的 542 个采样均位于等待事件的调用链，最终落在 `mach_msg2_trap`。
- PaperRss：10:08:04 开始，以 10 ms 间隔采样约 8 秒；反复出现 `SystemOutputVolumeMonitor.refresh`、`AudioWaveSpectrum.advance`、`AudioSpectrumAccumulator.receive`。
- PaperRss 的 `ArticleHTMLView.Coordinator.synchronizeAudioWave` 调用链包含 `String.init(format:locale:)`、`CFStringFormatLocalizedNumber` 和 ICU 数字格式化。
- 也观察到 `EntryListView.scheduleCurrentPagesReload`、`AppStore.reloadStateAsync` 与 `TimelineQueryService` 查询，不能仅凭出现这些栈就量化数据库的 CPU 贡献。

栈样本数量不是 CPU 百分比；关闭波形、优化桥接或改用 Release 后的收益尚未测量。

### REA 身份证据

| 字段 | 值 |
| --- | --- |
| Mach-O 证据 ID | `ev_67dbbfc25504b241e3e6a098947c6ecbfe65d32a2a063e59e79ec18669d4a2c8` |
| plist 证据 ID | `ev_56b03cba1c0c12bc6c68e1094d2c4c64ec5bc77146a632e75e3923dce41c1cc3` |
| 可执行文件 SHA-256 | `6bedce40fe4f22194fb0c281d041ae1f8c959c284fe31bf871137d582e4a2fe2` |
| arm64 Mach-O UUID | `D19D4D0C-EBB7-3AA1-87DF-BB55E61EFFBF` |

上述 ID 标识本轮 REA 输出，不是在线可检索地址。本文归档测量摘要与关键栈，不依赖临时文件路径；未纳入原始完整 trace，后续验收需重新采集。

## 3. NetNewsWire 的可借鉴机制

以下原生实现来自 7.1.3b4 本地源码快照；路径相对于 [NetNewsWire 官方仓库](https://github.com/Ranchero-Software/NetNewsWire)，行号为调研时点定位。

| 层面 | 已确认的源码行为 | 证据定位与限制 |
| --- | --- | --- |
| 刷新短路 | Cache-Control / 检查间隔过滤、条件请求、304 退出；200 正文 hash 相同也在解析前退出 | `Modules/Account/Sources/Account/LocalAccount/LocalAccountRefresher.swift:88,179,276,542`；hash 仍需要下载正文和计算 |
| 列表更新 | 文章完全相同直接返回；身份与顺序相同只更新可见行；状态变化与可见文章 ID 取交集；相关 Feed 通知经合并队列处理 | `Mac/MainWindow/Timeline/TimelineViewController.swift:117,185,718,793`；身份或顺序变化仍可能 `reloadData()` |
| 列表加工 | 固定行高、复用单元格、缓存标题与摘要，摘要先截断 HTML 再解码 | `Mac/MainWindow/Timeline/TimelineViewController.swift:912`、`Shared/Extensions/ArticleStringFormatter.swift:63,107`；收益来自具体策略，不能归纳为 AppKit 必然优于 SwiftUI |
| 阅读器 | 选中文章身份未变不重复推送；阅读状态未变不重载 HTML；通常复用 WebView | `Mac/MainWindow/Detail/DetailWebViewController.swift:27,78,378`；最近仍滚动时可能换新 WebView |
| 解析与数据库 | 串行后台解析；按 Feed 在事务中处理；只写新增、变更字段及对应索引，无新增/变更时不发文章下载通知 | `Modules/RSParser/Sources/RSParser/Feeds/FeedParser.swift:18,73`、`Modules/ArticlesDatabase/Sources/ArticlesDatabase/ArticlesTable.swift:226,682`、`Modules/Account/Sources/Account/Account.swift:1498` |
| 图片与调度 | 图标缓存、同 URL 请求去重及失败重试控制；到期刷新和空闲状态同步退避 | `Modules/Images/Sources/Images/ImageDownloader.swift:67,100,145`、`Shared/Timer/AccountRefreshTimer.swift:61`、`Shared/Timer/ArticleStatusSyncTimer.swift:15,63`；不能推广为隐藏窗口后全部工作停止 |

另外直接核对了安装版 7.1.1 的 `Contents/Resources/main_mac.js` 与 `main.js`：前者使用滚动、鼠标事件，后者在 `DOMContentLoaded` 处理正文；两个文件中未发现定时轮询。它们与本地源码哈希不同，因此这里只确认安装版脚本自身的事件驱动行为，不外推到文章脚本、iframe 或整个 WebContent 进程。

不能把低 CPU 简化为“禁用 JavaScript”或“小全局下载并发”：本地源码默认允许文章 JavaScript；下载每 host 连接限制与全局 pending 门槛也是不同概念。后台或串行执行可以限制峰值、保护响应性，但不自动减少总 CPU 时间。

## 4. PaperRss 优化候选与优先级

### P0：音频波形的持续计算和 JavaScript 桥接

**证据类型：源码与运行栈均支持；具体收益未测。**

开启波形后，[SystemOutputVolumeMonitor](../../PaperRss/Sources/App/SystemOutputVolumeMonitor.swift) 以每秒 30 次推进双声道 2048 点频谱；存在逐帧数组加工和缓冲复制。[ArticleReaderView](../../PaperRss/Sources/App/ArticleReaderView.swift) 的 `synchronizeAudioWave` 将 64 个频段逐个本地化格式化，再拼接 JavaScript。采样已观察到这条持续工作链。

候选改进：按可见阅读器的实际需求管理采集生命周期；将频谱计算移至串行后台并复用缓冲、预计算频段边界；通过参数传递数组减少逐帧格式化。静音稳定后停止不必要的 FFT 和桥接，同时保留可靠的声音恢复检测；隐藏后停止无消费者的工作。后台执行本身不是节省总 CPU 的证明。

验证时固定同一构建，比较波形关闭、开启有声、开启静音、阅读器隐藏及重新显示；确认视觉效果、恢复行为和音频回调正确，并测主进程与关联 WebKit 的成本。[Apple 定时器能效指南](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)支持减少无必要唤醒的方向，不提供本项目收益保证。

### P1：无内容变化刷新不再驱动全局重查

**证据类型：源码确认重复工作；运行贡献待隔离测量。**

[LocalAccountProvider](../../PaperRss/Sources/Core/Account/LocalAccountProvider.swift) 的 304 分支仅更新 Feed 元数据并返回 `updated=false`，但 [AppStore](../../PaperRss/Sources/Core/AppStore.swift) 的刷新结果处理仍会调用 `receiveRefreshProgress`。被 300 ms 节流放行的进度会查询侧边栏计数、递增 `timelineRevision`；整轮结束还会重载状态、重新发布列表并清理单篇查询缓存。

侧边栏计数包含 5 个聚合 SQL，定位于 [TimelineQueryService](../../PaperRss/Sources/Core/Persistence/Projections/TimelineQueryService.swift)。本轮未执行 EXPLAIN，不能把“全局聚合”写成已确认的“每次全表扫描”。

候选改进：区分进度 / Feed 元数据变化与文章 / 阅读状态的实际变化；只有后者刷新对应列表、计数和缓存。200 响应也应根据实际 merge 结果判断是否变化，而不是把解析成功等同于文章变更。

验证 300 源全部 304、200 但内容相同、仅单一 Feed 新增三组；无内容变化时不递增内容版本、不清正文查询缓存、不重复发布四个列表或执行全局内容计数，同时保持刷新时间、错误和进度准确。

### P2：收窄标读、标星与进度发布范围

**证据类型：源码支持的交互成本候选。**

`AppStore` 的标读与标星路径会更新多个发布数组和计数；[ArticleStateRepository](../../PaperRss/Sources/Core/Persistence/Repositories/ArticleStateRepository.swift) 也存在目标状态未变仍更新时间和写入的路径。应先确认实际变化再发布，按文章、Feed 与账户缩小更新范围；同步进度可使用较小的观察对象。不能为了省略无效写入而丢弃已有待同步意图。

验证大库连续标读、重复标读、标星、多个分类计数及远端失败重试；同时记录 SQL 次数、发布次数和每次操作 CPU 时间，核对最终状态与 outbox。

### P3：降低批量解析与刷新尾部读库成本

**证据类型：源码支持的刷新成本候选，尚未独立 profile。**

- [FeedParser.parseDate](../../PaperRss/Sources/Core/FeedParser.swift) 逐篇创建日期 formatter，可考虑按解析任务复用，保持并发安全。
- 相同 200 正文仍要解析、抽取摘要和图片；可评估正文摘要值短路，再决定是否需要更细粒度的文章输入指纹。
- `AppStore` 刷新尾部逐篇重新读取新未读文章的完整正文；可考虑后台批量检查“仍存在且未读”，复用已持有正文。保留刷新期间删除和标读的竞态校验。

验证真实 XML / Atom / JSON fixture、日期格式和时区、6 路并行，以及大批新文到达期间删除 Feed / 标读的行为；记录解析、合并与尾部校验各阶段的 CPU 时间和查询次数。

### 已有能力与实施边界

PaperRss 已具备条件请求 / 304、最多 6 路本地抓取、GRDB WAL 与异步读写、100 条元数据分页、单篇与正文缓存、300 ms 进度节流，以及 Metal 翻页的按需绘制。后续计划应复用这些能力，针对重复工作改进；本报告不提出全仓重构、替换 UI 技术栈或数据库。

## 5. 后续实施前的验证要求

| 场景 | 应统一的条件 | 观察指标 |
| --- | --- | --- |
| 静止阅读 | Release、相同文章、媒体与波形设置、相同窗口状态 | 主进程 CPU、关联 WebKit、唤醒次数、持续调用栈 |
| 轻量 Feed 切换 | 相同数据规模、图片设置、切换序列 | 每次操作 CPU 时间、响应延迟、更新次数、操作后回落 |
| 无变化刷新 | 相同 Feed 集合与响应 fixture | SQL / 发布次数、内容版本、缓存保留、总 CPU 时间 |
| 批量新增 | 相同条目数与正文大小 | 总 CPU 时间、总耗时、峰值、主线程阻塞与数据正确性 |

“日常低于 10%、峰值通常在 20–30% 内”是用户对 NetNewsWire 的观察，不是已验证的 PaperRss 验收结果。正式目标需在同等 Release 基线上确定；批量刷新同时比较总 CPU 时间与耗时，避免仅靠延长任务压低峰值。

现有 [RefreshPerformanceTests](../../Tests/RefreshPerformanceTests.swift) 主要检查主线程间隔与部分发布次数；其中 304 场景未充分约束查询、缓存失效和列表版本变化，且预构造 Feed 不覆盖真实解析器成本。[RuntimePerformanceAndIntegrityTests](../../Tests/RuntimePerformanceAndIntegrityTests.swift) 覆盖大库点查、缓存和部分标读行为，也不能证明闲置或刷新 CPU 低于 10%。并发删除相关行为应继续由 [RefreshDeletionTests](../../Tests/RefreshDeletionTests.swift) 保护。

本次归档不新增或执行性能测试，不将候选建议视为已验证修复。后续从 Release 基线和波形 A/B 开始单独计划实施，再逐项复测收益与行为正确性。
