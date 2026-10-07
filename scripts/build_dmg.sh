#!/bin/bash
set -euo pipefail

# 确保脚本在项目根目录下运行
CDPATH= cd "$(dirname "$0")/.."

# 本地 build 的兼容入口；发布始终需要单独调用 release.sh publish。
usage() {
    cat <<'EOF'
用法: ./scripts/build_dmg.sh [build] --version <X.Y.Z[-beta.N]> --build <N> [build 参数]

无参数或 --help 只显示本说明；直接传 build 参数和显式 build 子命令均可。
参数原样交给 release.sh build，可用 --channel、--output-root、--skip-notarization 等。
本入口仅生成本地产物，不推送 Tag、不上传 Release、不执行 publish。
EOF
}

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi
if [[ "$1" == "build" ]]; then
    shift
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
        exit 0
    fi
elif [[ "$1" != --* ]]; then
    echo "错误: build_dmg.sh 仅支持本地 build" >&2
    usage >&2
    exit 2
fi
exec ./scripts/release.sh build "$@"
