# Issue #42：控制自动抓取网页全文

- **Status**: implemented, automated tests and macOS host build passed
- **Issue**: https://github.com/ohmyangboy/PaperRss/issues/42
- **本轮范围**：macOS 全局阅读偏好；默认兼容原行为，不增加账号/订阅覆盖层。

## 对上一轮方案的复核

2026-10-13 的草案正确识别了问题：FreshRSS 已提供的短正文仍可能被当作弱候选，引发原网页抓取。但仅跳过普通抓取步骤不够，旧 revision 缓存升级也会请求网页；直接复用相邻预取的 `localOnly` 又会把用户主动选择的短正文视作临时降级预览。

本轮明确需求为“不自动额外抓取原网页全文”，不是不显示正文、只看标题，也不是离线模式。仅禁止网页全文请求；订阅同步、图片加载与用户启用的 AI 服务请求继续按原设置运行。

## NetNewsWire 本地源码对照

本轮读取 `../area/NetNewsWire-main/`，该目录没有 Git 元数据，因此以下是本地源码快照证据，不声称对应最新上游提交。

| 本地源码 | 实际做法 | PaperRss 本轮取舍 |
| --- | --- | --- |
| `Modules/Account/Sources/Account/ReaderAPI/ReaderAPIAccountDelegate.swift:1144` | Reader API 的 `summary.content` 直接作为文章 `contentHTML`，不因字段名叫 summary 就认定它只是摘要 | FreshRSS 提供的短正文也能直接使用，不触发二次抓取 |
| `Modules/Account/Sources/Account/FeedSettings.swift:81` | 订阅级 `readerViewAlwaysEnabled` 默认 false | 本轮采用全局开关；默认 true 保持 PaperRss 旧行为，不静默改变老用户体验 |
| `Mac/MainWindow/MainWindowController.swift:652` | 选择变化先取消旧提取；只有订阅明确开启 Reader View 才自动启动提取，否则展示文章 | 用户设置高于长度启发式；设置变化重启阅读任务，丢弃旧策略结果 |
| `Mac/MainWindow/MainWindowController.swift:432` | 用户可以显式提取、取消、切回订阅正文，并复用当前文章已提取结果 | 保留现有手动重抓与本地全文缓存；本轮不增加双视图切换 |
| `Shared/Article Rendering/ArticleRenderer.swift:108` | `article` 与 `extractedArticle` 是独立输入，HTML 与 baseURL 随所选来源一起变化 | 复用现有同源绑定的 PreparedArticle；关闭自动抓取不改写 Entry，也不以摘要覆盖全文缓存 |
| `Shared/Article Extractor/ArticleExtractor.swift:38` | 全文提取请求使用 `extract.feedbin.com`，支持取消 | 不引入第三方服务，继续使用 PaperRss 现有本地抽取与页面加载器 |

最值得迁移的是“明确触发全文提取”和“保留订阅正文”，而不是照搬网络服务或完整设置层级。关闭自动抓取仍允许读取既有网页缓存，因此文案采用“不自动抓取”，不承诺“仅显示订阅原文”。

## 已实施的行为

入口：设置 → 常规 → 文章正文 → 自动抓取网页全文。

| 场景 | 行为 |
| --- | --- |
| 初次安装或旧版升级 | 默认开启，沿用已有候选质量判断与网页兜底 |
| 关闭自动抓取 | 从订阅源正文和已有缓存选择最佳本地候选，不请求原网页 |
| FreshRSS 已提供短正文 | 直接展示，不以长度不足为由重抓 |
| 已有完整网页缓存 | 仍可阅读，不删除、不以短摘要覆盖 |
| 缓存 revision 已过期 | 本地兜底，不联网升级，也不冒充已升级写回 |
| 没有本地正文 | 使用现有兜底与原文入口，不自动抓网页 |
| AI 请求正文 | 经过同一 AppStore 入口，遵循开关；AI 服务请求本身不受此开关控制 |
| 手动重新抓取正文 | 保留显式操作，不受自动抓取开关限制 |
| 重新开启 | 清空进程内准备结果，短摘要不会阻止下一次网页升级 |
| 切换时有加载在途 | 阅读器重启加载任务；旧策略结果不得写回缓存，按最新策略重新准备 |

## 实现与存储边界

- `ArticlePreparationEngine.ArticlePreparationPolicy.storedContent` 在两条网页请求路径之前返回；不回写磁盘缓存。
- `AppStore.prepareArticle` 统一应用偏好，覆盖阅读、相邻预取和 AI 取正文。切换时取消预取并清空内存缓存。
- `ArticleReaderView` 监听开关变化，当前文章无需重启应用即可重新加载。
- 使用本机 UserDefaults 键 `PaperRss.automaticallyFetchArticleContent`。不迁移数据库、不同步至 FreshRSS/iCloud，也不改服务器设置。测试注入隔离 defaults，避免改动用户偏好。
- 保留现有手动重抓策略：它仍会优先采用足够完整的 Feed，而不是无条件请求网页。

首版不增加账户和订阅级规则。这能直接解决 #42，并保持设置含义明确；混合多个账户、需要逐源例外时再扩展继承关系。

## 验证

- `./scripts/verify.sh --filter 'ArticleFetchPreferenceTests|ArticlePreparationEngineTests|PreparedArticleMemoryCacheTests'`：45 项通过，0 失败；其中新增 7 项。
- 覆盖默认值与隔离偏好持久化、短正文/预取/AI 零网页请求、旧缓存不升级、重新开启恢复抓取、显式重抓，以及在途设置切换。
- 测试完整日志：`build/reports/run-40ryzbe6.log`。测试使用临时库、隔离 defaults 与 Mock 页面，不连接真实 FreshRSS 或 AI 服务。
- `./scripts/verify.sh --build`：macOS 宿主构建通过（退出码 0）；完整日志 `build/reports/run-bz1izwxc.log`。
- `git diff --check` 与 String Catalog JSON 检查通过。

真实设置点击与视觉验收尚未执行；本地实现不等于已经发布。
