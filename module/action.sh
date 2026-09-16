#!/system/bin/sh
# action.sh - KernelSU 管理器「Action」按钮：进程管理菜单
#
# 菜单（通过音量键选择，getevent 直接读取输入设备，无需终端交互）：
#   音量上 = 强制停止模块所有进程（mihomo/看门狗），并尽力还原修改（不考虑当前状态）
#   音量下 = 重启模块（stop + start，含看门狗；顺带清除熔断状态）
#   20 秒无操作自动退出

install_dir="/data/adb/modules/suclash"
scripts_dir="$install_dir/scripts"
state_file="/data/adb/suclash/state"

[ -d /data/adb/ksu/bin ] && PATH="/data/adb/ksu/bin:$PATH"
export PATH # 这里不会导致环境泄露

# 进程匹配模式集中定义，避免在多处硬编码
CORE_PAT="suclash/runtime.yaml"
WDOG_PAT="suclash_helper watchdog"

# 优雅退出宽限时间（秒）：超过则升级为 SIGKILL
WDOG_GRACE=2
CORE_GRACE=3

# ---------- 工具 ----------

log() { echo ">> $*"; }

# 短睡眠：优先 0.2s（toybox/busybox 支持小数），失败退回 1s
sleep_short() { sleep 0.2 2>/dev/null || sleep 1; }

# 列出模块当前运行的全部进程
list_procs() {
    _found=0
    for _pat in "$CORE_PAT" "$WDOG_PAT"; do
        for _p in $(pgrep -f "$_pat" 2>/dev/null); do
            _cmd=$(tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null)
            printf '  [%s] %s\n' "$_p" "${_cmd:-$_pat}"
            _found=1
        done
    done
    [ "$_found" -eq 0 ] && echo "  （无运行中的模块进程）"
    return 0
}

# 音量键选择：0=音量上 1=音量下 2=超时（20s）
get_key() {
    command -v getevent >/dev/null 2>&1 || return 2

    _deadline=$(($(date +%s) + 20))
    while [ "$(date +%s)" -lt "$_deadline" ]; do
        _line=$(timeout 3 getevent -qlc 2 2>/dev/null | head -n1)
        case "$_line" in
        *KEY_VOLUMEUP*) return 0 ;;
        *KEY_VOLUMEDOWN*) return 1 ;;
        esac
    done
    return 2
}

# 向某类进程发信号：$1=模式  $2=信号（默认 TERM）
signal_pat() {
    if [ -n "$2" ]; then
        pkill "$2" -f "$1" 2>/dev/null
    else
        pkill -f "$1" 2>/dev/null
    fi
}

# 判断 pid 是否已退出（含僵尸）
# 返回 0 = 已退出（进程不存在 或 state=Z）  1 = 仍存活
# 说明：僵尸进程 kill -0 仍成功，但已不能工作，父进程回收前无法再操作，按已退出处理
pid_gone() {
    _pid="$1"
    kill -0 "$_pid" 2>/dev/null || return 0
    case "$(awk '{print $3}' "/proc/$_pid/stat" 2>/dev/null)" in
    "" | Z) return 0 ;;
    *) return 1 ;;
    esac
}

# 优雅停止某一类进程：SIGTERM → 宽限内轮询 → 返回是否全部退出
# 返回 0 = 全部退出（含僵尸）  1 = 宽限期满仍有存活
stop_pat_graceful() {
    _pat="$1"
    _grace="$2"

    _snap=$(pgrep -f "$_pat" 2>/dev/null)
    [ -z "$_snap" ] && return 0

    pkill -f "$_pat" 2>/dev/null

    _deadline=$(($(date +%s) + _grace))
    while [ "$(date +%s)" -le "$_deadline" ]; do
        _alive=0
        for _p in $_snap; do
            if ! pid_gone "$_p"; then
                _alive=1
                break
            fi
        done
        [ "$_alive" -eq 0 ] && return 0
        sleep_short
    done
    return 1
}

# 报告仍存活的模块进程（僵尸/不可杀），仅诊断，不阻塞流程
# 返回 0 = 干净  1 = 有残留
report_stuck() {
    _stuck=""
    for _pat in "$WDOG_PAT" "$CORE_PAT"; do
        for _p in $(pgrep -f "$_pat" 2>/dev/null); do
            _stuck="$_stuck $_p"
        done
    done
    [ -z "$_stuck" ] && return 0

    log "警告：以下进程未能退出（多为僵尸，父进程回收后会自动消失）："
    for _p in $_stuck; do
        _st=$(awk '{print $3}' "/proc/$_p/stat" 2>/dev/null)
        _cmd=$(tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null)
        printf '  [%s] state=%s %s\n' "$_p" "${_st:-?}" "${_cmd:-?}"
    done
    return 1
}

# ---------- 操作 ----------

# 音量上：强制停止全部进程 + 尽力还原修改（不考虑状态）
force_stop() {
    log "强制停止模块所有进程（优先优雅退出）..."

    # 1) 先停看门狗：否则它会把核心拉回来
    if ! stop_pat_graceful "$WDOG_PAT" "$WDOG_GRACE"; then
        log "看门狗 ${WDOG_GRACE}s 内未退出，升级为 SIGKILL"
        signal_pat "$WDOG_PAT" -9
        sleep_short
    fi

    # 2) 再停核心：SIGTERM → 宽限 → 必要时 SIGKILL
    if ! stop_pat_graceful "$CORE_PAT" "$CORE_GRACE"; then
        log "核心 ${CORE_GRACE}s 内未退出，升级为 SIGKILL"
        signal_pat "$CORE_PAT" -9
        sleep_short
    fi

    # 3) 僵尸 / 不可杀进程兜底：仅报告，不阻塞还原流程
    report_stuck || true

    log "还原修改（尽力而为）..."
    # TUN 网卡：mihomo 被强杀时可能残留，手动删除
    for _if in Meta mihomo; do
        ip link del "$_if" 2>/dev/null
    done

    # 清理全部运行状态：pid、熔断、崩溃计数、探测标记、磁贴
    rm -f "$STATE/mihomo.pid" "$STATE/watchdog.pid" "$STATE/panic" \
        "$STATE/crashes" "$STATE/probe_fail"
    echo off >"$STATE/tile" 2>/dev/null

    log "完成（开机自启状态未改变，重启后仍按原 enabled 拉起）"
    sh "$scripts_dir/clashctl" status | head -2
}

# 音量下：重启模块（用户显式操作，顺带清除熔断状态）
restart_module() {
    log "重启模块..."
    rm -f "$STATE/panic" "$STATE/crashes" 2>/dev/null
    sh "$scripts_dir/clashctl" restart
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
