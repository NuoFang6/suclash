set -e

echo "GOOS=$GOOS, GOARCH=$GOARCH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT/build"
mkdir -p "$OUTPUT_DIR"

# 构建参数
VERSION="${VN:-1.0.0}"
COMMIT=$(git -C "$ROOT/mihomo" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# LDFLAGS：体积优化 + 版本注入
LDFLAGS="
    -s -w
    -X github.com/metacubex/mihomo/constant.Version=$VERSION
    -X github.com/metacubex/mihomo/constant.BuildTime=$BUILD_TIME
    -X github.com/metacubex/mihomo/constant.GitCommit=$COMMIT
"

# 纯 Go 内部链接（android/arm64 等）加 --static 消除 glibc 动态依赖；
# cgo（android/amd64 需 NDK 外部链接）下 --static 会导致 bionic 链接失败，须去掉。
if [ "${CGO_ENABLED:-0}" != "1" ]; then
    LDFLAGS="$LDFLAGS -extldflags --static"
fi

echo "🔨 编译 mihomo..."
cd "$ROOT/mihomo"

# 面板相关脚本供 hub/route 的 go:embed 使用（mihomo-patches/0005、0006）。
# 不入补丁，始终以本仓库最新版为准。
#   panel.js          悬浮面板 UI
#   storage_bridge.js 面板设置的模块级存储桥接（注入到 <head> 之后）
cp "$ROOT/module/webroot-src/panel.js" hub/route/panel.js
cp "$ROOT/module/webroot-src/storage-bridge.js" hub/route/storage_bridge.js

go build \
    -tags "with_gvisor" \
    -trimpath \
    -buildvcs=false \
    -ldflags="$LDFLAGS" \
    -o "$OUTPUT_DIR/mihomo" .

echo "✅ 编译完成: $OUTPUT_DIR/mihomo"
ls -lh "$OUTPUT_DIR/mihomo"
