#!/usr/bin/env bash
# =====================================================================
# 获取 zashboard 面板资源
# =====================================================================

# 遇到错误立即退出
set -e

# 定义目录 (与主脚本保持一致，确保绝对路径)
TOOLS_DIR="${GITHUB_WORKSPACE:-$(pwd)}/tmp"
ZASHBOARD_DIR="$TOOLS_DIR/zashboard"
ENV_FILE="$TOOLS_DIR/.env"

zashboard_repo="Zephyruso/zashboard"
zashboard_file="dist-no-fonts.zip"

# 辅助函数：环境检测与变量注入
is_ci() {
    [ -n "$GITHUB_ACTIONS" ] || [ -n "$CI" ]
}

add_to_env() {
    local key=$1 value=$2
    export "$key=$value"
    # CI 环境写入 GITHUB_ENV
    if is_ci && [ -n "$GITHUB_ENV" ]; then
        echo "$key=$value" >>"$GITHUB_ENV"
    fi
    # 本地环境写入 .env 供调试
    echo "export $key=\"$value\"" >>"$ENV_FILE"
}

echo "🎨 准备 zashboard 面板..."

# 检查必要依赖
if ! command -v jq &>/dev/null; then
    echo "❌ 缺少必要工具: jq，请先安装。"
    exit 1
fi

# 准备 curl 参数 (如果在 CI 中，自动使用 GITHUB_TOKEN 将 API 限额从 60次/小时 提升至 5000次/小时)
CURL_AUTH=()
if is_ci && [ -n "$GITHUB_TOKEN" ]; then
    CURL_AUTH+=(-H "Authorization: token $GITHUB_TOKEN")
fi

# ==============================
# 1. 获取最新 Release 信息
# ==============================
echo "正在获取 zashboard 最新 Release 信息..."
# 使用纯 curl 调用 GitHub API，一次性获取所有信息，替代两次 gh 调用
RELEASE_INFO=$(curl -s "${CURL_AUTH[@]}" "https://api.github.com/repos/$zashboard_repo/releases/latest")

# 注意：GitHub API 返回的字段名是下划线格式 (tag_name, target_commitish)
zashboard_ver=$(echo "$RELEASE_INFO" | jq -r '.tag_name')
zashboard_commit=$(echo "$RELEASE_INFO" | jq -r '.target_commitish[:7]')

if [ -z "$zashboard_ver" ] || [ "$zashboard_ver" == "null" ]; then
    echo "❌ 无法获取 zashboard 最新版本信息"
    echo "API 响应: $RELEASE_INFO"
    exit 1
fi

echo "检测到最新版本: $zashboard_ver ($zashboard_commit)"

# 写入环境变量
add_to_env "zashboard_ver" "$zashboard_ver"
add_to_env "zashboard_commit" "$zashboard_commit"

# ==============================
# 2. 下载并解压
# ==============================
mkdir -p "$ZASHBOARD_DIR"

# 缓存检测：如果版本未变，直接跳过下载和解压
VERSION_MARKER="$ZASHBOARD_DIR/.version"
if [ -f "$VERSION_MARKER" ] && [ "$(cat "$VERSION_MARKER")" == "$zashboard_ver" ]; then
    if [ -f "$ZASHBOARD_DIR/dist/index.html" ]; then
        echo "✅ zashboard 已是最新版本，跳过下载并重新打包。"
        node tools/patch-ui.mjs "$ZASHBOARD_DIR/dist"
        exit 0
    fi
    echo "⚠️ 缓存缺少 dist/index.html，重新下载。"
fi

# 从 JSON 中精准提取目标文件的下载链接
DOWNLOAD_URL=$(echo "$RELEASE_INFO" | jq -r ".assets[] | select(.name == \"$zashboard_file\") | .browser_download_url")

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo "❌ 未在 Release 中找到资源文件: $zashboard_file"
    exit 1
fi

echo "⬇️ 正在下载 $zashboard_file..."
curl -fSL "${CURL_AUTH[@]}" "$DOWNLOAD_URL" -o "$TOOLS_DIR/$zashboard_file"

echo "📦 正在解压到 $ZASHBOARD_DIR..."
# 覆盖已有文件 (-o)，确保面板资源是最新的
unzip -o "$TOOLS_DIR/$zashboard_file" -d "$ZASHBOARD_DIR"

# 清理下载的 zip 包，节省空间
rm "$TOOLS_DIR/$zashboard_file"

# 写入版本标记，供下次缓存使用
echo "$zashboard_ver" >"$VERSION_MARKER"

echo "修补 zashboard..."
# dist-no-fonts.zip 解压后资源在 $ZASHBOARD_DIR/dist 子目录内，显式传入
node tools/patch-ui.mjs "$ZASHBOARD_DIR/dist"

echo "✅ zashboard 面板下载完毕"
