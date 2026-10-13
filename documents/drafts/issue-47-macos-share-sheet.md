# 增加 macOS 系统共享 (Share Sheet) 与链接操作集成

- **Status**: accepted
- **Issue**: https://github.com/ohmyangboy/PaperRss/issues/47

## 已批准范围

1. 在时间线列表的文章右键上下文菜单（`entryContextMenu`）中增加系统级链接操作：
   - 「共享...」（使用 `ShareLink` 拉起 macOS 原生系统共享表单，支持分享到 Cubox、Obsidian、备忘录等扩展）
   - 「拷贝链接」（复制文章原始 URL 到剪贴板）
   - 「在浏览器中打开」（使用系统默认浏览器打开文章 URL）
2. 阅读工具栏胶囊暂不添加共享按钮（待定，先去除保持胶囊克制，主要由右键菜单承接）。
3. 保持与现有「打开原文」以及「复制文章 ID」入口协调，当文章缺少有效 URL 时优雅禁用或隐藏。

## 实现约束

- 严格遵循 macOS 体验规范，优先使用 AppKit `NSSharingServicePicker` 或 SwiftUI 原生 `ShareLink` 能力。
- 绝不引入私有 Cubox/Obsidian 第三方库或密钥，完全借助 macOS 系统级 Share Extension 机制让用户零成本打通外部分享与剪藏工作流。
- 文案进入本地化入口（I18N）。

## 验收

- 在列表右键菜单中，点击「共享...」可调起 macOS 原生分享面板并成功分享到支持的 App（如 Cubox、备忘录）；
- 在列表右键菜单中，点击「拷贝链接」可将文章 URL 写入剪贴板；点击「在浏览器中打开」可调起默认浏览器；
- 无链接条目安全降级。

## 实施与验证记录

实现：
- `RootView.swift`：
  - `entryContextMenu`：在文章右键菜单中增加快捷操作区：
    - `ShareLink(item: url, subject: Text(entry.title))`（「共享...」）
    - `拷贝链接`（通过 `AppInfo.copyToClipboard` 写入剪贴板并提示 Toast）
    - `在浏览器中打开`（通过 `AppInfo.openURL` 用系统默认浏览器打开）
- `ArticleReaderView.swift`：
  - 胶囊工具栏暂不占用图标位，保持既有 5 按钮精炼布局（翻译、读/未读、收藏、禅模式、打开原文）。
- 测试覆盖：
  - `Tests/MacOS14ZenModeToolbarContractTests.swift` 补充 `testContextMenuExposesShareLinkAndCopyLink` 契约断言，验证右键菜单的原生共享及链接入口。测试通过。
