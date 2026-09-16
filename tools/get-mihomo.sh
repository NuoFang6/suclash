#!/usr/bin/env bash
# =====================================================================
# 更新 mihomo 子模块
# =====================================================================

# 遇到错误立即退出
set -e

MIHOMO_DIR="mihomo"

# 确保在仓库根目录执行
if [ ! -d "$MIHOMO_DIR" ]; then
    echo "❌ 未找到 mihomo 子模块目录，请确保在仓库根目录运行此脚本。"
    exit 1
fi

# ==============================
# 1. 获取更新前的版本
# ==============================
echo "🔍 正在检查 mihomo 子模块状态..."
# 仅初始化 mihomo，不影响其他可能存在的子模块
git submodule update --init "$MIHOMO_DIR"

# 获取精确的短 Hash 作为版本号
OLD_VERSION=$(git -C "$MIHOMO_DIR" rev-parse --short HEAD)
echo "📌 当前 mihomo 版本: $OLD_VERSION"

# ==============================
# 2. 同步上游最新代码
# ==============================
echo "🔄 尝试同步 mihomo 上游最新代码..."
# --remote 会拉取子模块跟踪的远程分支的最新提交
git submodule update --remote "$MIHOMO_DIR"

NEW_VERSION=$(git -C "$MIHOMO_DIR" rev-parse --short HEAD)

# ==============================
# 3. 提交子模块更新 (如果版本有变化)
# ==============================
if [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
    echo "✨ mihomo 已更新至新版本: $NEW_VERSION"

    # 🌟 核心优化：仅添加 mihomo 目录，绝对不使用 git add . 防止误提交临时文件
    git add "$MIHOMO_DIR"

    # 检查是否有 staged 的更改
    if ! git diff --staged --quiet; then
        git commit -m "[skip ci] Chore: auto-update mihomo submodule to $NEW_VERSION"
        echo "✅ 已提交子模块更新"

        # 💡 关于推送：
        # 在 GitHub Actions 中直接 git push 需要配置 PAT 或确保 GITHUB_TOKEN 有写权限。
        # 如果确认需要推送到当前分支，请取消下面这行的注释：
        git push origin HEAD
    else
        echo "⚠️ 版本号变化但 git 未检测到暂存区更改，跳过提交。"
    fi
else
    echo "✅ mihomo 已是最新版本 ($OLD_VERSION)，无需更新。"
fi
