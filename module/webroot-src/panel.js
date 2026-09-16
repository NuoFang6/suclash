/* SU Clash 悬浮面板 - 由 mihomo 在 /ui/* 的 text/html 响应中服务端注入
 *  - 可拖拽气泡，点按展开全屏覆盖层（核心操作）
 *  - 启动/停止/重启 经 window.ksu.exec 调用模块 clashctl（KSU 管理器 WebUI 或配套 App 内可用；
 *    普通浏览器自动降级为仅状态显示）
 *  - 启动/重启成功后自动刷新页面（zashboard 重连）；停止后覆盖层显示"核心未运行"
 *  - 首次访问自动导入后端（读取 window.__SUCLASH__ 注入的 API 地址与 secret）
 *  - 脚本内嵌于 mihomo 二进制（mihomo-patches/0005），官方「升级面板」清空目录后仍可用，
 *    无需任何文件级自愈
 */
; (function () {
  'use strict'
  var CFG = window.__SUCLASH__ || { api: { protocol: 'http', host: '127.0.0.1', port: '9090', secret: '' } }
  var A = CFG.api
  var hasRoot = typeof window.ksu !== 'undefined' && typeof window.ksu.exec === 'function'
  var CTL = '/data/adb/modules/suclash/scripts/clashctl'

  // ---------- 本机后端（唯一写入者） ----------
  // panel.js 是本机后端「唯一」的写入方：clashctl 的面板 URL 已不再携带
  // hostname/secret/label 等后端参数，zashboard 的 addBackend 不会被触发，
  // 因此不会产生重复后端。这里只做两件事：
  //   1. 列表为空 → 种入 suclash-local；已存在 → 校正其 label/secret/字段（幂等）
  //   2. 历史版本残留的重复条目，用一次性迁移标记清理一次，之后不再做去重
  var SEED_VER = '2'
  function seedBackend() {
    try {
      var host = A.host || '127.0.0.1'
      var port = String(A.port || '9090')
      function localBackend() {
        return {
          type: 'clash',
          protocol: A.protocol || 'http',
          host: host,
          port: port,
          secondaryPath: '',
          password: A.secret || '',
          uuid: 'suclash-local',
          label: 'SU Clash',
          disableUpgradeCore: false,
          disableTunMode: false,
        }
      }
      var list = JSON.parse(localStorage.getItem('setup/api-list') || '[]')
      if (!list.length) {
        localStorage.setItem('setup/api-list', JSON.stringify([localBackend()]))
        // active-uuid 在 zashboard 里是 useStorage 的 string 类型（默认 ''），
        // 走 raw 序列化器——绝不能 JSON.stringify，否则带引号后 find(uuid===...) 匹配不上
        localStorage.setItem('setup/active-uuid', 'suclash-local')
        localStorage.setItem('setup/suclash-seed-v', SEED_VER)
        return
      }

      var activeUuid = localStorage.getItem('setup/active-uuid') || ''
      var migrated = localStorage.getItem('setup/suclash-seed-v') === SEED_VER

      var kept = [], seenLocal = false, dirty = false, removedActive = false
      for (var i = 0; i < list.length; i++) {
        var it = list[i]
        if (it.uuid === 'suclash-local') {
          if (it.label !== 'SU Clash') { it.label = 'SU Clash'; dirty = true }
          if (it.password !== (A.secret || '')) { it.password = A.secret || ''; dirty = true }
          if (it.disableUpgradeCore === undefined) { it.disableUpgradeCore = false; dirty = true }
          if (it.disableTunMode === undefined) { it.disableTunMode = false; dirty = true }
          seenLocal = true
          kept.push(it)
        } else if (!migrated && it.host === host && String(it.port) === port) {
          // 一次性迁移：清掉历史版本产生的同 endpoint 重复条目
          if (activeUuid === it.uuid) removedActive = true
          dirty = true
        } else {
          kept.push(it)
        }
      }
      if (!seenLocal) {
        kept.push(localBackend())
        dirty = true
      }
      if (dirty) localStorage.setItem('setup/api-list', JSON.stringify(kept))
      if (removedActive) localStorage.setItem('setup/active-uuid', 'suclash-local')
      if (!migrated) localStorage.setItem('setup/suclash-seed-v', SEED_VER)
    } catch (e) { /* ignore */ }
  }
  seedBackend()

  // ---------- root 执行 ----------
  function rootExec(cmd) {
    if (!hasRoot) return Promise.reject(new Error('no root bridge'))
    return new Promise(function (resolve) {
      var out = ''
      try { out = window.ksu.exec(cmd) || '' } catch (e) { out = '' }
      resolve(out)
    })
  }

  // ---------- HTTP 状态探测（无 root 桥时的降级方案） ----------
  // window.__SUCLASH__.api 的 host/port 取自 location，天然指向当前面板可达地址；
  // 只要 mihomo 对外端口有 HTTP 响应（200/401/404 均算在线），即视为核心运行中。
  function httpProbe() {
    var base = (A.protocol || 'http') + '://' + (A.host || '127.0.0.1') + ':' + (A.port || '9090')
    return new Promise(function (resolve) {
      try {
        var xhr = new XMLHttpRequest()
        xhr.open('GET', base + '/version', true)
        xhr.timeout = 4000
        if (A.secret) { try { xhr.setRequestHeader('Authorization', 'Bearer ' + A.secret) } catch (e) { } }
        xhr.onreadystatechange = function () {
          if (xhr.readyState !== 4) return
          resolve(xhr.status > 0 ? 'on' : 'off')
        }
        xhr.send()
      } catch (e) { resolve('off') }
    })
  }

  function getState() {
    if (!hasRoot) return httpProbe()
    return rootExec(CTL + ' status').then(function (out) {
      var m = (out || '').match(/state=(\w+)/)
      return m ? m[1] : 'off'
    }).catch(function () {
      return httpProbe()
    })
  }
  function waitRunning(sec) {
    return getState().then(function (st) {
      if (st === 'on') return true
      if (sec <= 0) return false
      return new Promise(function (res) { setTimeout(function () { res(waitRunning(sec - 2)) }, 2000) })
    })
  }

  // ---------- UI ----------
  var css = document.createElement('style')
  css.textContent = [
    '#suc-bubble{position:fixed;z-index:2147483647;right:14px;bottom:96px;width:44px;height:44px;',
    'border-radius:50%;background:#1f2937;color:#fbbf24;display:flex;align-items:center;justify-content:center;',
    'font-size:19px;box-shadow:0 2px 10px rgba(0,0,0,.35);cursor:grab;user-select:none;touch-action:none;opacity:.85}',
    '#suc-bubble:active{cursor:grabbing;opacity:1}',
    '@media (prefers-color-scheme: light){#suc-card{background:#ffffff !important;color:#0f172a !important}',
    '#suc-card .suc-btn{background:#e2e8f0 !important;color:#0f172a !important}',
    '#suc-card .suc-btn.pri{background:#2563eb !important;color:#fff !important}',
    '#suc-card .suc-btn.warn{background:#b91c1c !important;color:#fff !important}}',
    '#suc-ov{position:fixed;inset:0;z-index:2147483646;background:rgba(0,0,0,.55);display:none;',
    'align-items:center;justify-content:center}',
    '#suc-ov.show{display:flex}',
    '#suc-card{width:270px;background:#1f2937;color:#e5e7eb;border-radius:18px;padding:20px;',
    'box-shadow:0 10px 40px rgba(0,0,0,.45);font-size:14px}',
    '.suc-title{font-weight:700;font-size:16px;display:flex;align-items:center;gap:8px}',
    '.suc-title .tag{font-size:11px;background:#334155;color:#cbd5e1;border-radius:99px;padding:2px 8px;font-weight:400}',
    '.suc-status{margin:12px 0 4px;font-size:13px;line-height:1.5;word-break:break-all}',
    '.suc-dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;background:#9ca3af;vertical-align:middle}',
    '.suc-dot.on{background:#22c55e}.suc-dot.panic{background:#ef4444}',
    '.suc-row{display:flex;gap:8px;margin-top:12px}',
    '.suc-btn{flex:1;padding:11px 0;border-radius:10px;border:none;font-size:13.5px;cursor:pointer;',
    'background:#334155;color:#e5e7eb;font-weight:600}',
    '.suc-btn.pri{background:#2563eb;color:#fff}',
    '.suc-btn.warn{background:#b91c1c;color:#fff}',
    '.suc-btn:active{filter:brightness(1.25)}',
    '.suc-hint{font-size:11.5px;opacity:.6;margin-top:10px;line-height:1.6}',
    '.suc-big{font-size:15px;font-weight:700;margin:8px 0 2px}',
    '.suc-log{display:none;margin-top:10px;background:rgba(0,0,0,.4);color:#cbd5e1;',
    'font:10.5px/1.5 ui-monospace,monospace;padding:8px;border-radius:8px;',
    'max-height:170px;overflow:auto;white-space:pre-wrap;word-break:break-all}',
    '@media (prefers-color-scheme: light){#suc-log{background:#f1f5f9;color:#334155}}',
  ].join('')
  document.head.appendChild(css)

  var bubble = document.createElement('div')
  bubble.id = 'suc-bubble'
  bubble.textContent = '⚡'
  var ov = document.createElement('div')
  ov.id = 'suc-ov'
  var card = document.createElement('div')
  card.id = 'suc-card'
  ov.appendChild(card)
  document.body.appendChild(bubble)
  document.body.appendChild(ov)

  function html() {
    return '<div class="suc-title">⚡ SU Clash <span class="tag">mihomo</span></div>' +
      '<div class="suc-status" id="suc-st">读取中…</div>' +
      '<div id="suc-ctl"></div>' +
      '<div class="suc-row">' +
      '<button class="suc-btn" data-a="mlog">模块日志</button>' +
      '<button class="suc-btn" data-a="logrefresh">刷新日志</button></div>' +
      '<div class="suc-row">' +
      '<button class="suc-btn" data-a="config">配置</button></div>' +
      '<pre id="suc-log" class="suc-log">（模块日志 /data/adb/suclash/module.log）</pre>' +
      '<div class="suc-hint">拖动气泡可移动位置；核心操作经 root 桥执行。</div>'
  }

  function loadLog() {
    var el = card.querySelector('#suc-log')
    if (!el || el.style.display === 'none') return
    if (!hasRoot) { el.textContent = '（无 root 桥，无法读取日志）'; return }
    rootExec('tail -n 40 /data/adb/suclash/module.log 2>/dev/null').then(function (out) {
      el.textContent = (out && out.trim()) ? out.trim() : '（暂无日志）'
      el.scrollTop = el.scrollHeight
    }).catch(function () {
      el.textContent = '（读取日志失败）'
    })
  }

  // 视图：running=控制按钮; stopped=核心未运行提示
  function renderRunning(st) {
    var stEl = card.querySelector('#suc-st')
    var ctl = card.querySelector('#suc-ctl')
    var dot = st === 'on' ? 'on' : (st === 'panic' ? 'panic' : '')
    var label = { on: '核心运行中', off: '核心未运行', starting: '启动中…', stopping: '停止中…', panic: '已熔断（反复异常）', unknown: '状态未知' }[st] || st
    stEl.innerHTML = '<span class="suc-dot ' + dot + '"></span>' + label +
      '<div style="opacity:.45;font-size:10px;margin-top:3px">[diag] ksu=' + typeof window.ksu + ' exec=' + (window.ksu ? typeof window.ksu.exec : 'n/a') + ' hasRoot=' + hasRoot + '</div>'
    if (!hasRoot) {
      ctl.innerHTML = '<div class="suc-hint">当前环境无 root 桥，仅显示状态。核心管理请使用 SU Clash App。</div>'
      return
    }
    if (st === 'on') {
      ctl.innerHTML = '<div class="suc-row">' +
        '<button class="suc-btn" data-a="restart">重启核心</button>' +
        '<button class="suc-btn warn" data-a="stop">停止</button></div>'
    } else if (st === 'panic') {
      ctl.innerHTML = '<div class="suc-row"><button class="suc-btn pri" data-a="resume">恢复并启动</button></div>'
    } else {
      ctl.innerHTML = '<div class="suc-row"><button class="suc-btn pri" data-a="start">启动核心</button></div>'
    }
  }

  function renderBusy(text) {
    card.querySelector('#suc-st').innerHTML = '<span class="suc-dot"></span>' + text
    card.querySelector('#suc-ctl').innerHTML = ''
  }

  function renderStopped() {
    var stEl = card.querySelector('#suc-st')
    var ctl = card.querySelector('#suc-ctl')
    stEl.innerHTML = '<span class="suc-dot"></span>核心未运行'
    ctl.innerHTML = '<div class="suc-big">zashboard 面板不可用</div>' +
      '<div class="suc-hint">核心停止后页面将无法连接后端。可点击下方按钮重新启动，完成后自动刷新。</div>' +
      '<div class="suc-row">' +
      (hasRoot ? '<button class="suc-btn pri" data-a="start">启动核心</button>' : '') +
      '<button class="suc-btn" data-a="close">关闭</button></div>'
  }

  function refresh() {
    getState().then(function (st) {
      if (st === 'off') renderStopped()
      else renderRunning(st)
    }).catch(function () {
      renderRunning('unknown')
    })
  }

  // 轻量提示：无 root 桥时点击核心操作按钮给出可见反馈，而非静默无响应
  function toast(msg) {
    try {
      var t = document.createElement('div')
      t.textContent = msg
      t.style.cssText = 'position:fixed;left:50%;bottom:22%;transform:translateX(-50%);' +
        'z-index:2147483647;background:rgba(0,0,0,.82);color:#fff;padding:9px 16px;' +
        'border-radius:10px;font-size:13px;max-width:82vw;text-align:center;'
      document.body.appendChild(t)
      setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t) }, 2200)
    } catch (e) { }
  }

  // 静态按钮（模块日志/刷新日志/配置）依赖 root 桥，无桥时置灰禁用
  function syncRootButtons() {
    var btns = card.querySelectorAll('.suc-btn[data-a="mlog"],.suc-btn[data-a="logrefresh"],.suc-btn[data-a="config"]')
    for (var i = 0; i < btns.length; i++) {
      btns[i].disabled = !hasRoot
      btns[i].style.opacity = hasRoot ? '' : '.45'
    }
  }

  function act(a) {
    if (a === 'close') { ov.classList.remove('show'); return }
    if (!hasRoot) { toast('当前环境无 root 桥，请使用 SU Clash App 操作'); return }
    if (a === 'mlog') {
      var el = card.querySelector('#suc-log')
      el.style.display = el.style.display === 'block' ? 'none' : 'block'
      loadLog()
      return
    }
    if (a === 'logrefresh') { loadLog(); return }
    if (a === 'config') { try { window.ksu.openConfig() } catch (e) { } return }
    if (a === 'stop') {
      renderBusy('停止中…')
      rootExec(CTL + ' stop').then(function () { setTimeout(refresh, 500) })
      return
    }
    // start / resume / restart：完成后刷新 zash 面板
    var cmd = a === 'resume' ? 'resume' : a
    renderBusy(cmd === 'restart' ? '重启中…' : '启动中…')
    rootExec(CTL + ' ' + cmd).then(function () {
      waitRunning(35).then(function (ok) {
        if (ok) {
          renderBusy('已启动，正在刷新面板…')
          setTimeout(function () { location.reload() }, 600)
        } else {
          refresh()
        }
      })
    })
  }

  bubble.addEventListener('click', function (e) {
    if (dragged) return
    if (!card.innerHTML) card.innerHTML = html()
    syncRootButtons()
    ov.classList.add('show')
    refresh()
    setTimeout(loadLog, 500)
  })
  ov.addEventListener('click', function (e) {
    if (e.target === ov) { ov.classList.remove('show'); return }
    var t = e.target
    if (t.dataset && t.dataset.a) act(t.dataset.a)
  })

  // ---------- 拖拽（保存位置） ----------
  var dragged = false
  var sx = 0, sy = 0, ox = 0, oy = 0, moved = false
  bubble.addEventListener('pointerdown', function (e) {
    sx = e.clientX; sy = e.clientY
    var r = bubble.getBoundingClientRect()
    ox = r.left; oy = r.top
    moved = false
    bubble.setPointerCapture(e.pointerId)
  })
  bubble.addEventListener('pointermove', function (e) {
    if (e.buttons === 0 && e.pointerType === 'mouse') return
    var dx = e.clientX - sx, dy = e.clientY - sy
    if (Math.abs(dx) + Math.abs(dy) > 6) { moved = true; dragged = true }
    if (moved) {
      var w = window.innerWidth, h = window.innerHeight
      var x = Math.min(Math.max(0, ox + dx), w - 46)
      var y = Math.min(Math.max(0, oy + dy), h - 46)
      bubble.style.right = 'auto'
      bubble.style.bottom = 'auto'
      bubble.style.left = x + 'px'
      bubble.style.top = y + 'px'
    }
  })
  bubble.addEventListener('pointerup', function () {
    if (moved) {
      try { localStorage.setItem('suc-panel-pos', bubble.style.left + '|' + bubble.style.top) } catch (e) { }
      setTimeout(function () { dragged = false }, 50)
    }
  })
  try {
    var pos = (localStorage.getItem('suc-panel-pos') || '').split('|')
    if (pos.length === 2 && pos[0]) {
      bubble.style.right = 'auto'; bubble.style.bottom = 'auto'
      bubble.style.left = pos[0]; bubble.style.top = pos[1]
    }
  } catch (e) { }
})()
