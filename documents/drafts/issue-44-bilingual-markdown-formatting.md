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
