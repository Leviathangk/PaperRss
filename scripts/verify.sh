#!/bin/bash
# ==============================================================================
# PaperRss 自动化全链路与分级验证脚本 (Automated Verification Matrix)
#
# 用法:
#   ./scripts/verify.sh               # 运行全量自动化验证 (--all: Swift + Web + xcodebuild + git diff)
#   ./scripts/verify.sh --all         # 运行全量自动化验证 (同上，无冗余执行)
#   ./scripts/verify.sh --feature     # 仅执行 App 核心功能回归测试 (AppFeatureRegressionTests)
#   ./scripts/verify.sh --web         # 仅执行 Web Reader / JS Bridge / 快捷键策略测试
#   ./scripts/verify.sh --mathjax-webkit # 执行需拉起 WebKit 的 MathJax Tier 3 探针
#   ./scripts/verify.sh --highlight-webkit # 执行需拉起 WebKit 的代码高亮 Tier 3 探针
#   ./scripts/verify.sh --image-invert-webkit # 执行需拉起 WebKit 的深色纸面插图反相 Tier 3 探针
#   ./scripts/verify.sh --build       # 仅执行 macOS 宿主增量构建
#   ./scripts/verify.sh --core        # 仅执行 PaperRssCoreTests
#   ./scripts/verify.sh --filter <名> # 运行指定测试类或测试方法
#   ./scripts/verify.sh --gui [名]    # 显式执行真实窗口专项，可选过滤测试名
#   ./scripts/verify.sh --diagnostics # 显式执行杂志边缘像素诊断
#
# 默认模式关闭可见窗口测试；--gui/--diagnostics 会展示窗口。
# dev.sh --isolated 仅隔离数据与实例，仍共享当前桌面。
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

# 开发者目录与 Xcode 工具链检测 (优先尊重已有 DEVELOPER_DIR，否则使用系统当前选择的 xcode-select)
if [ -z "${DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR="$(xcode-select -p)"
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}🔍 [PaperRss] 启动自动化验证流程...${NC}"
echo -e "   工具链环境: ${DEVELOPER_DIR}"

MODE="${1:-all}"
FILTER_ARG=""
GUI_FILTER_ARG="MagazineFoldEffectTests|MagazinePerformanceTests|SidebarScrollPerformanceTests"

# 普通验证不继承可见窗口开关，避免环境残留导致日常回归打断桌面。
export PAPERRSS_RUN_GUI_TESTS=0
export PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS=0

if [ "$MODE" = "--filter" ]; then
    if [ -z "${2:-}" ]; then
        echo -e "${RED}错误: --filter 参数缺少测试名称${NC}" >&2
        echo -e "用法: ./scripts/verify.sh --filter <TestClassName/testMethodName>" >&2
        exit 1
    fi
    FILTER_ARG="$2"
fi

if [ "$MODE" = "--gui" ]; then
    if [ -n "${2:-}" ]; then GUI_FILTER_ARG="$2"; fi
    export PAPERRSS_RUN_GUI_TESTS=1
elif [ "$MODE" = "--diagnostics" ]; then
    export PAPERRSS_RUN_GUI_TESTS=1
    export PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS=1
fi

case "$MODE" in
    --filter|--gui) MAX_ARGS=2 ;;
    *) MAX_ARGS=1 ;;
esac
if [ "$#" -gt "$MAX_ARGS" ]; then
    echo "错误: 验证模式收到多余参数" >&2
    exit 2
fi

run_feature_tests() {
    echo -e "\n${BLUE}▶ 执行 App 核心功能回归测试 (AppFeatureRegressionTests)...${NC}"
    python3 scripts/build-support.py --lane tests --temporary -- swift test --scratch-path "$PWD/.build" --filter 'AppFeatureRegressionTests|EntryPreviewImageTests|ArticlePreviewPersistenceTests|ArticleThumbnailStoreTests|TimelinePresentationTests|MagazineEditionTests|MagazineFoldEffectTests|MagazinePerformanceTests|testArticlePreviewFromFreshRSS'
    echo -e "${GREEN}✔ App 核心功能回归测试通过！${NC}"
}

run_web_tests() {
    echo -e "\n${BLUE}▶ 执行 Web Reader / JS Bridge / 快捷键测试...${NC}"
    python3 scripts/build-support.py --temporary --unlocked -- node --test Tests/*.test.mjs
    echo -e "${GREEN}✔ Web / Bridge 测试全部通过！${NC}"
}

run_mathjax_webkit_test() {
    echo -e "\n${BLUE}▶ 执行 MathJax 真实 WKWebView 完成态探针...${NC}"
    ./scripts/test-mathjax-webkit.sh
    echo -e "${GREEN}✔ MathJax WKWebView 探针通过！${NC}"
}

run_highlight_webkit_test() {
    echo -e "\n${BLUE}▶ 执行代码高亮真实 WKWebView 完成态探针...${NC}"
    ./scripts/test-highlight-webkit.sh
    echo -e "${GREEN}✔ 代码高亮 WKWebView 探针通过！${NC}"
}

run_image_invert_webkit_test() {
    echo -e "\n${BLUE}▶ 执行深色纸面插图反相真实 WKWebView 探针...${NC}"
    ./scripts/test-reader-image-inversion-webkit.sh
    echo -e "${GREEN}✔ 插图反相 WKWebView 探针通过！${NC}"
}

run_core_tests() {
    echo -e "\n${BLUE}▶ 执行 PaperRssCoreTests (Core/Data/FreshRSS/Performance)...${NC}"
    python3 scripts/build-support.py --lane tests --temporary -- swift test --scratch-path "$PWD/.build" --filter '^PaperRssCoreTests[.]'
    echo -e "${GREEN}✔ Core 回归测试通过！${NC}"
}

run_swift_tests() {
    echo -e "\n${BLUE}▶ 执行 Swift 全套常规回归（可见窗口专项跳过）...${NC}"
    python3 scripts/build-support.py --lane tests --temporary -- swift test --scratch-path "$PWD/.build"
    echo -e "${GREEN}✔ Swift 常规回归测试通过！${NC}"
}

run_build_test() {
    echo -e "\n${BLUE}▶ 执行 macOS 宿主增量构建 (xcodebuild)...${NC}"
    python3 scripts/build-support.py --lane app -- xcodebuild -project PaperRss.xcodeproj -scheme PaperRss -destination "platform=macOS" -derivedDataPath "$PWD/build" build
    echo -e "${GREEN}✔ macOS 宿主编译构建成功！${NC}"
}

run_git_diff_check() {
    echo -e "\n${BLUE}▶ 执行代码规范与空白字符核查 (git diff --check)...${NC}"
    git diff --check
    echo -e "${GREEN}✔ 代码格式规范无违规！${NC}"
}

print_git_status() {
    echo -e "\n${BLUE}▶ 当前代码工作区状态 (git status --short):${NC}"
    git status --short || true
}

START_TIME=$(date +%s)

case "$MODE" in
    --feature)
        run_feature_tests
        ;;
    --web)
        run_web_tests
        ;;
    --mathjax-webkit)
        run_mathjax_webkit_test
        ;;
    --highlight-webkit)
        run_highlight_webkit_test
        ;;
    --image-invert-webkit)
        run_image_invert_webkit_test
        ;;
    --build)
        run_build_test
        ;;
    --core)
        run_core_tests
        ;;
    --filter)
        echo -e "\n${BLUE}▶ 执行自定义过滤回归测试: ${FILTER_ARG}...${NC}"
        python3 scripts/build-support.py --lane tests --temporary -- swift test --scratch-path "$PWD/.build" --filter "$FILTER_ARG"
        echo -e "${GREEN}✔ 自定义测试 ${FILTER_ARG} 执行完成！${NC}"
        ;;
    --gui)
        echo -e "\n${YELLOW}▶ 执行真实窗口专项：会展示窗口；需无打扰时请在独立图形会话运行。${NC}"
        python3 scripts/build-support.py --lane tests --temporary -- swift test --scratch-path "$PWD/.build" --filter "$GUI_FILTER_ARG"
        ;;
    --diagnostics)
        echo -e "\n${YELLOW}▶ 执行可见窗口像素诊断（输出用于排障，不作为像素回归通过证据）...${NC}"
        python3 scripts/build-support.py --lane tests --temporary -- swift test --scratch-path "$PWD/.build" --filter 'MagazineFoldEffectTests/testDiagnoseEdgeLine'
        ;;
    all|--all)
        echo -e "\n${BLUE}▶ [1/4] 执行 Swift 常规套件 (Core / App / Regression)...${NC}"
        run_swift_tests
        echo -e "\n${BLUE}▶ [2/4] 执行 Web / JS Bridge / 治理测试...${NC}"
        run_web_tests
        echo -e "\n${BLUE}▶ [3/4] 执行 macOS 宿主构建...${NC}"
        run_build_test
        echo -e "\n${BLUE}▶ [4/4] 检查代码规范与格式...${NC}"
        run_git_diff_check
        print_git_status
        ;;
    *)
        echo -e "${RED}错误: 未知验证模式 '${MODE}'${NC}" >&2
        echo -e "用法:" >&2
        echo -e "  ./scripts/verify.sh               # 全量自动化验证 (--all)" >&2
        echo -e "  ./scripts/verify.sh --all         # 全量自动化验证" >&2
        echo -e "  ./scripts/verify.sh --feature     # 仅回归 App 核心功能 (AppFeatureRegressionTests)" >&2
        echo -e "  ./scripts/verify.sh --web         # 仅回归 Web / JS Bridge" >&2
        echo -e "  ./scripts/verify.sh --mathjax-webkit # MathJax Tier 3 WebKit 探针" >&2
        echo -e "  ./scripts/verify.sh --highlight-webkit # 代码高亮 Tier 3 WebKit 探针" >&2
        echo -e "  ./scripts/verify.sh --image-invert-webkit # 深色纸面插图反相 Tier 3 WebKit 探针" >&2
        echo -e "  ./scripts/verify.sh --build       # macOS 宿主增量构建" >&2
        echo -e "  ./scripts/verify.sh --core        # 仅回归 PaperRssCoreTests" >&2
        echo -e "  ./scripts/verify.sh --filter <名> # 运行指定测试类/方法" >&2
        echo -e "  ./scripts/verify.sh --gui [名]    # 显式执行可见窗口专项" >&2
        echo -e "  ./scripts/verify.sh --diagnostics # 显式执行可见像素诊断" >&2
        exit 1
        ;;
esac

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "\n${GREEN}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}所选验证已完成！(总耗时: ${DURATION}s；跳过的专项不计作通过证据)${NC}"
echo -e "${GREEN}${BOLD}==============================================${NC}"
