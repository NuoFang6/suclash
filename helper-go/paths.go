package main

import (
	"runtime"
)

// 路径与常量（与模块布局一一对应，勿改名——APK/脚本依赖这些路径）
const (
	modDir   = "/data/adb/modules/suclash"
	dataDir  = "/data/adb/suclash"
	binDir   = modDir + "/bin"
	scrDir   = modDir + "/scripts"
	modUIDir = modDir + "/ui"

	stateDir  = dataDir + "/state"
	logDir    = dataDir + "/logs"
	dataUIDir = dataDir + "/ui"

	userCfg     = dataDir + "/config.yaml"
	runtimeCfg  = dataDir + "/runtime.yaml"
	coreLog     = logDir + "/mihomo.log"
	moduleLog   = dataDir + "/module.log"
	logMaxBytes = 8 * 1024 * 1024

	pidFile     = stateDir + "/mihomo.pid"
	wdPidFile   = stateDir + "/watchdog.pid"
	enabledFl   = stateDir + "/enabled"
	stoppingFl  = stateDir + "/stopping"
	tileFl      = stateDir + "/tile"
	panicFl     = stateDir + "/panic"
	crashFl     = stateDir + "/crashes" // "<count> <first_ts>"
	probeFailFl = stateDir + "/probe_fail"
	saveLogFl   = stateDir + "/save_log" // 存在=保存 mihomo 日志；默认不保存
	hangdumpFl  = dataDir + "/hangdump.log"

	mihomoBin  = binDir + "/mihomo"
	helperBin  = binDir + "/suclash_helper"
	defaultCfg = modDir + "/config.default.yaml"

	apiAddr = "127.0.0.1:9090"

	startWaitSec   = 15  // 等待 API 就绪上限
	termWaitSec    = 5   // SIGTERM 后等待退出上限
	wdIntervalSec  = 30  // 看门狗健康探测周期，降低常驻唤醒和 HTTP 开销
	maxCrash       = 3   // 熔断阈值
	crashWindowSec = 600 // 崩溃统计窗口
)

var (
	goos   = runtime.GOOS
	goarch = runtime.GOARCH
)
