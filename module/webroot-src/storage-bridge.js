/* SU Clash：面板（zashboard）设置的「模块级存储」桥接。
 *
 * 由 mihomo 服务端内联注入到 <head> 之后，必须早于任何面板脚本求值
 * （面板在模块初始化阶段就会同步读取 localStorage）。
 *
 * 真源是模块数据目录下的 ui-storage.json（与 external-ui 同级），
 * 因此 SU Clash App / 浏览器 / WebUI 等任意入口访问面板，都共用同一套面板偏好，
 * 清除 App 数据或重装 App 都不会丢失。
 *
 * ── 分流规则（关键）────────────────────────────────────────────
 * 只共享「面板偏好」，不共享「后端连接地址」：
 *
 *   setup/*     → 各入口原生的 localStorage（不共享）
 *                 zashboard 用它保存后端地址（host:port + secret）与当前选中的后端。
 *                 这类值天然随入口而变：App 直连 127.0.0.1:9090，浏览器经端口转发走
 *                 19090，KSU WebUI 又走别的端口。若共享，A 入口写死的地址会让 B 入口
 *                 连不上后端，面板直接白屏离线。
 *
 *   其它键       → 模块级共享存储（config/*、cache/* 等）
 *                 主题、语言、排序、列显隐……这些才是用户真正想统一的设置。
 *                 （panel.js 的 seedBackend 会按入口把正确的后端地址写进本地，
 *                  恰好落在 setup/* ，与共享区互不干扰。）
 *
 * ── 逃生开关 ─────────────────────────────────────────────────
 * 地址后附加 ?nostorage 可整体回退到浏览器原生 localStorage，便于排查。
 */
(function () {
  var CFG = window.__SUCLASH_STORE__
  if (!CFG || !CFG.url) return

  try {
    if (/[?&]nostorage(?:=|&|$)/.test(window.location.search)) return
  } catch (e) { }

  function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k) }

  // 本地专属前缀：后端连接相关，按入口隔离
  function isLocal(k) { return typeof k === 'string' && k.indexOf('setup/') === 0 }

  // ---------- 原生（本地）存储：后端地址，按入口隔离 ----------
  var NATIVE = null
  try { NATIVE = window.localStorage } catch (e) { }
  if (!NATIVE) return // 连原生 localStorage 都没有，无法安全接管

  // ---------- 共享存储：面板偏好 ----------
  var DATA = {}
  try {
    var src = CFG.data
    if (src && typeof src === 'object') {
      for (var k in src) if (has(src, k) && !isLocal(k)) DATA[k] = String(src[k])
    }
  } catch (e2) { }

  function keys() {
    var out = []
    for (var k in DATA) if (has(DATA, k)) out.push(k)
    return out
  }

  var AUTH = CFG.secret ? 'Bearer ' + CFG.secret : ''
  var dirty = false
  var changeGeneration = 0
  var timer = null
  var fails = 0

  function markDirty() {
    dirty = true
    changeGeneration++
    if (timer) clearTimeout(timer)
    timer = setTimeout(function () { timer = null; flush(false) }, 400)
  }

  function flush(sync) {
    if (timer) { clearTimeout(timer); timer = null }
    if (!dirty) return
    dirty = false
    if (fails > 5) return
    try {
      var xhr = new XMLHttpRequest()
      xhr.open('PUT', CFG.url, !sync)
      xhr.setRequestHeader('Content-Type', 'application/json')
      if (AUTH) xhr.setRequestHeader('Authorization', AUTH)
      if (!sync) {
        xhr.onloadend = function () {
          if (xhr.status >= 200 && xhr.status < 300) { fails = 0; return }
          fails++
          dirty = true
          timer = setTimeout(function () { timer = null; flush(false) }, 3000)
        }
      }
      xhr.send(JSON.stringify(DATA))
    } catch (e3) { dirty = true; fails++ }
  }

  // 首次启用（模块级存储文件尚不存在）时，把当前环境已有的面板偏好迁移上去，
  // 避免老用户升级后设置被清空。setup/* 属于后端地址，跳过。
  if (CFG.fresh) {
    try {
      var migrated = false
      for (var i = 0; i < NATIVE.length; i++) {
        var nk = NATIVE.key(i)
        if (nk != null && !isLocal(nk) && !has(DATA, nk)) {
          DATA[nk] = String(NATIVE.getItem(nk))
          migrated = true
        }
      }
      if (migrated) markDirty()
    } catch (e4) { }
  }

  // 页面可能被 Service Worker 缓存成旧版本（内联快照过期），启动后异步校准一次：
  // 跳过本次会话刚写过的键的校准窗口很短，简单起见直接以远端为准覆盖未改动项。
  try {
    var rx = new XMLHttpRequest()
    var requestGeneration = changeGeneration
    rx.open('GET', CFG.url, true)
    if (AUTH) rx.setRequestHeader('Authorization', AUTH)
    rx.onload = function () {
      if (rx.status !== 200) return
      var obj = null
      try { obj = JSON.parse(rx.responseText) } catch (e5) { return }
      var d = obj && obj.data
      if (!d) return
      for (var k2 in d) {
        if (has(d, k2) && !isLocal(k2) && !dirty && changeGeneration === requestGeneration && DATA[k2] !== String(d[k2])) {
          DATA[k2] = String(d[k2])
        }
      }
    }
    rx.send()
  } catch (e6) { }

  // ---------- 代理 store ----------
  var store = {
    getItem: function (k) {
      k = String(k)
      return isLocal(k) ? NATIVE.getItem(k) : (has(DATA, k) ? DATA[k] : null)
    },
    setItem: function (k, v) {
      k = String(k)
      if (isLocal(k)) return NATIVE.setItem(k, String(v))
      DATA[k] = String(v)
      markDirty()
    },
    removeItem: function (k) {
      k = String(k)
      if (isLocal(k)) return NATIVE.removeItem(k)
      delete DATA[k]
      markDirty()
    },
    // 清空只重置共享的面板偏好；后端地址保留，否则面板会立刻连不上后端
    clear: function () {
      var ks = keys()
      for (var i = 0; i < ks.length; i++) delete DATA[ks[i]]
      markDirty()
    },
    key: function (i) {
      if (typeof i !== 'number') i = parseInt(i, 10)
      // 本地键在前，共享键在后
      var nl = 0
      try { nl = NATIVE.length } catch (e7) { }
      if (i < nl) return NATIVE.key(i)
      var ks = keys()
      return i - nl < ks.length ? ks[i - nl] : null
    },
    get length() {
      var nl = 0
      try { nl = NATIVE.length } catch (e8) { }
      return nl + keys().length
    }
  }

  try {
    Object.defineProperty(window, 'localStorage', { value: store, configurable: true })
  } catch (e9) { }
  // WebView 上若 defineProperty 失败（localStorage 不可重定义），
  // 桥接自动失效并退回原生行为，不会影响面板正常工作。

  function saveNow() { if (dirty) flush(true) }
  window.addEventListener('pagehide', saveNow)
  window.addEventListener('beforeunload', saveNow)
  try {
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden') saveNow()
    })
  } catch (e10) { }
})()
