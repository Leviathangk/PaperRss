# 优化 AI 翻译排版与 Markdown 列表及引用块阅读兼容性

- **Status**: accepted
- **Issue**: https://github.com/ohmyangboy/PaperRss/issues/44

## 已批准范围

1. Markdown / HTML 列表（`<ul>` 与 `<ol>`）：将逐项内容（`<li>`）作为独立的翻译分段单元，而非将整个列表粗暴合并为一个巨型段落放在列表末尾。译文节点放置在对应 `<li>` 内部或紧跟其后，保持原文与译文逐条紧密对照。
2. Markdown / HTML 引用块（`<blockquote>`）：确保引用样式的译文具有对齐的视觉指示（保留引用色、边线或块级排版属性），避免脱幅为不可辨识的普通段落。
3. 保持现有代码块（`<pre>`）禁区与表格单元格级翻译（#33）不受影响。

## 实现约束

- `ArticleExtractor.swift` 中的 `readerBlockMatches` 识别到嵌套了 `li` 的 `ul`/`ol` 时，不将外部 `ul`/`ol` 容器选为唯一翻译单元，而是让其内部的 `li` 作为候选翻译块进入管线。
- 对于 `li` 块：插入内联翻译时，译文标签必须放置在 `li` 的闭合标签之前（类似表格单元格 `td`/`th` 的处理机制），避免在 `ul` 内部产生非法的直接 `<aside>` 兄弟元素，破坏列表的结构和序号。
- CSS 层面：针对 `li > .paper-rss-translation` 以及 `blockquote + .paper-rss-translation` 提供美观的边距与引用条边框，确保与原文列表或引用紧凑对应。
- WebKit JS 动态更新链路（`PaperReaderBridge`）同步适配 `li` 节点的插入规则。

## 验收

- 解析含多个 `li` 的 `ul`/`ol` 时，每个 `li` 产生独立的 `ReaderParagraph`；
- 插入内联翻译后，译文嵌入在对应 `li` 内部，DOM 结构合法，不会导致列表整体只在末尾显示单一翻译段落；
- 引用块的译文具有引用视觉线索；
- 既有表格、代码块以及纯文本段落测试无回归。

## 实施与验证记录

实现：
- `ArticleExtractor.swift`：
  - 新增 `ReaderListItem` 与 `listItemFragments(in:)`，自动识别扁平列表（`<ul>` / `<ol>`），将各个列表项（`<li>`）作为独立可翻译单元输出为 `pX_0`、`pX_1` 等，在内层包含嵌套复杂列表时自动回退为整体单元，保持复杂结构稳健。
  - 在 `insertingInlineTranslations` 中新增 `listPlan` 处理分支与 `annotatedListItem` 辅助函数，将译文节点 `<aside class="paper-rss-translation">` 插在 `</li>` 闭合标签之前，确保列表 DOM 结构合法且译文与源条目紧凑并列。
- `ArticleReaderView.swift`：
  - 动态翻译 JS 桥接脚本中增加 `LI` 放置策略（`placement = (source.tagName === "TD" || source.tagName === "TH" || source.tagName === "LI") ? "beforeend" : "afterend"`），支持动态流式更新时插入 `<li>` 内部。
  - CSS 样式表优化：
    - 新增 `li > .paper-rss-translation` 规则，消除列表项内部块级负外边距与列表符号干扰。
    - 优化 `blockquote + .paper-rss-translation` 规则，补充 `border-left: 2px solid var(--paper-warm)` 与左侧 `padding: .08em 0 .08em 1em`，使其在视觉上与引用块左侧边框及缩进完全对齐。
- 测试覆盖：
  - `Tests/ReaderBlockSemanticsTests.swift` 新增 `testFlatListsDecomposeIntoItemLevelTranslationUnits`，断言扁平列表项级拆分与 `<li>` 内译文结构。
  - 更新 `testInsertingTranslationsTranslatesTablePerCellInsideTheTable` 对列表条目分段与内嵌断言，全套 19 项语义测试全部 PASS。
  - 执行 `./scripts/verify.sh --web`，212 项 Web / Bridge 测试全部 PASS。

## 用户后续补充反馈与二次优化（v1.5.0-beta.1 体验反馈）

### 补充反馈分析与技术归因
1. **引用块（`<blockquote>`）插入式逐段对照诉求**：
   - **现象**：虽然给 `blockquote + .paper-rss-translation` 加了边框，但多段引用块仍然是“所有原文在上，所有译文在下”，读者在长引用中对照依然需要大幅跳跃。
   - **根因**：`ArticleExtractor.readerBlockMatches` 原先对含有嵌套 `<p>` 的 `<blockquote>` 没有跳过容器，导致整块作为单一单元提取；同时静态与动态（JS）插入均落在 `</blockquote>` 外部。
   - **解法**：
     - 若 `<blockquote>` 内含嵌套 reader block，跳过外部容器，使内部子块（`<p>`、`<h3>`、`<ul>` 等）成为独立翻译单元。子块翻译后自然生成在子块闭合标签之后（即 `<blockquote>` 内部），实现逐段对照并共享外层引用竖线。
     - 若 `<blockquote>` 为纯文本单块，静态与动态均插在 `</blockquote>` 闭合标签之前（`beforeend`）。
     - CSS 新增 `blockquote .paper-rss-translation`，消除重复左边框与多余内边距（`border-left: none; padding: 0`），使其自然融入引用块内部。
2. **Markdown 非严格换行与行间距统一**：
   - **现象**：用户在非严格换行（单换行 / `<br>`）下，原文行间距紧凑，而译文每行之间却出现了整行空行。
   - **根因**：`String.plainText` 中 `(?is)<br\s*/?>` 替换为 `\n` 时，若 HTML 中存在 `<br>\n`，直接放大了为 `\n\n`（双换行）。LLM 收到带有双换行的文本后输出双换行，在 `white-space: pre-wrap;` 下渲染为双倍空行。
   - **解法**：
     - `String.plainText` 将正则升级为 `(?is)<br\s*/?>[ \t]*\r?\n?`，防止单换行膨胀。
     - Prompt 约束：明确要求保留单换行，禁止将单换行转换为多余空行。
     - 代码层防御性对齐：新增 `String.aligningNewlines(withOriginal:)`，当原文不含 `\n\n` 时，折叠译文中多余的连续换行，保证译文行距与原文严格匹配。

### 嵌套列表（Nested List）与底部段落调度加固（实测样本 `16740453972212946442`）

#### 1. 嵌套列表项（Nested List）逐项内联拆分与原位插入
- **根因**：原 `listItemFragments` 使用非贪婪正则匹配 `<li>...</li>`，并在检测到包含 `<ul`、`<ol`、`<table` 时直接返回 `nil`，导致嵌套列表退化为单一巨型段落，所有子项合并沉底在列表最下方。
- **解法**：
  - `ArticleExtractor.swift`：实现基于标签栈（Stack）的列表块解析器 `listBlockPlan(in block: String) -> ReaderListPlan?`。
  - 维护列表嵌套与 `li` 嵌套栈，准确提取每一项自身文本（剔除直接子列表后的文本）。叶子项文本为其内部内容；含子列表的父项文本为其前置标题/引导文字（如 `Dual Operating Modes:`），不混杂子项文字。
  - 插入点定位：
    - 含直接子列表的父项：译文插在直接子列表（`<ul>` / `<ol>`）的开标签之前，保证父项译文紧随父项文字，子列表及其缩进排布在其下方；
    - 叶子项：译文插在当前项的 `</li>` 闭合标签之前；
    - 结构保真：通过逆序字符偏移量插入，原字符串的所有原始结构字符、空白与缩进 100% 保持。
  - `ArticleReaderView.swift`：WebKit 动态插入脚本中，当目标为 `LI` 且存在直接子列表时（`:scope > ul, :scope > ol`），将译文节点插在直接子列表前（`beforebegin`），叶子项插在 `beforeend`。

#### 2. 文章底部段落（如 Related Guide / Tip）未被翻译问题修复
- **根因**：
  - WebKit 端 `publishParagraphs` 硬编码了 `.slice(0, 10)`，当文章前部存在多行表格（如 32 个单元格）或密集嵌套列表项时，视口与预加载范围内的单元数超过 10，排在后面的底部段落被硬性截断无法报送给原生层；
  - Swift 端在异步翻译任务中缺乏 `defer` 清理，若上一批在未完全完成时退出可能造成 `pendingBilingualParagraphIDs` 锁死，且 `persistedBilingualSegments` 快照未在批次结束时从本地存储同步更新。
- **解法**：
  - WebKit 端将 `publishParagraphs` 报送上限放宽至 `slice(0, 40)`，给视口内密集短段落（表格单元格、嵌套列表与紧随段落）留出充足通道；
  - Swift 端使用 `defer { pendingBilingualParagraphIDs.subtract(batch) }` 保证任何分支均清理 pending 状态；
  - 批次完成时同步刷新 `persistedBilingualSegments`，并通过 `requestVisibleTranslationsIfPossible()` 自动无缝推进下一批，直至视口内所有段落全部翻译完毕。

### 验收与验证
- `Tests/ReaderBlockSemanticsTests.swift`：
  - 更新 `testNestedListsDecomposeIntoItemLevelTranslationUnits`，断言嵌套列表项级拆分与父项在子列表前、子项在闭合前的树级插入；
  - 更新 `testDiagnosePaperBlogArticle`，断言样本文章中 `Dual Operating Modes:` 与子项 `Global Mode`、`Local Project Mode` 均成功拆分，底部 `📖 Related Guide` 与 `💡 Tip` 完整提取并成功挂载译文。
- 全套 22 项语义测试通过；`./scripts/verify.sh --web` 220 项 Web / Bridge 测试全部通过（0 failure）。
