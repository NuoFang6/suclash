package io.github.suclash.control

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * SU Clash 主界面：核心运行中 → 全屏 WebView 加载 zashboard（注入与 KSU 管理器
 * 同名的 ksu root 桥，悬浮面板同一套代码）；核心未运行 → 原生提示页（启动核心）。
 */
class MainActivity : Activity() {

    /** 界面私有作用域：onDestroy 时统一取消，避免协程泄漏 */
    private val scope = CoroutineScope(SupervisorJob() + mainDispatcher)

    private var web: WebView? = null
    private var started = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotifPermission()
        refreshEntry()
    }

    override fun onResume() {
        super.onResume()
        if (!started) refreshEntry()
        TileState.sync(this)
    }

    private fun requestNotifPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    /** 读取核心状态，决定进入 webview 还是提示页。 */
    private fun refreshEntry() {
        scope.launch {
            val out = withContext(Dispatchers.IO) {
                Root.exec("sh ${Root.SCRIPT} status; sh ${Root.SCRIPT} panel").out
            }
            val state = STATE_RE.find(out)?.groupValues?.get(1) ?: "noroot"
            val panelUrl = PANEL_RE.find(out)?.groupValues?.get(1)

            when {
                state == "on" && panelUrl != null -> showWeb(panelUrl)
                state == "noroot" ->
                    showHint("无法连接 root shell\n\n请在 KernelSU 管理器中授权本应用后重试。")

                else ->
                    showHint("核心未运行\n\n启动后自动进入 zashboard 面板。")
            }
        }
    }

    private fun showHint(text: String) {
        started = false
        setContentView(buildHint(text))
    }

    private fun buildHint(text: String): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(20))
        }

        TextView(this).apply {
            setText("⚡ SU Clash  [mihomo]")
            textSize = 19f
            typeface = Typeface.DEFAULT_BOLD
        }.let(root::addView)

        TextView(this).apply {
            setText(text)
            textSize = 14f
            setPadding(0, dp(16), 0, dp(4))
        }.let(root::addView)

        root.addView(Button(this).apply {
            setText("启动核心")
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(16) }
            setOnClickListener { startCore() }
        })

        root.addView(Button(this).apply {
            setText("重新检测")
            setOnClickListener { refreshEntry() }
        })

        root.addView(Button(this).apply {
            setText("配置")
            setOnClickListener { startActivity(Intent(this@MainActivity, ConfigActivity::class.java)) }
        })

        TextView(this).apply {
            textSize = 11.5f
            setPadding(0, dp(12), 0, 0)
            setText(
                "提示：若启动按钮无效，请在 KernelSU 管理器「超级用户」中授权本应用。\n" +
                        "核心运行后本应用即 zashboard 面板，核心启停等操作在面板右下角悬浮窗中。"
            )
        }.let(root::addView)

        return ScrollView(this).apply {
            setFillViewport(true)
            addView(
                root,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                )
            )
        }
    }

    private fun startCore() {
        Toast.makeText(this, "正在启动核心…", Toast.LENGTH_SHORT).show()
        Root.ctlAsync("start") {
            scope.launch(mainDispatcher) {
                delay(800) // 等价旧实现 mainHandler.postDelayed(refreshEntry, 800)
                refreshEntry()
            }
        }
    }

    private fun showWeb(url: String) {
        started = true
        val content = FrameLayout(this)
        web = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.cacheMode = WebSettings.LOAD_NO_CACHE
            setBackgroundColor(0xFF0F172A.toInt())
            addJavascriptInterface(KsuBridge(this@MainActivity), "ksu")
            webViewClient = WebViewClient()
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }
        content.addView(web)
        content.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            } else {
                @Suppress("DEPRECATION")
                view.setPadding(
                    insets.systemWindowInsetLeft,
                    insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight,
                    insets.systemWindowInsetBottom
                )
            }
            insets
        }
        setContentView(content)
        content.requestApplyInsets()
        web?.loadUrl(url)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val w = web
        if (w != null && w.canGoBack()) w.goBack() else super.onBackPressed()
    }

    override fun onDestroy() {
        scope.cancel()
        web?.destroy()
        super.onDestroy()
    }

    private companion object {
        /** panel= 后跟 http(s) 面板地址 */
        val PANEL_RE = Regex("""panel=(http\S+)""")
    }
}
