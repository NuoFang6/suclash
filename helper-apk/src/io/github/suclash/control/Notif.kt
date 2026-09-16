package io.github.suclash.control

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/** 常驻通知：静态通知（无前台服务），动作经 ActionReceiver 执行。 */
object Notif {
    private const val CHANNEL = "ksuc_core"
    private const val ID = 1001

    /** 通知按钮动作的 action 标识 */
    const val ACTION_CMD = "ksuc.CMD"

    private fun nm(c: Context) =
        c.getSystemService(NotificationManager::class.java)

    private fun ensureChannel(c: Context) {
        val ch = NotificationChannel(
            CHANNEL,
            c.getString(R.string.notif_channel),
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            description = "SU Clash 快捷操作"
            setShowBadge(false)
        }
        nm(c).createNotificationChannel(ch)
    }

    private fun action(c: Context, cmd: String): PendingIntent =
        PendingIntent.getBroadcast(
            c,
            cmd.hashCode(),
            Intent(c, ActionReceiver::class.java)
                .setAction(ACTION_CMD)
                .putExtra("cmd", cmd),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun openApp(c: Context): PendingIntent? {
        val i = c.packageManager.getLaunchIntentForPackage(c.packageName)
            ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
            ?: return null
        return PendingIntent.getActivity(
            c, 7, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** 依据状态文件构建/刷新通知。state: on|off|starting|stopping|panic */
    fun post(c: Context, state: String, detail: String?) {
        ensureChannel(c)

        val text = when (state) {
            "on" -> "运行中" + (detail?.let { " · $it" } ?: "")
            "panic" -> "已熔断（多次崩溃自动停止）"
            "starting" -> "启动中…"
            "stopping" -> "停止中…"
            else -> "已停止"
        }

        val b = Notification.Builder(c, CHANNEL).apply {
            setSmallIcon(R.drawable.ic_tile)
            setContentTitle(c.getString(R.string.notif_title))
            setOngoing(true)
            setOnlyAlertOnce(true)
            setContentIntent(openApp(c))
            setShowWhen(false)
            setContentText(text)
        }

        when (state) {
            "on" -> {
                b.addAction(Notification.Action.Builder(null, "停止核心", action(c, "stop")).build())
                b.addAction(Notification.Action.Builder(null, "重启核心", action(c, "restart")).build())
            }

            "panic" ->
                b.addAction(Notification.Action.Builder(null, "恢复并启动", action(c, "resume")).build())

            else ->
                b.addAction(Notification.Action.Builder(null, "启动", action(c, "start")).build())
        }

        try {
            nm(c).notify(ID, b.build())
        } catch (_: SecurityException) {
            // 通知权限未授予时静默跳过
        }
    }

    fun cancel(c: Context) = nm(c).cancel(ID)
}
