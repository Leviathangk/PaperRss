# 贡献与 PR 规范

PaperRss 由单人维护。每个 PR 聚焦一个问题，说明触发场景、改动后的行为和影响范围；大范围产品、平台或依赖变更先讨论。提交前阅读 [项目原则](../.agents/rules/principle.md)，采用 [PR 模板](pull_request_template.md)。不要求额外一人批准。

## 提交证据

保留模板的三个章节及字段名称，移除 TODO 占位符。注明系统、工具链环境，每条测试命令记录实际通过、失败和跳过用例数，并列出未测行为及原因。格式示例：

```text
命令: `./scripts/verify.sh --web` | 通过: 120 | 失败: 0 | 跳过: 2
未测项: GUI 交互尚未测试；两个依赖签名产物的测试跳过。
```

示例数字不是测试结果。勾选框、构建成功、零匹配、全部跳过均不代表单元测试通过；失败必须如实记录，修复后重新验证。按 [验证矩阵](../.agents/docs/verification-matrix.md) 选择命令，日志在 `build/reports/`。动画可额外附录屏，但不替代前后截图。不调用真实 AI 服务或使用真实用户数据来补齐测试。

UI 改动必须提供同一场景的修改前/后截图：相同数据、窗口大小、主题、操作，并说明平台与状态。使用 `![修改前](https://github.com/user-attachments/assets/实际附件ID)` 等图片 Markdown；支持 GitHub 附件及 GitHub 图片域名。两张图需不同图片路径，仅改变查询参数不算另一张图。上传前遮盖个人信息；截图无法补齐时保持 PR 未就绪。无 UI 变化填写“UI变更: 否”、具体理由，以及两处“不适用”。App、Resources、website 路径保守视为 UI 候选；声明无 UI 变化须在“路径说明:”中提供具体解释，由维护者复核，其他路径造成的可见变化仍须主动申报。

## 检查与合并

`PR policy` 校验正文结构、占位符、图片 URL 形态以及 base/head 三点差异的空白问题；`PR web tests` 和 `PR core tests` 实际运行已有测试（纯 Markdown 文档 PR 可明确豁免 Core，Web 和规范检查仍运行）；`PR gate` 汇总全部结果，失败或整个 job 意外跳过都不算通过；纯文档 Core 豁免由成功的 job 明确报告。正文编辑会重新检查。所有 PR（含草稿）都产生检查，不用路径过滤跳过整个工作流。

校验器不会下载图片，不能证明图片存在、内容真实、场景相同，也不能证明作者填写的测试数真实；维护者须核对截图、日志与实际 CI。PR 可修改工作流或校验器，当前同仓库检查不是防恶意篡改的独立信任边界；这些文件变更需重点人工审查。只读 `pull_request` 工作流使用 GitHub 托管 runner，无 secrets、写权限、持久化 checkout 凭据或 PR 内容 shell 拼接。外部 PR 继续遵循仓库现有 `collaborators_only` 策略。

规范失败只报告失败，不自动关闭 PR。只有远程 main 保护启用必需检查后才真正禁止合并；本地文件不等于已启用保护。计划采用 `PR gate`（首次 CI 验证后确认实际名称）作为必需检查；部署与发布工作流不能替代 PR 测试。macOS runner 上 Core 的首次成功、工具链兼容性仍需真实 CI 验证；`--build` 涉及签名配置，本轮不纳入必需检查。

远程待确认：要求 PR、禁止强推/删除、讨论解决、0 个额外批准、所有人包括 owner 无绕过，以及是否要求分支与 main 最新。自动关闭范围另行确认。冲突 PR 可能不产生 `pull_request` 运行，先解决冲突再等待检查。

## 路径检查边界

对新增或修改路径拒绝已知构建目录（`build*`、`DerivedData`、`.build`、`.swiftpm`、`dist`、`.dist`、`.scratch`）和 Xcode 本机状态。疑似凭据文件名（`.env*`、`release.env`、常见 SSH 私钥名及 key/pem/p12/pfx/mobileprovision 扩展名）也会失败；`.example` / `.template` 和 `Tests/fixtures/`、`AppTests/fixtures/` 中的测试材料允许保留，仍须人工确认是合成数据。删除这些文件不受阻止。改名按删除加新增分析，避免把代码改名为 Markdown 后误获 Core 豁免。

这是路径检查，不读取文件内容，也不是秘密扫描：普通源码中的密钥、改名后的产物、其他目录或扩展名不保证发现。`.gitignore` 本身也不能阻止强制添加或已跟踪文件；维护者仍须检查 diff。正文与截图真实性检查边界同上。

## 本地校验

```sh
node --test Tests/pr-policy.test.mjs
GITHUB_EVENT_PATH=/path/to/event.json node scripts/check-pr.mjs
./scripts/verify.sh --web
```

事件 JSON 需含 `pull_request.title/body/base.sha/head.sha`，本地 Git 要具备两端历史。校验器仅将 SHA 传给 `execFileSync`，正文不执行为命令。

## 设计依据

借鉴 [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire/blob/main/CONTRIBUTING.md) 的先讨论范围与作者责任、[CodeEdit 模板](https://github.com/CodeEditApp/CodeEdit/blob/main/.github/pull_request_template.md) 的 UI 截图与 [贡献规范](https://github.com/CodeEditApp/CodeEdit/blob/main/CONTRIBUTING.md) 的拆分混杂改动及测试失败不合并、[VS Code](https://github.com/microsoft/vscode/wiki/How-to-Contribute) 的单目标小 PR 与配套测试。双图同场景是 PaperRss 维护者额外要求；此处不采用其他项目的 CLA、多人批准或功能范围限制，也不照搬自动关闭做法。
