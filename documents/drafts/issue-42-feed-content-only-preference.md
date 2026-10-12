# 评估与建议：增加“仅使用订阅原始内容/不自动抓取网页正文”偏好设置

- **Status**: proposed
- **Issue**: https://github.com/ohmyangboy/PaperRss/issues/42

## 背景与需求分析

- 用户反馈在结合 FreshRSS 使用时，FreshRSS 服务端可能已经通过 Readability 插件完成了全文抓取，但在 PaperRss 打开文章时仍可能因启发式字数判断（如小于 600 字）而重新触发网络网页正文抓取（`ArticlePreparationEngine` 经由 `pageLoader.loadPage`）。
- 用户希望有机制控制“是否默认读取/抓取原网页正文”，一方面提升打开效率、节省流量，另一方面避免冗余的网络等待。

## 方案设计

1. 在设置（排版/高级）中增加设置项：`articleFetchPolicy` 或「优先使用订阅源正文（禁用网页自动抓取）」。
2. 当开启该设置时，`ArticlePreparationEngine` 将对常规前台阅读行为应用类似 `.localOnly` 或跳过步骤 5（Web 抓取），直接采用 Feed 候选。
3. 作为第一阶段，本轮重点实施 #45、#44、#47、#46 等维护者确认和高频交互缺陷；本方案作为后续版本的系统性扩展储备。
