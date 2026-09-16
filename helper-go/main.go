// Package main - suclash_helper
//
// SU Clash 模块的统一管理二进制：接管原 shell 脚本的全部数据处理与
// 进程管理职责（runtime 配置生成、mihomo 进程管理、看门狗、Clash API
// 访问），shell 仅保留 KernelSU/Magisk 生命周期胶水。
//
// 背景：busybox awk（root 管理器附带，版本不可控）的 sub/gsub 在匹配
// 范围含多字节 UTF-8 字符时会段错误；nc 手写 HTTP、sed 抠 JSON 同样
// 脆弱。全部收编为单一 Go 二进制。
package main

import (
	"fmt"
	"os"
	"strings"
	_ "time/tzdata" // 内嵌 tzdb：Android 无 /usr/share/zoneinfo，TZ 指针才有库可查
)

const (
	version = "1.0.0"
)

// init 设置本地时区：Android 无 /etc/localtime，Go 拿不到 TZ 时默认 UTC，
// module.log/panic 等时间戳会与设备本地时间差数小时（取证误导源）。
// 从 persist.sys.timezone 读 IANA 名设置 TZ；time.Local 惰性初始化，
// 在首次时间格式化前生效。
func init() {
	if os.Getenv("TZ") != "" {
		return
	}
	out, err := runCmd("getprop", "persist.sys.timezone")
	if err != nil {
		return
	}
	if tz := strings.TrimSpace(out); tz != "" {
		_ = os.Setenv("TZ", tz)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `SU Clash helper v`+version+`

用法: suclash_helper <命令> [参数]

核心控制:
  start              启动核心(含 patch、校验、就绪等待、看门狗)
  stop               停止核心与看门狗
  restart            重启核心
  status             核心运行状态
  mode <m>           切换模式 direct|rule|global
  toggle             启停切换(运行中停止并禁自启，已停则启用并启动)
  reload             热重载配置(PUT /configs)
  resume             清除熔断状态并重新启动
  watchdog           看门狗前台循环(由 start 自动拉起, 不建议手动)

配置与 UI:
  patch              生成 runtime.yaml
  panel              输出 WebUI 面板地址
  reset-ui           从模块安装目录恢复被破坏的面板
  config <path>      导入配置文件(替换 config.yaml 并重启核心)

开关与信息:
  enable|disable     开机自启开关
  savelog [on|off]   核心日志保存开关(默认关闭, 开启后缓存写盘)
  log [n]            查看核心日志(默认 50 行)
  mlog [n]           查看模块管理日志(默认 50 行)
  version            版本信息
`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]

	var err error
	switch cmd {
	case "start":
		err = cmdStart(args)
	case "stop":
		err = cmdStop(args)
	case "restart":
		err = cmdRestart(args)
	case "status":
		err = cmdStatus(args)
	case "mode":
		err = cmdMode(args)
	case "toggle":
		err = cmdToggle(args)
	case "reload":
		err = cmdReload(args)
	case "resume":
		err = cmdResume(args)
	case "watchdog":
		err = cmdWatchdog(args)
	case "patch":
		err = cmdPatch(args)
	case "panel":
		err = cmdPanel(args)
	case "reset-ui":
		err = cmdResetUI(args)
	case "config":
		err = cmdConfig(args)
	case "enable":
		err = cmdEnable(args)
	case "disable":
		err = cmdDisable(args)
	case "savelog":
		err = cmdSavelog(args)
	case "log":
		err = cmdLog(args)
	case "mlog":
		err = cmdMlog(args)
	case "version":
		err = cmdVersion(args)
	default:
		fmt.Fprintf(os.Stderr, "未知命令: %s\n\n", cmd)
		usage()
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}
}
