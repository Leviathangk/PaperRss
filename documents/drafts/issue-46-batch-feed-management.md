# 侧边栏批量管理订阅源体验优化（支持键盘删除）

- **Status**: accepted
- **Issue**: https://github.com/ohmyangboy/PaperRss/issues/46

## 已批准范围

1. 保持现有的 `Shift` 连续多选、`Command` 点选以及右键菜单批量操作能力。
2. 为侧边栏增加键盘 `Delete` / `Backspace`（退格键）操作支持：当用户选中一个或多个订阅源时，按下键盘 Delete 键直接弹出批量删除确认对话框，无需强制使用右键菜单，贴合 Mac 用户的原生交互直觉。
3. 确保多选状态提示与删除确认窗口文案清晰明了。

## 实现约束

- 沿用现有的 `batchDeleteConfirmFeedIDs` 确认状态机与数据源删除链路；
- 避免在搜索框或文字输入框获得焦点时误触删除操作。

## 验收

- 选中多个订阅源后，按 Delete 键可触发删除确认对话框；
- 确认删除后，所有选中源被正确删除并重置选中态。

## 实施与验证记录

实现：
- `RootView.swift`：
  - 在 `SidebarView` 上添加 `.onDeleteCommand` 监听。当用户在侧边栏焦点下选中单个或多个订阅源时（通过 `selectedFeedIDs` 或 `selection = .feed` / `.feeds`），按下键盘 `Delete` / `Backspace` 键直接激活 `batchDeleteConfirmFeedIDs`，弹出原生的批量删除确认对话框。
  - 确认删除后统一调用 `store.deleteFeeds`，清空 `selectedFeedIDs` 并安全重置选中态，与右键批量删除共享完全一致的数据与确认流程。
- 测试覆盖：
  - `Tests/MacOS14ZenModeToolbarContractTests.swift` 补充 `testSidebarExposesOnDeleteCommandForBatchManagement`，断言 `SidebarView` 对 `.onDeleteCommand` 以及批量删除确认的调用契约。测试通过。
