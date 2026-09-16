#!/system/bin/sh
# action.sh - KernelSU 管理器「Action」按钮：进程管理菜单
#
# 菜单（通过音量键选择，getevent 直接读取输入设备，无需终端交互）：
#   音量上 = 强制停止模块所有进程（mihomo/看门狗），并尽力还原修改（不考虑当前状态）
#   音量下 = 重启模块（stop + start，含看门狗；顺带清除熔断状态）
#   20 秒无操作自动退出

MODDIR="/data/adb/modules/suclash"
SCR="$MODDIR/scripts"
STATE="/data/adb/suclash/state"

[ -d /data/adb/ksu/bin ] && PATH="/data/adb/ksu/bin:$PATH"
export PATH

# ---------- 工具 ----------

# 列出模块当前运行的全部进程
list_procs() {
    _found=0
    for _pat in "suclash/runtime.yaml" "suclash_helper watchdog"; do
        for _p in $(pgrep -f "$_pat" 2>/dev/null); do
            _cmd=$(cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')
            echo "  [$_p] ${_cmd:-$_pat}"
            _found=1
        done
    done
    [ "$_found" = 0 ] && echo "  （无运行中的模块进程）"
}

# 音量键选择：0=音量上 1=音量下 2=超时
get_key() {
    _deadline=$(( $(date +%s) + 20 ))
    while [ "$(date +%s)" -lt "$_deadline" ]; do
        # 每次监听 3 秒：-q 静默 -l 键名 -c 2 收到 2 个事件即返回
        _line=$(timeout 3 getevent -qlc 2 2>/dev/null | head -n1)
        case "$_line" in
            *KEY_VOLUMEUP*)   return 0 ;;
            *KEY_VOLUMEDOWN*) return 1 ;;
            # 其他输入事件（触屏等）视为噪音，继续等待
        esac
    done
    return 2
}

# ---------- 操作 ----------

# 音量上：强制停止全部进程 + 尽力还原修改（不考虑状态）
force_stop() {
    echo ">> 强制停止模块所有进程..."
    # 先杀看门狗（防止它把核心拉回来），再杀核心；宽限 1 秒后补 SIGKILL
    # TODO 退出核心时优先等其优雅退出，强杀非必要不执行。
    # TODO 考虑出现极端情况如 僵尸进程、无法杀死 时的解决方案
    pkill -f "suclash_helper watchdog" 2>/dev/null
    pkill -f "suclash/runtime.yaml" 2>/dev/null
    sleep 1
    pkill -9 -f "suclash_helper watchdog" 2>/dev/null
    pkill -9 -f "suclash/runtime.yaml" 2>/dev/null

    echo ">> 还原修改（尽力而为）..."
    # TUN 网卡：mihomo 被强杀时可能残留，手动删除（模块不写 iptables/ip rule，无其他系统修改）
    for _if in Meta mihomo; do
        ip link del "$_if" 2>/dev/null
    done

    # 清理全部运行状态：pid、熔断、崩溃计数、探测标记、磁贴
    rm -f "$STATE/mihomo.pid" "$STATE/watchdog.pid" "$STATE/panic" \
          "$STATE/crashes" "$STATE/probe_fail" 2>/dev/null
    echo off > "$STATE/tile" 2>/dev/null

    echo ">> 完成（开机自启状态未改变，重启后仍按原 enabled 拉起）"
    sh "$SCR/clashctl" status | head -2
}

# 音量下：重启模块（用户显式操作，顺带清除熔断状态）
restart_module() {
    echo ">> 重启模块..."
    rm -f "$STATE/panic" "$STATE/crashes" 2>/dev/null
    sh "$SCR/clashctl" restart
}

# ---------- 主流程 ----------

echo "== SU Clash (mihomo) =="
echo ""
echo "当前进程:"
list_procs
echo ""
echo ">>> 请按音量键选择（20 秒无操作自动退出）:"
echo "    音量上 = 强制停止全部进程并还原修改"
echo "    音量下 = 重启模块"
echo ""

get_key
case $? in
    0) force_stop ;;
    1) restart_module ;;
    *) echo ">> 20 秒无操作，退出" ;;
esac
