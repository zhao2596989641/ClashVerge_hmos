# 架构

> 本文描述当前实现的稳定结构。改代码前请先读一遍，尤其是「为什么必须分进程」和「控制文件契约」。
> 文件路径均相对 `codes/ClashVerge_OHOS/`。

## 1. 总览

```
┌─ UI 进程（ArkTS + ArkWeb/CEF）──────────────────────────────┐
│  EntryAbility.onCreate → CoreHost.bootEarly()               │
│  CoreHost 只读写控制文件，绝不 dlopen Go                      │
│  React 前端 ↔ LocalServer(http://127.0.0.1:45123)            │
│  前端 ↔ 内核：REST / WebSocket 127.0.0.1:9090                 │
└───────────┬─────────────────────────────────────────────────┘
            │ childProcessManager.startNativeChildProcess(
            │   "libclash_core.so:ClashCoreChildMain", {entryParams})
            ▼
┌─ 内核子进程（无 CEF，Go runtime 独占）───────────────────────┐
│  ClashCoreChildMain(C)：等 clash_core_ready → 进 Go           │
│  clash_core_child_main：init → load → 控制循环（500 ms）       │
│  控制器 9090 + mixed-port 7890                                │
└───────────▲─────────────────────────────────────────────────┘
            │ SCM_RIGHTS（tunfd，子进程自己收）
┌─ VpnExtension 进程（ClashVpnExtensionAbility）──────────────┐
│  createVpnConnection → conn.create() → relayPublish(tun.sock)│
└──────────────────────────────────────────────────────────────┘

另有：
  TrayStatusBarAbility（StatusBarView 扩展进程，托盘面板独立窗口）
  BackGroundAbility（让 hideAbility 具备托盘前置条件）
```

## 2. 为什么必须分进程（不要改回去）

把 Go 内核 `dlopen` 进 UI 进程时，Go runtime 在 `runtime.main` 创建 sysmon
（`runtime.newm1 → runtime._cgo_thread_start → pthread_sigmask/pthread_create`）会**随机卡死**，
并把整个进程（包括 ArkWeb/CEF 的全部线程）一起拖停：

- hilog 停在启动阶段，之后没有任何输出；
- `core.log` 最后一行是被截断的 `init internal/bytealg @0 ms, `；
- 调试器里 Go 线程停在 `runtime.write1 → runtime.write → runtime.writeErrData`。

同一个包、同样代码，有时能完整跑完，有时死在第一个包 —— 这是与 CEF 线程争 musl 锁的竞态，
调时序无法根治。两套可用的鸿蒙参考实现也都让内核远离 CEF：

- ClashBox：UI 是纯 ArkUI，没有 WebView；
- ClashOhos：内核放在 VpnExtension 进程。

本项目选择第三条路：`childProcessManager` 拉起的 **native 子进程**，UI 只通过
`127.0.0.1:9090` 的 REST/WS 控制它。前端因此不需要知道内核在哪个进程。

## 3. UI 进程

| 组件 | 文件 | 职责 |
|---|---|---|
| Ability 生命周期 | `entry/src/main/ets/entryability/EntryAbility.ets` | 窗口、主题、关闭到托盘、自动轻量、托盘事件 |
| 页面 | `pages/Index.ets` | 唯一页面：ArkWeb + 启动层（logo/字标 + 淡出） |
| 本地静态服务 | `server/LocalServer.ets` | 45123，从 `rawfile/web` 读文件，64 KB 分块 |
| 桥入口 | `bridge/JsBridge.ets` | 注入 `window.clashBridge`、命令注册、回包、Channel |
| 命令实现 | `bridge/AppBridge.ets` | 文件/配置/订阅/系统/窗口/剪贴板等命令 |
| 内核 REST | `bridge/MihomoBridge.ets` | `plugin:mihomo|*` → REST，含测速闸门 |
| 内核 WS | `core/MihomoWsHost.ets` | `plugin:mihomo|ws_*` → 真 WebSocket 到 9090 |
| 内核宿主 | `core/CoreHost.ets` | 起子进程、控制文件、status 轮询、geo 释放 |
| TUN 控制 | `core/TunController.ets` | 拉扩展 → 写 `tun.json` → 等 status |
| 托盘 | `core/TrayIcon.ets` / `pages/TrayPanel.ets` | 状态栏图标、右键菜单、独立面板 |
| 前端兼容层 | `webapp/src/ohos/shim.ts` | 接管 Tauri IPC、event、Channel、文件 URL、能力门禁 |

前端加载路径：`ArkWeb → http://127.0.0.1:45123/index.html`。
不用 `resource://rawfile`，因为不透明源下 ESM/Worker/fetch 的行为不可预期。

## 4. 内核子进程

### 4.1 入口

- `entryPoint` = `"libclash_core.so:ClashCoreChildMain"`
- `ClashCoreChildMain` 由 `scripts/build-core.sh` 生成的 C 垫片提供：
  先轮询 `clash_core_ready`（Go init 完成后由 `bridge/main.go` 的 `init()` 置 1），
  再调用 `clash_core_child_main(entryParams)`。
- `entryParams`（JSON）：

```json
{"home":"<filesDir>/verge/core","config":"","control":"<filesDir>/verge/runtime","version":"v1.19.34","sdk":26}
```

`config` 传空：子进程只做 init；订阅随后通过 `reload.json` 下发。

### 4.2 控制文件契约（`<filesDir>/verge/runtime/`）

| 文件 | 写方 | 内容 | 语义 |
|---|---|---|---|
| `reload.json` | UI | `{"seq":N,"path":"…/clash-verge.yaml"}` | `seq` 变化才 load |
| `tun.json` | UI | `{"seq":N,"on":true,"socket":"…/tun.sock","stack":"mips","gateway":"172.19.0.1/30","portal":"172.19.0.2","dns":"…"}` | `seq` 变化才生效 |
| `status.json` | 子进程 | `{"pid","phase","ready","tun","error","config","updatedAt"}` | 500 ms 心跳；>5 s 未更新 = 子进程已死 |
| `vpn-status.json` | VPN 扩展 | `{"connected","tunFd","lastError",…}` | 扩展自己的状态；**不得与 `status.json` 混用** |

`phase`：`init / inited / loaded / ready / load-failed / tun-on / tun-off / tun-fd-failed / tun-start-failed`。

### 4.3 端口与常量（`entry/src/main/ets/common/Constants.ets`）

```
BUNDLE_NAME        com.lyldeer.clashverge
LOCAL_SERVER_PORT  45123     前端 origin
CONTROLLER_PORT    9090      mihomo external-controller（secret 见 verge.json）
mixed-port         7890
TUN_ADDRESS        172.19.0.1/30
TUN_PORTAL         172.19.0.2
TUN_DNS            172.19.0.2
TUN_MTU            1400      ⚠️ 写死；改错会“连上但没网”
TUN_IPV6           fdfe:dcba:9876::1/126
TUN_RELAY_SOCKET   verge/runtime/tun.sock
MIHOMO_VERSION     v1.19.34
```

### 4.4 内核 C ABI（`core/mihomo-1.19.34/bridge/main.go`）

`clash_core_init / load / start_tun / stop_tun / shutdown / version / traffic`
+ `clash_core_ready`（Go init 完成后置 1）+ `clash_core_child_main`（子进程入口，在 `child.go`）。

`start_tun` 内部 `syscall.Dup(fd)` 后交给 sing-tun；`mergeTun` 强制 `mtu=1400`、`stack=mips`、
`auto-route=false`。`clash_core_set_protect_hook` / `clash_core_protect_done` **不导出** ——
mihomo 没有逐 socket protect 的机制，改用 VpnExtension 侧 `protectProcessNet()` 整进程保护。

## 5. TUN 全链路

```
TunController.start
  → CoreHost.ensureStarted()
  → startVpnExtensionAbility
  → 扩展：createVpnConnection（blockedApplications=[自身]，防回环）
         → conn.create() → FdRelay.publish(tun.sock, fd)
  → 子进程 recvFd（SCM_RIGHTS）→ clash_core_start_tun(fd, "mips", …)
  → status.json phase=tun-on
```

判据日志：

```
[VpnAbility] publish fd=N rc=0
[CoreHost] tun is up (child)
core.log: [TUN] Tun adapter listening at ... mtu: 1400
```

## 6. 托盘

| 入口 | 实现 | 说明 |
|---|---|---|
| 状态栏图标 + 右键菜单 | `core/TrayIcon.ets` | `statusBarManager`；右键 8 个页面跳转；退出用系统自带项 |
| 左键（`tray_event=main_window`） | 打开主窗口 | 默认值 |
| 左键（`tray_event=tray_menu`） | `TrayStatusBarAbility` → `pages/TrayPanel.ets` | 独立扩展窗口，自绘 UI、秒级轮询 + 3 条 WS |

托盘面板与主进程的跨进程通信：公共事件 `TRAY_REFRESH / TRAY_COMMAND / TRAY_STATE` +
共享 `filesDir` + 各自连 9090。

> 平台限制：应用侧无法模糊“窗口背后的桌面”。面板采用近实色 + 1 px 分隔线，
> 不要用降 alpha 假装毛玻璃。

## 7. 配置与数据

| 数据 | 位置 | 说明 |
|---|---|---|
| Verge 配置 | `verge/verge.json` | 字段名与上游 `IVerge` 一致；鸿蒙侧无 YAML 解析器，落盘用 JSON |
| 订阅索引 | `verge/profiles.yaml` | 订阅原文保真 |
| 运行时配置 | `verge/clash-verge.yaml` | `RuntimeConfig` 合并 overrides / mode 后写给内核 |
| 跨重载 overrides | `verge/runtime-overrides.json` | 开关 TUN 会整核重载，需保留的字段放这里 |
| 当前模式 | `verge/clash-mode.txt` | `rule / global / direct` |
| 控制器 secret | `verge/core-secret.txt` | 首次启动生成 |
| 应用日志 | `verge/logs/app.log` | 前端 console 与 ArkTS 日志 |
| 内核日志 | `verge/core/logs/core.log` | 子进程 stdout/stderr，跨启动追加 |

## 8. 后台与生命周期

- 主进程必须存活：官方《连接 VPN》服务生命周期规定，调用 `startVpnExtensionAbility` 的应用进程退出时
  系统会停止 VPN。
- `module.json5` 配置 `backgroundModes: ["taskKeeping","dataTransfer"]`，
  并由 `BackgroundKeeper` 启动长时任务；删掉该配置会导致 `startBackgroundRunning` 失败。
- 关闭按钮 → `windowStageClose` + `hideAbility()`（收进托盘），不是最小化。
- 轻量模式同样走 `hideAbility()`，避免在 Dock 留缩略窗。

## 9. 文件地图

```
codes/ClashVerge_OHOS/
├── AppScope/                     app.json5（bundle / 版本 / 图标）
├── entry/
│   ├── src/main/ets/             ArkTS（40 个 .ets）
│   ├── src/main/cpp/             NAPI：clash_adapter（遗留）/ fd_relay / napi_init
│   ├── src/main/resources/
│   │   ├── base/media/           图标、开屏素材
│   │   ├── rawfile/geo/          geosite.dat + country.mmdb
│   │   └── rawfile/icons/        托盘图标
│   └── libs/arm64-v8a/           libclash_core.so（build-core.sh 产物，不入库）
├── core/
│   └── mihomo-1.19.34/           mihomo 源码（+ bridge/ 自写 C ABI）
├── webapp/                       上游前端 vendored 副本
├── scripts/                      build-core.sh / build-web.sh / build-hap.sh
└── docs/                         内部过程记录（不入库）
```

更多构建细节见 [BUILD.md](BUILD.md)，上游改动清单见 [PORTING.md](PORTING.md)。