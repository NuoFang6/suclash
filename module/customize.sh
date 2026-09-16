#!/system/bin/sh
# customize.sh - SU Clash (mihomo) 安装/升级脚本
#
# 由 ksud installer.sh source 执行（非子进程），执行前安装器已完成：
#   - 全部模块文件已解压到 $MODPATH（SKIPUNZIP=0）
#   - 默认权限：目录 0755 / 文件 0644
#   - 预置变量：$MODPATH $TMPDIR $ZIPFILE $ARCH $API 等
# 数据目录 /data/adb/suclash 不在模块目录内，升级时自动保留。

SKIPUNZIP=0

DATA_DIR="/data/adb/suclash"

# 占位符 __TARGET_ARCH__ 由 CI 打包时替换为实际架构（arm64 / amd64）。
TARGET_ARCH="__TARGET_ARCH__"
# KernelSU/Magisk 的 $ARCH 命名不同，统一到 CI 使用的规范名（arm64 / amd64）
case "$ARCH" in
    arm64)        _ARCH="arm64" ;;
    x86_64|x64)   _ARCH="amd64" ;;
    *)            abort "! 不支持的架构: $ARCH（本模块仅支持 arm64 / amd64）" ;;
esac
if [ "$TARGET_ARCH" != "$_ARCH" ]; then
    abort "! 架构不匹配：本包为 $TARGET_ARCH，但当前设备是 $_ARCH，请下载对应架构的模块包"
fi


MOD_VER=$(grep_prop version "$MODPATH/module.prop")
ui_print "- SU Clash (mihomo) $MOD_VER 安装中"

# 升级说明：更新只写入 modules_update/，旧目录 /data/adb/modules/<id> 原样保留并打
# update 标记，重启时才由 ksud 应用更新。此期间旧 mihomo 继续从旧目录运行（代理不中断），
# 与新文件零冲突，所以这里不需要也不应该停掉运行中的实例。

# 权限（补可执行位）
# 安装器默认只给 system/bin 等目录 0755，模块根下的可执行文件需手动设置
set_perm "$MODPATH/service.sh"   0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh"    0 0 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/bin/mihomo" 0 0 0755
set_perm "$MODPATH/bin/suclash_helper" 0 0 0755

# 用户数据目录（升级保留，仅补齐缺失部分）
mkdir -p "$DATA_DIR/state" "$DATA_DIR/logs" "$DATA_DIR/cache"

# zashboard 面板复制到数据目录（mihomo external-ui 安全限制：仅允许 -d 主目录内路径）
rm -rf "$DATA_DIR/ui"
cp -a "$MODPATH/ui" "$DATA_DIR/ui" || abort "! 面板复制失败"


# 用户配置：仅首次生成，升级不覆盖
if [ ! -f "$DATA_DIR/config.yaml" ]; then
    cp -f "$MODPATH/config.default.yaml" "$DATA_DIR/config.yaml"
    ui_print "- 已生成默认配置: $DATA_DIR/config.yaml"
    ui_print "  请填入你的节点/订阅后启动"
else
    ui_print "- 保留了现有用户配置"
fi

# 首次安装默认启用
[ -f "$DATA_DIR/state/enabled" ] || echo 1 > "$DATA_DIR/state/enabled"

# # 辅助 App（快捷磁贴 + 通知操作）：不在安装期 pm install。
# # 更新只写入 modules_update/，重启后由 service.sh 安装；指纹必须由
# # service.sh 在安装成功后写入，不能在这里提前写入，否则新 APK 会被跳过。
# if [ -f "$MODPATH/bin/MihomoControl.apk" ]; then
#     # 清除旧状态，兼容此前安装流程已错误写入新 APK 指纹的设备。
#     rm -f "$DATA_DIR/state/apk.md5"
#     ui_print "- 控制 App 将在重启后自动安装/更新"
# fi

ui_print ""
ui_print "  快速上手:"
ui_print "  1. 配置: /data/adb/suclash/config.yaml"
ui_print "  2. 启停: 控制中心磁贴 / 通知按钮 / 管理器Action"
ui_print "  3. 面板: 管理器 WebUI 入口 → http://127.0.0.1:9090/ui/"
ui_print "  4. CLI : sh /data/adb/modules/suclash/scripts/clashctl"
ui_print ""
