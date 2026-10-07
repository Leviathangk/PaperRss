# 自动化测试与分级验证矩阵

## 决策准则

- 围绕改动行为选择最小充分验证；不因文件位于 `Sources/App/` 就机械执行前台 GUI，不默认跑全套。
- 同一代码状态、测试环境和候选产物下复用已通过证据；`--all` 已覆盖的 Core、Feature 和 Web 测试不重复执行。代码、环境或相关产物变化后，只补充失效的必要证据。
- 默认验证不展示窗口。真实绘制与交互专项显式启用，需要不打断用户桌面时，在经过验证的独立图形会话或虚拟机中执行；手动前台调试按需保留。
- 构建成功、进程存活和真实交互通过是不同证据。交付说明实际执行项目、跳过项和环境限制；跳过的 GUI 测试不得记为通过。

## 按行为选择验证

| 改动行为 | 必要证据 | 执行入口 | 桌面影响 |
| --- | --- | --- | --- |
| 模型、解析、持久化、网络、同步、AI 或纯策略 | Core 回归；影响用户可见投影时补充相关 App 行为回归 | `./scripts/verify.sh --core`；按需 `--feature` 或 `--filter <名称>` | 默认不显示窗口，使用临时 fixture / 测试库 |
| Reader JS、Bridge、快捷键策略、官网或治理规则 | 相关 Node 测试；Bridge 修改同时核对 macOS/iOS Coordinator 与消息协议 | `./scripts/verify.sh --web` | 不启动 App |
| Shell / Python 自动化入口 | 语法与对应契约测试，按入口实际行为补充验证 | `bash -n <脚本>`；`python3 -m py_compile <文件>`；相关 Node 测试 | 语法与契约检查不启动 App |
| App 状态、视图组合、系统桥接 | 受影响 App 行为回归与宿主构建；布局、焦点、快捷键等可见行为按改动补充真实交互 | `--feature` / `--filter <名称>` 与 `--build`；需要交互时 `./scripts/dev.sh --isolated` | 自动化默认不显示窗口；手动启动仍共享桌面 |
| Metal Drawable、真实窗口绘制 | 明确运行且通过的真实窗口专项 | `./scripts/verify.sh --gui [测试过滤器]` | 显式显示窗口，需图形会话 |
| 杂志黑边 / 像素排障 | 手动检查像素日志与复现材料，不能用诊断日志代替回归断言 | `./scripts/verify.sh --diagnostics` | 显式显示诊断窗口 |
| MathJax、代码高亮、插图反相的真实 WebKit 完成态 | 对应 WebKit 探针 | `--mathjax-webkit` / `--highlight-webkit` / `--image-invert-webkit` | 独立的按需 WebKit 专项，不包含在 `--all` 中 |
| 发布候选 | 自动化回归、构建产物与受影响路径的真实交互验收 | 按 [发布流程与质量门禁](release-process.md) 执行 | 交互门禁保留，优先独立图形会话或虚拟机 |

## 执行入口契约

- `--core` 只运行 `PaperRssCoreTests`，不再等同于全部 Swift 测试。
- `--feature` 运行现有 App 功能回归子集；可见窗口专项默认跳过。
- `--filter <名称>` 用于针对性排障；默认仍关闭可见窗口专项。必须检查实际匹配与跳过情况，不能把零匹配或全部跳过记为有效证据。
- 无参数或 `--all` 依次执行全部 Swift 测试（可见窗口与像素诊断默认跳过）、Web 测试、macOS 宿主构建、`git diff --check`；Swift 全套只执行一次。
- 普通 `--core` / `--feature` / `--filter` / `--all` 强制关闭 GUI 与像素诊断开关，防止继承环境变量而意外显示窗口。
- `--gui [测试过滤器]` 显式设置 `PAPERRSS_RUN_GUI_TESTS=1`；默认选择杂志与侧边栏真实窗口专项。侧边栏性能测试仍需额外显式设置 `PAPERRSS_RUN_SIDEBAR_PERF=1`；自定义过滤器应指向需要真实窗口的测试。
- `--diagnostics` 显式设置 `PAPERRSS_RUN_GUI_TESTS=1` 与 `PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS=1`，仅运行 `testDiagnoseEdgeLine` 像素诊断。

## 数据隔离与桌面隔离

`./scripts/dev.sh --isolated [已创建的绝对目录]` 使用隔离数据与构建产物，不关闭日常实例；它仍共享当前 macOS 桌面，应用窗口可能遮挡界面或取得焦点。`./scripts/test.sh` 的新用户实例也共享桌面。独立 Bundle ID、临时数据目录与后台启动均不能保证桌面隔离。

常规开发先运行无可见窗口的自动化入口。需要不打断桌面的真实交互时，使用经过验证、具备工具链与图形环境的独立会话或虚拟机；没有该环境时如实说明，不能声称已完成桌面隔离。仅构建可使用 `--build`；`dev.sh --isolated` 已有同代码状态的构建成功证据时，不再重复构建。

可能写入真实数据、运行迁移或启动可能持久化的真实 App / GUI 前，执行 [开发数据备份](dev-data-backup.md)。已授权且能保证只读的检查、临时 fixture 和隔离库无需备份正式用户数据；无法证明只读时按可能写入处理。
