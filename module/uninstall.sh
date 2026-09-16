#!/system/bin/sh
# uninstall.sh - 彻底清理，不留残留
MODDIR="/data/adb/modules/suclash"

# 停核心与看门狗
pkill -f "suclash/runtime.yaml" 2>/dev/null
pkill -f "suclash_helper watchdog" 2>/dev/null
for p in /data/adb/suclash/state/*.pid; do
    [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null
done
sleep 1
pkill -9 -f "suclash/runtime.yaml" 2>/dev/null
pkill -9 -f "suclash_helper watchdog" 2>/dev/null

# 删除全部持久化数据
rm -rf /data/adb/suclash

# 移除辅助 App：卸载发生在重启早期，pm 可能未就绪 → 后台重试
(
    i=0
    while [ "$i" -lt 12 ]; do
        if pm uninstall --user 0 io.github.suclash.control >/dev/null 2>&1; then
            exit 0
        fi
        sleep 5
        i=$((i + 1))
    done
) >/dev/null 2>&1 &

exit 0
