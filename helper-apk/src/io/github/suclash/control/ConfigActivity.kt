package io.github.suclash.control

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import java.io.IOException

/**
 * 配置管理：临时编辑器 + 导入配置文件 + 用其他应用打开。
 * 配置源文件 /data/adb/suclash/config.yaml 由 root 读写，核心运行中应用时走 clashctl reload（SIGHUP）。
 */
class ConfigActivity : Activity() {

    private lateinit var status: TextView
    private lateinit var editor: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showMain()
    }

    // ---------------- 视图 ----------------

    private fun showMain() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(16), dp(18), dp(16))
        }

        TextView(this).apply {
            setText("⚡ 配置管理")
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
        }.let(root::addView)

        status = TextView(this).apply {
            setPadding(0, dp(8), 0, dp(8))
            textSize = 13f
        }
        root.addView(status)

        root.addView(btn("编辑配置") { showEditor() })
        root.addView(btn("导入配置文件") { pickFile() })
        root.addView(btn("用其他应用打开") { openExternal() })
        root.addView(btn("重新导入外部编辑") { reimportExternal() })
        root.addView(btn("重置 UI（从模块目录恢复面板）") {
            val r = Root.exec("sh ${Root.SCRIPT} reset-ui", 30)
            toast(if (r.ok) r.out.trim() else "重置失败：${r.err}")
            refreshStatus()
        })
        root.addView(btn("返回") { finish() })

        setContentView(
            ScrollView(this).apply {
                addView(
                    root,
                    ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT
                    )
                )
            }
        )
        refreshStatus()
    }

    private fun showEditor() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(12), dp(12), dp(12))
        }

        TextView(this).apply {
            setText("编辑 $CFG\n保存后核心运行中则自动重载，否则启动时生效。")
            textSize = 12f
            setPadding(0, 0, 0, dp(8))
        }.let(root::addView)

        editor = EditText(this).apply {
            gravity = Gravity.TOP or Gravity.START
            typeface = Typeface.MONOSPACE
            textSize = 12f
            setHorizontallyScrolling(false)
            setText(readConfig().orEmpty())
        }
        root.addView(
            editor,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
        )

        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(btn("保存并应用") {
                toast(apply(editor.text.toString()))
                showMain()
            })
            addView(btn("取消") { showMain() })
        })

        setContentView(root)
    }

    private fun btn(label: String, onClick: (View) -> Unit): Button =
        Button(this).apply {
            setText(label)
            isAllCaps = false
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(6) }
            setOnClickListener(onClick)
        }

    // ---------------- 数据读写 ----------------

    private fun readConfig(): String? {
        val r = Root.exec("cat $CFG", 20)
        return r.out.takeIf { r.ok }
    }

    /** 写私有临时文件，再经 root 覆盖到数据目录；运行中则重载。 */
    private fun apply(content: String): String {
        val tmp = File(filesDir, "config-import.yaml")
        try {
            tmp.writeText(content)
        } catch (e: IOException) {
            return "写临时文件失败：$e"
        }
        val w = Root.exec("cat '${tmp.absolutePath}' > $CFG && chmod 644 $CFG", 30)
        if (!w.ok) return "写入配置失败（无 root？）"
        if (state() == "on") {
            val r = Root.exec("sh ${Root.SCRIPT} reload", 30)
            return "已保存并重载：${r.out.trim()}"
        }
        return "已保存（核心未运行，启动后生效）"
    }

    private fun state(): String {
        val r = Root.exec("sh ${Root.SCRIPT} status", 20)
        return STATE_RE.find(r.out)?.groupValues?.get(1) ?: "off"
    }

    private fun refreshStatus() {
        val st = state()
        val t = "核心：" + when (st) {
            "on" -> "运行中"
            "panic" -> "已熔断"
            else -> "已停止"
        }
        status.text = "$t\n配置：$CFG"
    }

    // ---------------- 导入 ----------------

    private fun pickFile() {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(i, REQ_IMPORT)
        } catch (_: Exception) {
            toast("无法打开文件选择器")
        }
    }

    // ---------------- 用其他应用打开 ----------------

    private fun openExternal() {
        val content = readConfig() ?: run {
            toast("读取配置失败")
            return
        }
        val f = File(filesDir, "config-export.yaml")
        try {
            f.writeText(content)
        } catch (e: IOException) {
            toast("导出失败：$e")
            return
        }

        val i = Intent(Intent.ACTION_EDIT).apply {
            setDataAndType(
                Uri.parse("content://${ConfigProvider.AUTHORITY}/config"),
                "text/yaml"
            )
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        }
        try {
            startActivityForResult(i, REQ_EXTERNAL)
        } catch (_: Exception) {
            toast("未找到可编辑 YAML 的应用")
        }
    }

    private fun reimportExternal() {
        val f = File(filesDir, "config-export.yaml")
        if (!f.exists()) {
            toast("尚无外部编辑导出，请先「用其他应用打开」")
            return
        }
        try {
            toast(apply(f.readText()))
            refreshStatus()
        } catch (e: IOException) {
            toast("读取外部编辑失败：$e")
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(req: Int, res: Int, data: Intent?) {
        super.onActivityResult(req, res, data)
        if (res != RESULT_OK || data == null) return
        when (req) {
            REQ_IMPORT -> {
                val u = data.data ?: return
                try {
                    val content = readUri(u)
                    if (content == null) {
                        toast("读取所选文件失败")
                        return
                    }
                    toast(apply(content))
                    refreshStatus()
                } catch (e: IOException) {
                    toast("导入失败：$e")
                }
            }

            REQ_EXTERNAL ->
                toast("已从外部编辑返回，点「重新导入外部编辑」应用")
        }
    }

    private fun readUri(u: Uri): String? =
        contentResolver.openInputStream(u)?.use { it.readBytes().toString(Charsets.UTF_8) }

    private companion object {
        const val CFG = "/data/adb/suclash/config.yaml"
        const val REQ_IMPORT = 1
        const val REQ_EXTERNAL = 2
    }
}
