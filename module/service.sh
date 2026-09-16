#!/system/bin/sh
# service.sh - 开机启动入口（不阻塞，后台拉起）
# 生命周期胶水保留 shell；核心管理逻辑在 bin/suclash_helper（Go 二进制）
MODDIR="/data/adb/modules/suclash"
DATA="/data/adb/suclash"
HELPER="$MODDIR/bin/suclash_helper"

{
    # 等待系统启动完成（最多 3 分钟）
    _i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$_i" -lt 90 ]; do
        sleep 2
        _i=$((_i + 1))
    done
    # 给 netd/网络栈留出稳定时间
    sleep 5

    # 等待基础网络就绪（最多 90s），确保 mihomo 启动时能拉取订阅/规则
    _j=0
    while [ "$_j" -lt 30 ]; do
        ping -c1 -W1 223.5.5.5 >/dev/null 2>&1 && break
        sleep 3
        _j=$((_j + 1))
    done

    mkdir -p "$DATA/state" "$DATA/logs" 2>/dev/null
    # 本次开机的新日志（避免跨启动累积的旧错误干扰排查）
    : >"$DATA/logs/boot.log" 2>/dev/null

    # 权限兜底：安装器解压可能丢失可执行位
    chmod 755 "$MODDIR/bin/mihomo" "$MODDIR/bin/suclash_helper" "$MODDIR/scripts/"* "$MODDIR/"*.sh 2>/dev/null

    # 首次安装默认启用；按 enabled 决定是否自启
    # TODO 此处可能有bug，会导致app无法连接到控制器，必须手动 module\action.sh 启动模块。
    [ -f "$DATA/state/enabled" ] || echo 1 >"$DATA/state/enabled" 2>/dev/null
    [ "$(cat "$DATA/state/enabled" 2>/dev/null)" != "0" ] &&
        "$HELPER" start >>"$DATA/logs/boot.log" 2>&1
} >/dev/null 2>&1 &

# 幂等安装/更新辅助 APK（磁贴+通知快捷入口）
# 触发条件：App 未安装，或模块更新带了新 APK ；
# 安装成功才更新指纹，失败则下次开机重试
# TODO 如果失败或未安装，使用 module\module.prop 的 description 体现模块状态
{
    sleep 20
    APK="$MODDIR/bin/MihomoControl.apk"
    if [ -f "$APK" ]; then
        _cur=$(md5sum "$APK" 2>/dev/null | cut -d' ' -f1)
        _last=$(cat "$DATA/state/apk.md5" 2>/dev/null)
        if ! pm path io.github.suclash.control >/dev/null 2>&1 || [ "$_cur" != "$_last" ]; then
            if pm install -r "$APK" >/dev/null 2>&1; then
                echo "$_cur" >"$DATA/state/apk.md5" 2>/dev/null
            fi
        fi
    fi
} >/dev/null 2>&1 &

exit 0
