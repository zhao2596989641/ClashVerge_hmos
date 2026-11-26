// Package main 是 mihomo 内核的 C ABI 薄壳（供 HarmonyOS 的 NAPI 模块 dlopen）。
//
// 符号名与 entry/src/main/cpp/clash_adapter.cpp 里的 dlsym 严格对齐，不要单方面改名。
//
// 设计要点（见 docs/HANDOFF.md）：
//   - mihomo 原生支持 `tun.file-descriptor`（F12），所以这里不需要自己创建 TUN，
//     也不必碰 gVisor/fdbased；系统给的 tunfd 直接写进配置即可。
//   - **YAML 合并在这一层做**：ArkTS 只写「订阅原文 + runtime-overrides.json」，
//     由这里统一合并，避免文本拼接导致 YAML 重复键（yaml.v3 会直接报错）。
//   - 所有函数都是同步阻塞的，调用方（ArkTS/VpnExtension）必须放在非 UI 线程执行。
//   - 出站 socket 的防回环不在这里做：mihomo v1.19.34 没有逐 socket protect 的钩子，
//     改用 VpnConnection.protectProcessNet() 整进程保护（见 HANDOFF §4.6）。
package main

/*
#include <stdlib.h>

// 由 clash_core_marker.c 定义，C 侧直接读这个变量判断 Go 初始化是否完成，
// **不需要进入 Go**（这正是关键：初始化没完成时任何 cgo 调用都可能卡死）
extern volatile int clash_core_ready;
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"

	yaml "go.yaml.in/yaml/v3"

	"github.com/metacubex/mihomo/config"
	Cc "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

const overridesName = "runtime-overrides.json"

var (
	mu             sync.Mutex
	loaded         bool
	homeDir        string
	version        string
	gitHash        string
	sdkLevel       int
	tunFd          int
	lastConfigPath string
)

func cstr(s string) *C.char { return C.CString(s) }

// init 在整个包（以及它 import 的全部 mihomo 依赖）的 init 都跑完之后执行。
//
// 我们把「我初始化好了」写进 C 侧的 clash_core_ready：
//   - 真机实测（2026-11-15）：dlopen 会在**另一个线程**上启动 Go runtime 并跑 doInit，
//     而 dlopen 立刻返回；此时从 ArkTS 线程调进来会撞在初始化中间，表现为整个进程卡死、
//     连一句日志都出不来。
//   - 所以 C 侧必须**先等这个标志**再调任何 Go 函数。
//
// ⚠️ 这里不要写 stderr/日志：那一刻 fd 2 还是应用原本的管道，写它有可能直接阻塞。
func init() {
	C.clash_core_ready = 1
}

var stdioOnce sync.Once
var stdioPath string

// redirectStdio 把 fd 1/2 接到 `<home>/logs/core.log`。
//
// 为什么必须做（真机实测，2026-11-14）：
//   应用里 fd 2 往往是一个**没人读的管道**。mihomo 的日志/Go 的 fatal error 全都写 fd 2，
//   一旦管道写满，write(2) 会**永久阻塞**，整个调用卡死 —— 表现就是「点了没反应 / 界面卡住」，
//   而且 hilog 里什么都看不到（Go 直接写 fd，不经过 hilog）。
//   重定向到文件之后：既能避免阻塞，又能把 Go 的 panic/fatal traceback 留下来。
func redirectStdio(home string) {
	stdioOnce.Do(func() {
		if home == "" {
			return
		}
		dir := filepath.Join(home, "logs")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return
		}
		p := filepath.Join(dir, "core.log")
		f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return
		}
		fd := int(f.Fd())
		if err := syscall.Dup3(fd, 1, 0); err != nil {
			f.Close()
			return
		}
		_ = syscall.Dup3(fd, 2, 0)
		stdioPath = p
		f.Close()
	})
}

// mark 往 core.log 写一行（不依赖任何外部状态，用于定位"卡在哪一步"）
func mark(format string, args ...interface{}) {
	fmt.Fprintf(os.Stdout, format+"\n", args...)
}

// clash_core_init 初始化运行环境（不启动代理）
//
//	void clash_core_init(const char* home, const char* version, const char* git, int sdk)
//
//export clash_core_init
func clash_core_init(home *C.char, ver *C.char, git *C.char, sdk C.int) {
	// 第一件事：抢在"任何可能写 fd2 的代码"之前重定向，否则一旦阻塞就再也回不来
	redirectStdio(C.GoString(home))
	mark("[bridge] === enter init (pid=%d) ===", os.Getpid())

	mu.Lock()
	defer mu.Unlock()

	homeDir = C.GoString(home)
	version = C.GoString(ver)
	gitHash = C.GoString(git)
	sdkLevel = int(sdk)
	mark("[bridge] step1 args home=%s ver=%s sdk=%d", homeDir, version, sdkLevel)

	Cc.SetHomeDir(homeDir)
	mark("[bridge] step2 SetHomeDir ok")
	Cc.SetConfig(Cc.Path.Resolve("config.yaml"))
	mark("[bridge] step3 SetConfig ok")
	if err := config.Init(Cc.Path.HomeDir()); err != nil {
		mark("[bridge] step4 config.Init FAILED: %s", err.Error())
		log.Errorln("[bridge] config.Init failed: %s", err.Error())
	} else {
		mark("[bridge] step4 config.Init ok")
	}
	log.Infoln("[bridge] init home=%s ver=%s git=%s sdk=%d", homeDir, version, gitHash, sdkLevel)
	mark("[bridge] === init done ===")
}

// clash_core_load 读取配置并启动内核（不含 TUN，TUN 由 start_tun 注入）
//
//	const char* clash_core_load(const char* path)   // 返回空串=成功
//
//export clash_core_load
func clash_core_load(path *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()

	cfgPath := C.GoString(path)
	if cfgPath == "" {
		cfgPath = Cc.Path.Config()
	}
	lastConfigPath = cfgPath
	raw, err := prepareBase(cfgPath)
	if err != nil {
		return cstr(err.Error())
	}
	if err := startLocked(raw); err != nil {
		return cstr(err.Error())
	}
	log.Infoln("[bridge] loaded %s", cfgPath)
	return cstr("")
}

// prepareBase 读订阅原文 → 应用 overrides → dns 兜底 → 关掉 tun.enable
func prepareBase(cfgPath string) ([]byte, error) {
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	root, err := parseYaml(raw)
	if err != nil {
		return nil, err
	}
	applyOverrides(root, loadOverrides(cfgPath))
	applyDnsFile(root, cfgPath)
	applyProxyChain(root, cfgPath)
	ensureDNS(root)
	// 启动阶段先禁用 tun：fd 还没拿到，此时让 sing-tun 自建设备在沙箱里必然失败。
	root["tun"] = tunSection(root, false)
	return yaml.Marshal(root)
}

func parseYaml(raw []byte) (map[string]interface{}, error) {
	var root map[string]interface{}
	if err := yaml.Unmarshal(raw, &root); err != nil {
		return nil, fmt.Errorf("yaml parse: %w", err)
	}
	if root == nil {
		root = map[string]interface{}{}
	}
	return root, nil
}

// proxyChainName 链式代理的配置文件名：{"chain": ["入口", "中转", "出口"]}
const proxyChainName = "proxy-chain.json"

// applyProxyChain 把 ArkTS 侧记录的链路落到 proxies 的 dialer-proxy 上。
// 语义对齐上游 config/runtime.rs:update_proxy_chain_config：
//   1) 先清空所有 proxy 的 dialer-proxy
//   2) chain[i] 的 dialer-proxy = chain[i-1]（chain[0] 是入口，末位是出口）
func applyProxyChain(root map[string]interface{}, cfgPath string) {
	path := filepath.Join(filepath.Dir(cfgPath), proxyChainName)
	raw, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var payload struct {
		Chain []string `json:"chain"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		log.Warnln("[bridge] bad %s", path)
		return
	}
	proxies, ok := root["proxies"].([]interface{})
	if !ok || len(proxies) == 0 {
		return
	}
	for _, proxy := range proxies {
		if m, ok := proxy.(map[string]interface{}); ok {
			delete(m, "dialer-proxy")
		}
	}
	if len(payload.Chain) < 2 {
		return
	}
	for i := 1; i < len(payload.Chain); i++ {
		for _, proxy := range proxies {
			m, ok := proxy.(map[string]interface{})
			if !ok {
				continue
			}
			if fmt.Sprint(m["name"]) == payload.Chain[i] {
				m["dialer-proxy"] = payload.Chain[i-1]
				break
			}
		}
	}
}

// loadOverrides 读同目录下的 runtime-overrides.json（ArkTS 侧写的强制字段）
func loadOverrides(cfgPath string) map[string]interface{} {
	path := filepath.Join(filepath.Dir(cfgPath), overridesName)
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var m map[string]interface{}
	if err := json.Unmarshal(raw, &m); err != nil {
		log.Warnln("[bridge] bad %s", path)
		return nil
	}
	return m
}

func applyOverrides(root map[string]interface{}, overrides map[string]interface{}) {
	for k, v := range overrides {
		root[k] = v
	}
}

// applyDnsFile 用户自定义 DNS 覆盖。
//
// 对应上游语义（`src-tauri/src/cmd/clash.rs`）：`dns_config.yaml` 存的是一个 **dns 段映射**，
// `apply_dns_config(true)` 才启用。ArkTS 没有 YAML 解析器，所以由这里解析并整体替换 dns 段。
//
//	verge/dns_active      存在 = 启用
//	verge/dns_config.yaml dns 段（enable / nameserver / fallback / nameserver-policy ...）
func applyDnsFile(root map[string]interface{}, cfgPath string) {
	dir := filepath.Dir(cfgPath)
	if _, err := os.Stat(filepath.Join(dir, "dns_active")); err != nil {
		return
	}
	raw, err := os.ReadFile(filepath.Join(dir, "dns_config.yaml"))
	if err != nil {
		log.Warnln("[bridge] dns_active set but dns_config.yaml unreadable: %s", err.Error())
		return
	}
	var dns map[string]interface{}
	if err := yaml.Unmarshal(raw, &dns); err != nil {
		log.Warnln("[bridge] dns_config.yaml parse failed: %s", err.Error())
		return
	}
	if len(dns) == 0 {
		return
	}
	root["dns"] = dns
	log.Infoln("[bridge] dns override applied (%d keys)", len(dns))
}

// ensureDNS 只在订阅没给 dns 配置时补一份 fake-ip 兜底；
// TUN 模式下没有可用 DNS 会导致所有域名解析失败（表现为「能连上但网页打不开」）。
func ensureDNS(root map[string]interface{}) {
	dns, ok := root["dns"].(map[string]interface{})
	if !ok || dns == nil {
		dns = map[string]interface{}{}
	}
	if _, has := dns["enable"]; !has {
		dns["enable"] = true
	}
	if _, has := dns["ipv6"]; !has {
		dns["ipv6"] = false
	}
	if _, has := dns["enhanced-mode"]; !has {
		dns["enhanced-mode"] = "fake-ip"
	}
	if _, has := dns["fake-ip-range"]; !has {
		dns["fake-ip-range"] = "198.18.0.1/16"
	}
	if _, has := dns["default-nameserver"]; !has {
		dns["default-nameserver"] = []interface{}{"223.5.5.5", "119.29.29.29"}
	}
	root["dns"] = dns
}

// tunSection 取/建 tun 段并设置 enable。
func tunSection(root map[string]interface{}, enable bool) map[string]interface{} {
	tun, ok := root["tun"].(map[string]interface{})
	if !ok || tun == nil {
		tun = map[string]interface{}{}
	}
	tun["enable"] = enable
	return tun
}

// mergeTun 把系统给的 tunfd 注入 tun 段
func mergeTun(root map[string]interface{}, fd int, stack, gateway, portal string) {
	tun := tunSection(root, fd > 0)
	tun["stack"] = stack
	tun["file-descriptor"] = fd
	// 系统已经把 tun 设备与路由配好了，必须关掉 mihomo 自己的路由/设备管理
	tun["auto-route"] = false
	tun["auto-detect-interface"] = false
	// ⚠️ MTU 必须与 VpnConfig.mtu 一致（Constants.TUN_MTU = 1400）。
	// 不写时 sing-tun 默认 9000：内核按 9000 协商 MSS/写包，而系统 tun 网卡只有 1400，
	// 大包写入直接失败 → TCP 能握手但 TLS/HTTP 数据全卡死（真机 2026-11-15 21:25 复现：
	// 连接建立了、api.deepseek.com 也 matched DIRECT，但页面永远加载不出来）。
	tun["mtu"] = 1400
	// ⚠️ 必须是 any:53：按目标地址精确匹配（例如只写 172.19.0.2）容易漏掉，
	// 导致系统发来的 DNS 查询不被劫持 → 域名解析全失败。
	tun["dns-hijack"] = []interface{}{"any:53"}
	if gateway != "" {
		tun["inet4-address"] = []interface{}{gateway}
	}
	if portal != "" {
		tun["loopback-address"] = []interface{}{portal}
	}
	root["tun"] = tun
}

func startLocked(raw []byte) error {
	controller := "127.0.0.1:9090"
	secret := ""
	if root, err := parseYaml(raw); err == nil {
		if v, ok := root["external-controller"].(string); ok && v != "" {
			controller = v
		}
		if v, ok := root["secret"].(string); ok {
			secret = v
		}
	}
	opts := []hub.Option{hub.WithExternalController(controller)}
	if secret != "" {
		opts = append(opts, hub.WithSecret(secret))
	}
	if err := hub.Parse(raw, opts...); err != nil {
		return fmt.Errorf("hub.Parse: %w", err)
	}
	loaded = true
	return nil
}

func currentConfigPath() string {
	if lastConfigPath != "" {
		return lastConfigPath
	}
	return Cc.Path.Config()
}

// clash_core_start_tun 把系统给的 tunfd 注入配置并重建内核
//
//	int clash_core_start_tun(int fd, const char* stack, const char* gateway,
//	                         const char* portal, const char* dns)   // 0=成功
//
//export clash_core_start_tun
func clash_core_start_tun(fd C.int, stack *C.char, gateway *C.char, portal *C.char, dns *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()

	raw, err := prepareBase(currentConfigPath())
	if err != nil {
		log.Errorln("[bridge] start_tun base failed: %s", err.Error())
		return -1
	}
	root, err := parseYaml(raw)
	if err != nil {
		log.Errorln("[bridge] start_tun parse failed: %s", err.Error())
		return -1
	}
	st := C.GoString(stack)
	if st == "" {
		st = "mips"
	}

	// ⚠️ 必须 dup 一份再交给 sing-tun：
	// sing-tun 的 `NativeTun.Close()` 会 `close(t.tunFile)`，而 t.tunFile 正是用
	// `options.FileDescriptor` 包出来的 os.File（tun_linux.go:72）。
	// 也就是说内核 shutdown / 重载时会**把系统给的那个 tunfd 关掉**。
	// 热重载要复用同一个 fd，不 dup 的话第二次 start_tun 必然失败（bad fd）。
	dupFd, dupErr := syscall.Dup(int(fd))
	if dupErr != nil {
		log.Errorln("[bridge] dup(fd=%d) failed: %s", int(fd), dupErr.Error())
		return -1
	}

	// dns 参数（VpnConfig.dnsAddresses 的地址）只影响系统往哪里发 DNS，
	// 内核侧统一 any:53 劫持，所以这里不用再传。
	mergeTun(root, dupFd, st, C.GoString(gateway), C.GoString(portal))
	merged, err := yaml.Marshal(root)
	if err != nil {
		log.Errorln("[bridge] start_tun marshal failed: %s", err.Error())
		_ = syscall.Close(dupFd)
		return -1
	}
	if err := startLocked(merged); err != nil {
		log.Errorln("[bridge] start_tun failed: %s", err.Error())
		_ = syscall.Close(dupFd)
		return -1
	}
	tunFd = dupFd
	log.Infoln("[bridge] tun started sysFd=%d kernelFd=%d stack=%s", int(fd), tunFd, st)
	return 0
}

// clash_core_stop_tun 停止 TUN（保留内核与控制面）
//
//export clash_core_stop_tun
func clash_core_stop_tun() {
	mu.Lock()
	defer mu.Unlock()

	raw, err := prepareBase(currentConfigPath())
	if err != nil {
		return
	}
	if err := startLocked(raw); err != nil {
		log.Errorln("[bridge] stop_tun reload failed: %s", err.Error())
		return
	}
	tunFd = 0
	log.Infoln("[bridge] tun stopped")
}

// clash_core_shutdown 关闭内核
//
//export clash_core_shutdown
func clash_core_shutdown() {
	mu.Lock()
	defer mu.Unlock()

	if !loaded {
		return
	}
	executor.Shutdown()
	loaded = false
	tunFd = 0
	log.Infoln("[bridge] shutdown")
}

// clash_core_version 内核版本
//
//export clash_core_version
func clash_core_version() *C.char {
	return cstr(fmt.Sprintf("%s(%s) bridge=%s", Cc.Version, Cc.BuildTime, version))
}

// clash_core_traffic 流量快照 {"up":n,"down":n}
//
// TODO: 接 mihomo 内部的连接统计（下一轮）。UI 的高频流量走 WS /traffic，
// 不依赖这个接口，所以这里先返回合法 JSON，避免 NAPI 侧解析失败。
//
//export clash_core_traffic
func clash_core_traffic() *C.char {
	return cstr(`{"up":0,"down":0}`)
}

// main 在库模式下不会执行，但必须存在。
func main() {}
