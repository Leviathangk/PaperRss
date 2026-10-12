# 优化 AI 摘要字数控制与个性化偏好支持

- **Status**: accepted
- **Issue**: https://github.com/ohmyangboy/PaperRss/issues/45

## 已批准范围

1. 在内置 AI 摘要系统提示词（System Prompt）中引入明确的篇幅与精简限制，将默认摘要控制在 300 字左右（1 句精炼结论 + 3 至 5 点核心事实），避免模型发散生成冗长细节。
2. 修复 `LLMService.summary` 未拼接用户自定义提示词（`customPrompt`）的缺陷，使设置页中的「表达偏好（customPrompt）」真正对 AI 摘要生效，支持用户自主控制语气、篇幅或特定结构。
3. 保持现有指纹（Fingerprint）机制及缓存机制一致性，确保提示词改动后缓存有效失效与更新。

## 实现约束

- `PaperRss/Sources/Core/LLMService.swift` 中统一维护摘要系统提示词组装。
- 若用户在设置中配置了 `customPrompt`，将其作为附加偏好附加于系统提示词中（与 `explainSelection`、`askSelection` 的逻辑保持一致）。
- 保证测试覆盖：验证提示词组装包含篇幅控制与用户偏好。

## 验收

- 在未配置 `customPrompt` 时，系统提示词明确声明紧凑精炼且篇幅控制在 300 字/词以内；
- 在配置了 `customPrompt` 时，摘要的系统提示词中包含用户自定义的偏好指令；
- 单测全部通过。

## 实施与验证记录

实现：
- 在 `PaperRss/Sources/Core/LLMService.swift` 中新增 `LLMService.summarySystemPrompt(configuration:)`，将默认提示词升级为要求每个要点紧凑精炼、全篇摘要控制在 300 词/字左右。
- 补全对 `configuration.customPrompt` 的拼接，使用户在设置中自定义的偏好指令（如语气、字数、特定排版）在生成 AI 摘要时能够生效。
- 在 `Tests/PaperRssCoreTests.swift` 中补充单元测试 `testSummarySystemPromptIncludesLengthLimitAndCustomPrompt`，严格覆盖默认 300 字限制断言及自定义指令拼接断言。
