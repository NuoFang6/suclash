package io.github.suclash.control

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 磁贴/通知共用的状态语义。 */
object TileState {
    const val TILE_ON = "on"
    const val TILE_OFF = "off"
    const val TILE_STARTING = "starting"
    const val TILE_STOPPING = "stopping"
    const val TILE_PANIC = "panic"

    private val VALID = setOf(TILE_ON, TILE_STARTING, TILE_STOPPING, TILE_PANIC)

    private val PID_RE = Regex("""pid=(\d+)""")
    private val MODE_RE = Regex("""mode=(\w+)""")

    fun normalize(raw: String?): String {
        val s = raw?.trim().orEmpty()
        return if (s in VALID) s else TILE_OFF
    }

    /** 从 clashctl status 全文输出中提取 state= 值 */
    private fun parseState(statusOut: String): String =
        STATE_RE.find(statusOut)?.groupValues?.get(1).let(::normalize)

    /** root 读取状态并刷新通知（结果派发主线程）。 */
    // TODO 用户手动启停后，有概率出现通知显示的状态与实际状态不同步的问题，待排查
    fun sync(c: Context) {
        appScope.launch(mainDispatcher) {
            val out = withContext(Dispatchers.IO) { Root.ctl("status", 20) }
            val state = parseState(out)

            var detail = ""
            if (state == TILE_ON) {
                PID_RE.find(out)?.takeIf { it.groupValues[1] != "-1" }?.let {
                    detail = "pid ${it.groupValues[1]}"
                }
                MODE_RE.find(out)?.let {
                    detail = it.groupValues[1] + if (detail.isEmpty()) "" else " · $detail"
                }
            }
            Notif.post(c, state, detail)
        }
    }
}
