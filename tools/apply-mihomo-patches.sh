#!/usr/bin/env bash
# =====================================================================
# 将 mihomo-patches 目录下的补丁按顺序应用到 mihomo 子模块
# =====================================================================

# TODO 现在把web悬浮面板补丁到mihomo源码的方案不太洁净

# 遇到错误立即退出
set -e

# 获取脚本所在目录和项目根目录，确保在任何位置执行脚本都能正确定位
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

MIHOMO_DIR="$ROOT_DIR/mihomo"
PATCHES_DIR="$ROOT_DIR/mihomo-patches"

# 检查目录是否存在
if [ ! -d "$MIHOMO_DIR" ]; then
    echo "❌ 未找到 mihomo 子模块目录: $MIHOMO_DIR"
    exit 1
fi

if [ ! -d "$PATCHES_DIR" ]; then
    echo "⚠️ 未找到补丁目录: $PATCHES_DIR，跳过补丁应用。"
    exit 0
fi

# 查找所有 .patch 文件并按名称排序 (确保 0001 在 0002 之前应用)
# 使用 nullglob 防止目录为空时 bash 将 "*.patch" 当作普通字符串处理
shopt -s nullglob
# Git Bash (Windows) 下 pwd 产生 POSIX 风格路径（/c/...），git apply 无法识别，
# 统一转换为 C:/... 混合风格（cygpath 在 Git Bash 中必然存在，Linux 下无此命令则原样保留）
PATCHES_DIR_NATIVE="$PATCHES_DIR"
if command -v cygpath >/dev/null 2>&1; then
    PATCHES_DIR_NATIVE=$(cygpath -m "$PATCHES_DIR")
fi
PATCH_FILES=("$PATCHES_DIR_NATIVE"/*.patch)
shopt -u nullglob

if [ ${#PATCH_FILES[@]} -eq 0 ]; then
    echo "⚠️ 补丁目录为空，跳过补丁应用。"
    exit 0
fi

# 进入子模块目录准备打补丁
cd "$MIHOMO_DIR"

echo "🩹 开始应用 mihomo 补丁 (共 ${#PATCH_FILES[@]} 个)..."

for patch in "${PATCH_FILES[@]}"; do
    patch_name=$(basename "$patch")
    
    # 1. 检查补丁是否已经应用 (通过尝试“反向应用”来检查)
    # 如果反向检查成功，说明当前代码已经包含了该补丁的内容
    if git apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "✅ 已应用，跳过: $patch_name"
        continue
    fi
    
    # 2. 检查补丁是否可以正常应用 (检查上下文是否匹配)
    if ! git apply --check "$patch" >/dev/null 2>&1; then
        echo "❌ 补丁应用失败 (上下文不匹配或代码已变更): $patch_name"
        echo "💡 提示：mihomo 上游代码可能已更新，导致行号或上下文错位，请在本地重新生成该补丁。"
        exit 1
    fi
    
    # 3. 正式应用补丁
    echo "⚙️ 正在应用: $patch_name"
    git apply "$patch"
done

echo "🎉 所有补丁应用完毕！"