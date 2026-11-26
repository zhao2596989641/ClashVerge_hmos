package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"
)

// 本文件是**独立内核进程**的入口（HarmonyOS native child process）。
//
// 为什么需要它（真机 2026-11-15）：
//   把 Go 内核 dlopen 进 UI 进程时，Go runtime 初始化会在 `newm(sysmon)` 里卡住
//   （调试器栈：`newm1 → _cgo_thread_start → pthread_sigmask`），并且**把整个进程一起拖停**，
//   界面停在开屏/加载页。两套能跑的参考实现（ClashBox / ClashOhos）里，内核都**不与 CEF 同进程**：
//   ClashBox 的 UI 是纯 ArkUI（没有 ArkWeb）；ClashOhos 把内核放在 VpnExtension 进程。
//   所以这里改成：内核跑在 `childProcessManager.startNativeChildProcess` 拉起的独立进程里，
//   UI 通过 127.0.0.1:9090 的 REST/WS 控制它（前端零改动），tunfd 用 SCM_RIGHTS 直接递进来。
//
// 契约（ArkTS 侧 `CoreHost.bootEarly()` 负责组装）：
//   入口符号 `ClashCoreChildMain`（C 侧定义，先等 clash_core_ready 再调这里）
//   entryParams = JSON:
//     {
//       "home":    "<files>/verge/core",
//       "config":  "<files>/verge/clash-verge.yaml",
//       "control": "<files>/verge/runtime",
//       "version": "v1.19.34",
//       "sdk":     26
//     }
//
//   control 目录下的文件（都由 ArkTS 写，seq 变化才生效）：
//     reload.json {"seq":N,"path":"..."}                       ← 换订阅/改配置
//     tun.json    {"seq":N,"on":true,"socket":"...","stack":"mips",
//                  "gateway":"...","portal":"...","dns":"..."}  ← 开/关 TUN
//   本进程写：
//     status.json {"pid","phase","ready","tun","error","updatedAt"}
//
// ⚠️ 入口函数**永不返回**：返回后系统会立刻销毁子进程。

type childParams struct {
	Home    string `json:"home"`
	Config  string `json:"config"`
	Control string `json:"control"`
	Version string `json:"version"`
	SDK     int    `json:"sdk"`
}

type childReload struct {
	Seq  int64  `json:"seq"`
	Path string `json:"path"`
}

type childTun struct {
	Seq     int64  `json:"seq"`
	On      bool   `json:"on"`
	Socket  string `json:"socket"`
	Stack   string `json:"stack"`
	Gateway string `json:"gateway"`
	Portal  string `json:"portal"`
	DNS     string `json:"dns"`
}

var (
	childStatusPath string
	childReady      bool
	childTunOn      bool
	childErr        string
	childPhase      string
	childConfig     string
	// 收到的 tunfd **不关**：reload（切订阅/改配置）会把内核里的 tun 段关掉，
	// 需要用同一个 fd 再 start_tun 一次；关了就只能重新拉扩展要 fd。
	childTunFd      int = -1
	childTunOpts    childTun
)

func childWriteStatus() {
	if childStatusPath == "" {
		return
	}
	st := map[string]interface{}{
		"pid":       os.Getpid(),
		"phase":     childPhase,
		"ready":     childReady,
		"tun":       childTunOn,
		"error":     childErr,
		"config":    childConfig,
		"updatedAt": time.Now().UnixMilli(),
	}
	body, err := json.Marshal(st)
	if err != nil {
		return
	}
	// 先写临时文件再 rename：ArkTS 侧可能正好在读，避免读到半个 JSON
	tmp := childStatusPath + ".tmp"
	if err := os.WriteFile(tmp, body, 0o644); err == nil {
		_ = os.Rename(tmp, childStatusPath)
	}
}

// recvFd 用 SCM_RIGHTS 从 unix socket 收一个文件描述符（等价于 C 侧的 relayReceive）。
//
// 为什么不用 C 版的 fd_relay：子进程只加载 libclash_core.so（纯 Go + 一个 C 垫片），
// 把 fd_relay.cpp 也链进来会多一份 hilog 依赖；Go 这边 syscall 直接做更干净。
func recvFd(sockPath string, timeoutMs int) (int, error) {
	sock, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		return -1, err
	}
	deadline := time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)
	connected := false
	for {
		err = syscall.Connect(sock, &syscall.SockaddrUnix{Name: sockPath})
		if err == nil {
			connected = true
			break
		}
		if time.Now().After(deadline) {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if !connected {
		_ = syscall.Close(sock)
		return -1, err
	}
	buf := make([]byte, 4)
	oob := make([]byte, syscall.CmsgSpace(4))
	_, oobn, _, _, err := syscall.Recvmsg(sock, buf, oob, 0)
	_ = syscall.Close(sock)
	if err != nil {
		return -1, err
	}
	msgs, err := syscall.ParseSocketControlMessage(oob[:oobn])
	if err != nil || len(msgs) == 0 {
		return -1, err
	}
	fds, err := syscall.ParseUnixRights(&msgs[0])
	if err != nil || len(fds) == 0 {
		return -1, err
	}
	return fds[0], nil
}

func childApplyReload(path string) {
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	msg := C.GoString(clash_core_load(cp))
	if msg != "" {
		childErr = msg
		childPhase = "load-failed"
		return
	}
	childErr = ""
	childConfig = path
	childPhase = "loaded"
	// load 会重建 hub（tun 段被 prepareBase 关掉）。如果刚才 TUN 是开着的，
	// 用同一个 fd 重新挂回去，用户切订阅时不会掉线。
	if childTunOn && childTunFd >= 0 {
		rc := childStartTun(childTunFd, childTunOpts)
		if rc != 0 {
			childErr = "re-apply tun rc=" + itoa(rc)
			childPhase = "tun-start-failed"
			childTunOn = false
			return
		}
		childPhase = "tun-on"
	}
}

// childStartTun 把 tunfd 塞进内核（内部会 dup 一份，所以可以重复调用同一个 fd）
func childStartTun(fd int, t childTun) int {
	cStack := C.CString(t.Stack)
	cGw := C.CString(t.Gateway)
	cPortal := C.CString(t.Portal)
	cDNS := C.CString(t.DNS)
	rc := clash_core_start_tun(C.int(fd), cStack, cGw, cPortal, cDNS)
	C.free(unsafe.Pointer(cStack))
	C.free(unsafe.Pointer(cGw))
	C.free(unsafe.Pointer(cPortal))
	C.free(unsafe.Pointer(cDNS))
	return int(rc)
}

func childApplyTun(t childTun) {
	if !t.On {
		clash_core_stop_tun()
		// 显式关闭时把 relay 收到的 fd 也关掉（sing-tun 只关它自己的 dup）；
		// reload 期间的重挂不经过这里，不会误关。
		if childTunFd >= 0 {
			_ = syscall.Close(childTunFd)
			childTunFd = -1
		}
		childTunOn = false
		childPhase = "tun-off"
		return
	}
	fd, err := recvFd(t.Socket, 10000)
	if err != nil {
		childErr = "recv tunfd: " + err.Error()
		childTunOn = false
		childPhase = "tun-fd-failed"
		return
	}
	childTunOpts = t
	rc := childStartTun(fd, t)
	if rc == 0 {
		// fd 留着：reload 后还要用它重新挂 tun
		childTunFd = fd
	} else {
		_ = syscall.Close(fd)
	}
	if rc != 0 {
		childErr = "start_tun rc=" + itoa(int(rc))
		childTunOn = false
		childPhase = "tun-start-failed"
		return
	}
	childErr = ""
	childTunOn = true
	childPhase = "tun-on"
}

func itoa(v int) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var b [20]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

//export clash_core_child_main
func clash_core_child_main(params *C.char) C.int {
	var p childParams
	if err := json.Unmarshal([]byte(C.GoString(params)), &p); err != nil || p.Home == "" {
		return 1
	}
	if p.Control == "" {
		p.Control = filepath.Join(filepath.Dir(p.Home), "runtime")
	}
	_ = os.MkdirAll(p.Control, 0o755)
	childStatusPath = filepath.Join(p.Control, "status.json")
	childConfig = p.Config
	childPhase = "init"
	childWriteStatus()

	// 复用与 C ABI 完全相同的初始化路径（它会先重定向 stdio，再 SetHomeDir/config.Init）
	cHome := C.CString(p.Home)
	cVer := C.CString(p.Version)
	cGit := C.CString("")
	clash_core_init(cHome, cVer, cGit, C.int(p.SDK))
	C.free(unsafe.Pointer(cHome))
	C.free(unsafe.Pointer(cVer))
	C.free(unsafe.Pointer(cGit))

	childPhase = "inited"
	childWriteStatus()

	if p.Config != "" {
		childApplyReload(p.Config)
		childWriteStatus()
	}
	childReady = true
	childPhase = "ready"
	childWriteStatus()

	var lastReload int64 = -1
	var lastTun int64 = -1
	reloadPath := filepath.Join(p.Control, "reload.json")
	tunPath := filepath.Join(p.Control, "tun.json")
	for {
		if b, err := os.ReadFile(reloadPath); err == nil {
			var r childReload
			if json.Unmarshal(b, &r) == nil && r.Seq != lastReload && r.Path != "" {
				lastReload = r.Seq
				childApplyReload(r.Path)
				childWriteStatus()
			}
		}
		if b, err := os.ReadFile(tunPath); err == nil {
			var t childTun
			if json.Unmarshal(b, &t) == nil && t.Seq != lastTun {
				lastTun = t.Seq
				childApplyTun(t)
				childWriteStatus()
			}
		}
		childWriteStatus() // 心跳：ArkTS 用它判断内核还活着
		time.Sleep(500 * time.Millisecond)
	}
}
