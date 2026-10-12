# 增加 macOS 系统共享 (Share Sheet) 与链接操作集成

- **Status**: accepted
- **Issue**: https://github.com/ohmyangboy/PaperRss/issues/47

## 已批准范围

1. 在阅读工具栏胶囊（`ReaderCapsuleToolbar`）中增加系统「共享」按钮（使用系统标准 `square.and.arrow.up` 图标），支持将当前文章的链接和标题通过 macOS 原生 `NSSharingServicePicker` 分享给系统扩展（如 Cubox、Pocket、Obsidian、备忘录、信息等）。
2. 在时间线列表的文章右键上下文菜单（`entryContextMenu`）中增加：
   - 「拷贝链接」（复制文章原始 URL 到剪贴板）
   - 「共享...」（拉起 macOS 原生系统共享表单）
3. 保持与现有「打开原文」以及「复制文章 ID」入口协调，当文章缺少有效 URL 时优雅禁用或隐藏。

## 实现约束

- 严格遵循 macOS 体验规范，优先使用 AppKit `NSSharingServicePicker` 或 SwiftUI 原生 `ShareLink` 能力。
- 绝不引入私有 Cubox/Obsidian 第三方库或密钥，完全借助 macOS 系统级 Share Extension 机制让用户零成本打通外部分享与剪藏工作流。
- 文案进入本地化入口（I18N）。

## 验收

- 在阅读文章时，胶囊工具栏展示共享按钮，点击可弹出系统分享面板并成功分享到支持的 App（如 Cubox、备忘录）；
- 在列表右键菜单中，点击「拷贝链接」可将文章 URL 写入剪贴板；点击「共享...」可调起分享菜单；
- 无链接条目安全降级。

## 实施与验证记录

实现：
- `ArticleReaderView.swift`：
  - `ReaderCapsuleToolbar` 增加 `articleURL: URL?` 与 `articleTitle: String` 属性。
  - 胶囊工具栏新增 `ShareLink(item: articleURL, subject: Text(articleTitle))` 入口，使用系统标准 `square.and.arrow.up` 图标，点击可原生唤出 macOS Share Sheet（支持 Cubox、Obsidian、备忘录等扩展剪藏）；在文章无有效链接时保持 disabled 占位，避免胶囊跳动。
- `RootView.swift`：
  - `readerToolbarCapsule`：向 `ReaderCapsuleToolbar` 注入当前文章的 `current.url` 与 `current.title`。
  - `entryContextMenu`：在文章右键菜单中增加快捷操作区：
    - `ShareLink(item: url, subject: Text(entry.title))`（「共享...」）
    - `拷贝链接`（通过 `AppInfo.copyToClipboard` 写入剪贴板并提示 Toast）
    - `在浏览器中打开`（通过 `AppInfo.openURL` 用系统默认浏览器打开）
- 测试覆盖：
  - `Tests/MacOS14ZenModeToolbarContractTests.swift` 补充 `testReaderCapsuleToolbarAndContextMenuExposeShareLinkAndCopyLink` 契约断言，验证阅读胶囊与右键菜单的原生共享及链接入口。测试通过。
