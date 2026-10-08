#!/bin/bash
# 快捷编译并拉起 PaperRss macOS 应用（免 Xcode GUI）
set -e

cd "$(dirname "$0")/.."

# 隔离验收复用指定目录，便于验证重启持久化；不关闭用户的日常实例。
ISOLATED_DIRECTORY=""
OWNED_DIRECTORY=""
APP_PID=""
DERIVED_DATA="./build"
BUILD_OPTIONS=("ONLY_ACTIVE_ARCH=YES")
SCHEME="PaperRss"
CONFIGURATION="Debug"
ICLOUD_MODE=0
ISOLATED_MODE=0
BUILD_ONLY=0
usage() {
    cat <<'EOF'
用法:
  ./scripts/dev.sh [--icloud] [--build-only]
  ./scripts/dev.sh --isolated [已创建的绝对临时目录] [--build-only]

  --icloud      使用已配置的 CloudKit Development 签名，编译并启动
  --build-only  只构建，不启动 App 或关闭已有实例
  --isolated    使用独立本机数据目录和 Bundle ID（不与 --icloud 合用）
EOF
}
cleanup() {
    local code=$?
    trap - EXIT INT TERM
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    if [ -n "$OWNED_DIRECTORY" ]; then
        rm -rf -- "$OWNED_DIRECTORY"
    fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
while [ $# -gt 0 ]; do
    case "$1" in
        --icloud)
            ICLOUD_MODE=1
            shift
            ;;
        --build-only)
            BUILD_ONLY=1
            shift
            ;;
        --isolated)
            ISOLATED_MODE=1
            shift
            if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
                ISOLATED_DIRECTORY="$1"
                shift
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$ICLOUD_MODE" -eq 1 ] && [ "$ISOLATED_MODE" -eq 1 ]; then
    echo "--icloud 使用正式 Bundle ID 的开发描述文件，不能与独立 Bundle ID 的 --isolated 合用。" >&2
    exit 2
fi
if [ "$ICLOUD_MODE" -eq 1 ]; then
    SCHEME="PaperRss iCloud"
    CONFIGURATION="Debug-iCloud"
    BUILD_OPTIONS+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
fi
if [ "$ISOLATED_MODE" -eq 1 ]; then
    if [ -z "$ISOLATED_DIRECTORY" ]; then
        mkdir -p build/tmp
        OWNED_DIRECTORY="$(mktemp -d "$PWD/build/tmp/dev-home.XXXXXX")"
        ISOLATED_DIRECTORY="$OWNED_DIRECTORY"
    fi
    if [[ "$ISOLATED_DIRECTORY" != /* || ! -d "$ISOLATED_DIRECTORY" ]]; then
        echo "用法: ./scripts/dev.sh --isolated [已创建的绝对临时目录]" >&2
        exit 2
    fi
    DERIVED_DATA="${PAPERRSS_DEV_DERIVED_DATA:-./build/isolated}"
    BUILD_OPTIONS+=("PRODUCT_BUNDLE_IDENTIFIER=${PAPERRSS_DEV_BUNDLE_ID:-com.yangbukun.PaperRss.SettingsUI}")
fi

if [ -z "$DEVELOPER_DIR" ]; then
    # 跟随系统当前选择的开发者目录，可用 DEVELOPER_DIR 显式覆盖
    export DEVELOPER_DIR="$(xcode-select -p)"
fi

echo "🚀 正在编译 PaperRss..."
echo "运行方案: $SCHEME ($CONFIGURATION)"
python3 scripts/build-support.py --lane app -- xcodebuild -project PaperRss.xcodeproj -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED_DATA" "${BUILD_OPTIONS[@]}" -quiet

APP_BIN="$DERIVED_DATA/Build/Products/$CONFIGURATION/PaperRss.app/Contents/MacOS/PaperRss"

if [ ! -f "$APP_BIN" ]; then
    echo "❌ 未找到编译产物: $APP_BIN"
    exit 1
fi

if [ "$BUILD_ONLY" -eq 1 ]; then
    echo "✅ 编译完成: $APP_BIN"
    exit 0
fi

# 编译成功后关闭已有运行实例，再启动新实例
if [ -z "$ISOLATED_DIRECTORY" ] && pgrep -x "PaperRss" >/dev/null 2>&1; then
    echo "🛑 检测到已运行的 PaperRss 实例，正在关闭..."
    pkill -x "PaperRss" || true
    sleep 0.5
fi

echo "🚀 启动最新 PaperRss (控制台输出已连接，按 Ctrl+C 退出)..."
if [ -n "$ISOLATED_DIRECTORY" ]; then
    env CFFIXED_USER_HOME="$ISOLATED_DIRECTORY" "$APP_BIN" &
    APP_PID=$!
    wait "$APP_PID"
else
    exec "$APP_BIN"
fi
