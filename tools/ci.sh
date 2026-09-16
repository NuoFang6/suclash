#!/usr/bin/env bash
# =====================================================================
# 主构建调度脚本
# =====================================================================

# 遇到任何错误立即退出，防止子脚本失败后继续执行后续步骤
set -e

# ==============================
# 0. CI 环境初始化
# ==============================
if [ -n "$GITHUB_ACTIONS" ] || [ -n "$CI" ]; then
    echo "🤖 检测到 CI 环境，正在配置 Git 全局信息..."
    git config --global user.name "github-actions[bot]"
    git config --global user.email "github-actions[bot]@users.noreply.github.com"
fi

# ==============================
# 1. 目录准备与依赖获取
# ==============================
echo "📂 创建临时目录"
TOOLS_DIR="${GITHUB_WORKSPACE:-$(pwd)}/tmp"
mkdir -p "$TOOLS_DIR"
BUILD_DIR="${GITHUB_WORKSPACE:-$(pwd)}/build"
mkdir -p "$BUILD_DIR"

echo "🌐 获取并更新 mihomo"
bash tools/get-mihomo.sh

echo "🩹 应用 mihomo 补丁..."
bash tools/apply-mihomo-patches.sh

echo "🎨 下载最新 zashboard"
bash tools/get-zashboard.sh

echo "🛠️ 准备 helper-apk 构建工具"
bash tools/get-tools.sh

# get-tools.sh 把 JAVA_HOME / platform_android_jar / PATH / GOROOT 写入 tmp/.env；
# CI 中 GITHUB_ENV 仅对后续 step 生效，同 step 内需显式 source 才能传给后续脚本
if [ -f "$TOOLS_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$TOOLS_DIR/.env"
fi

# ==============================
# 2. 编译阶段
# ==============================
echo "⚙️ 编译 helper-go"
bash tools/build-helper-go.sh

echo "📱 编译 helper-apk"
bash tools/build-helper-apk.sh

echo "🚀 编译 mihomo"
bash tools/build-mihomo.sh

# ==============================
# 3. 打包阶段
# ==============================
echo "📦 打包模块"
bash tools/package-module.sh

echo "🎉 所有构建与打包任务执行完毕！"
