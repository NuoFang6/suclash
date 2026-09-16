package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// 杂项子命令：config 导入、自启开关、日志查看、模式切换、panic 清除。

// cmdConfig 导入配置文件：YAML 校验 → 原子替换 config.yaml → 重启核心。
func cmdConfig(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("用法: config <配置文件路径>")
	}
	src := args[0]
	cfg, err := loadYAML(src)
	if err != nil {
		return fmt.Errorf("配置文件无效: %w", err)
	}
	if len(cfg) == 0 {
		return fmt.Errorf("配置文件为空")
	}
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	tmp := userCfg + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return fmt.Errorf("写入失败: %w", err)
	}
	if err := os.Rename(tmp, userCfg); err != nil {
		return err
	}
	appendModuleLog("config imported: %s", src)
	fmt.Println("imported, restarting core")
	return cmdRestart(nil)
}

func cmdEnable(args []string) error {
	// 对齐原 shell 语义：清除熔断/崩溃标记后开启自启（不自动启动核心）
	_ = os.Remove(panicFl)
	_ = os.Remove(crashFl)
	_ = os.WriteFile(enabledFl, []byte("1"), 0o644)
	fmt.Println("autostart on")
	return nil
}

func cmdDisable(args []string) error {
	_ = os.WriteFile(enabledFl, []byte("0"), 0o644)
	_ = cmdStop(nil)
	fmt.Println("autostart off, stopped")
	return nil
}

// cmdToggle 启停切换（原 clashctl toggle 语义：磁贴/通知依赖）。
// panic 态先清除熔断；运行中则停止并禁自启，已停则启用并启动。
func cmdToggle(args []string) error {
	if fileExists(panicFl) {
		_ = cmdStop(nil)
		_ = os.Remove(panicFl)
		_ = os.Remove(crashFl)
		appendModuleLog("panic cleared by toggle")
	}
	if corePID() > 0 {
		_ = cmdStop(nil)
		_ = os.WriteFile(enabledFl, []byte("0"), 0o644)
		fmt.Println("stopped")
		return nil
	}
	_ = os.WriteFile(enabledFl, []byte("1"), 0o644)
	return cmdStart(nil)
}

// cmdResume 清除熔断状态并重新启动（原 clashctl resume 语义）。
func cmdResume(args []string) error {
	_ = os.Remove(panicFl)
	_ = os.Remove(crashFl)
	_ = os.WriteFile(enabledFl, []byte("1"), 0o644)
	return cmdStart(nil)
}

func cmdLog(args []string) error {
	n := 50
	if len(args) >= 1 {
		if v, err := strconv.Atoi(args[0]); err == nil && v > 0 {
			n = v
		}
	}
	return tailFile(coreLog, n)
}

// cmdMlog 查看模块管理日志（原 clashctl mlog 语义）。
func cmdMlog(args []string) error {
	n := 50
	if len(args) >= 1 {
		if v, err := strconv.Atoi(args[0]); err == nil && v > 0 {
			n = v
		}
	}
	return tailFile(moduleLog, n)
}

// cmdSavelog 控制是否保存 mihomo 核心日志（默认不保存）。
//
//	savelog on    开启保存：后续核心的 stdout/stderr 落盘到 mihomo.log（缓存写）
//	savelog off   关闭保存：核心日志丢弃（/dev/null），不产生落盘
//	savelog       无参：打印当前状态
//
// 开关持久化在 state/save_log。切换即时生效需重启核心（日志目标是 spawn 时确定的）。
func cmdSavelog(args []string) error {
	arg := ""
	if len(args) >= 1 {
		arg = strings.ToLower(args[0])
	}
	switch arg {
	case "on", "1", "enable":
		return setSavelog(true)
	case "off", "0", "disable":
		return setSavelog(false)
	case "":
		if fileExists(saveLogFl) {
			fmt.Println("core log saving: on")
		} else {
			fmt.Println("core log saving: off (default)")
		}
		return nil
	default:
		return fmt.Errorf("用法: savelog [on|off]")
	}
}

// setSavelog 切换日志保存开关，并在核心运行时重启核心使新日志目标生效。
// 一致性保证：若核心重启失败，回滚开关到旧状态，避免"开关已改但日志目标
// 未变"的状态错位（savelog 与 watchdog restartCore 抢非阻塞锁时可能触发）。
func setSavelog(on bool) error {
	oldOn := fileExists(saveLogFl)
	if oldOn == on {
		fmt.Printf("core log saving: %s (already)\n", onOffStr(on))
		return nil
	}
	if on {
		_ = os.WriteFile(saveLogFl, []byte("1"), 0o644)
	} else {
		_ = os.Remove(saveLogFl)
	}
	appendModuleLog("core log saving: %s", onOffStr(on))
	if corePID() < 0 {
		fmt.Printf("core log saving: %s (core not running, applied on next start)\n", onOffStr(on))
		return nil
	}
	appendModuleLog("restarting core to apply log target")
	if err := cmdRestart(nil); err != nil {
		// 重启失败（多为与 watchdog 锁竞争）：回滚开关，保证状态一致
		if on {
			_ = os.Remove(saveLogFl)
		} else {
			_ = os.WriteFile(saveLogFl, []byte("1"), 0o644)
		}
		appendModuleLog("core restart failed, reverted log switch: %v", err)
		return fmt.Errorf("核心重启失败，日志开关已回滚: %w", err)
	}
	fmt.Printf("core log saving: %s\n", onOffStr(on))
	return nil
}

// onOffStr 布尔转 "on"/"off" 小写显示。
func onOffStr(on bool) string {
	if on {
		return "on"
	}
	return "off"
}

// cmdVersion 输出核心版本（原 clashctl version 语义：mihomo -v 首行）。
func cmdVersion(args []string) error {
	if out, err := exec.Command(mihomoBin, "-v").Output(); err == nil {
		for _, l := range strings.Split(string(out), "\n") {
			if l = strings.TrimSpace(l); l != "" {
				fmt.Println(l)
				return nil
			}
		}
	}
	fmt.Printf("suclash_helper v%s (%s/%s)\n", version, goos, goarch)
	return nil
}
