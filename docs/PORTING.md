# 移植说明（相对上游的改动）

> 本文是「我们改了什么」的权威清单，也是后续跟进上游时的对照表。
> 前端基线：Clash Verge Rev `b3da333b`（2026-11-13，`v2.5.10-65-gb3da333b`，版本 `2.6.0-dev`）。
> 内核基线：mihomo **v1.19.34**（本体未改）。

## 1. 总体策略

- **不重写前端**：ArkWeb 直接运行上游 React，通过 `src/ohos/shim.ts` 接管 Tauri IPC。
- **不把内核塞进 UI 进程**：mihomo 用 c-archive 编成 `.so`，在 `childProcessManager` 的
  native 子进程里运行；UI 只走 REST/WS。
- **TUN 不移植 gVisor**：使用 mihomo 原生 `tun.file-descriptor` + `mips` 栈，
  VpnExtension 建隧道后通过 `SCM_RIGHTS` 递 fd。
- **上游能不改就不改**：前端补丁集中在兼容层与少量平台适配；内核 `bridge/` 为新增目录。

## 2. 前端改动（`codes/ClashVerge_OHOS/webapp`）

### 2.1 新增文件

| 文件 | 作用 |
|---|---|
| `src/ohos/shim.ts` | 鸿蒙 Tauri 兼容层：接管 `__TAURI_INTERNALS__.invoke`、event 插件、Channel 帧、`convertFileSrc`、console 转发、能力置灰 CSS、标题栏避让 |
| `src/services/pending-selection.ts` | 切节点的乐观上屏缓存（8 s TTL），避免内核忙时 UI 卡住 |

### 2.2 修改文件（22 个）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `src/services/bindings.ts` | 命令名/参数对齐 ArkTS 实现 |
| 2 | `src/services/cmds.ts` | 同上；补充 `copyClashEnv` 等 |
| 3 | `src/services/notice-handlers.ts` | 鸿蒙通知适配；内核加载提示 |
| 4 | `src/services/bus/create-bus-handlers.ts` | 事件总线适配；补充刷新键 |
| 5 | `src/services/delay.ts` | 测速策略：整组接口仅用于 ≤24 节点的组；大组逐条 + 并发 6 |
| 6 | `src/hooks/use-proxy-selection.ts` | 接入乐观选择 |
| 7 | `src/components/proxy/use-render-list.ts` | 全局模式渲染 `[GLOBAL, ...所有组]`，GLOBAL 可折叠；接入乐观选择 |
| 8 | `src/components/setting/setting-verge-basic.tsx` | `ENV_OPTIONS` 扁平数组（不能包 Fragment）、env 归一化、复制按钮、隐藏启动脚本 |
| 9 | `src/components/setting/setting-verge-advanced.tsx` | 「检查更新」行跳转 Release |
| 10 | `src/components/setting/mods/clash-core-viewer.tsx` | 隐藏「升级内核」、过滤 Alpha、禁止切换 |
| 11 | `src/components/setting/mods/lite-mode-viewer.tsx` | 即改即存、只留「关闭」、鸿蒙文案 |
| 12 | `src/components/setting/mods/clash-port-viewer.tsx` | 端口弹窗适配 |
| 13 | `src/components/setting/setting-system.tsx` | `IS_OHOS` 分支：系统代理等置灰；开机自启改为「转到设置」 |
| 14 | `src/components/home/clash-info-card.tsx` | 显示「系统代理地址」 |
| 15 | `src/components/home/system-info-card.tsx` | 「检查更新」行、跳转 Release |
| 16 | `src/components/home/proxy-tun-card.tsx` | `IS_OHOS` 分支 |
| 17 | `src/components/home/ip-info-card.tsx` | IP 查询适配 |
| 18 | `src/types/global.d.ts` | 声明 `IS_OHOS` |
| 19 | `src/pages/_routers.tsx` | `createBrowserRouter` → `createHashRouter` |
| 20 | `src/main.tsx` | 首行 import `./ohos/shim` |
| 21 | `src/index.html` | 初始遮罩 + 深浅两套 `--bg-color`（防白闪） |
| 22 | `src/locales/{en,zh}/home.json` | 「检查更新」文案 |

### 2.3 前端根配置

| 文件 | 改动 |
|---|---|
| `vite.config.mts` | `root: 'src'`、`base: './'`、`OS_PLATFORM="linux"`、`IS_OHOS="true"`、本地 vendor 别名、`css.transformer: 'postcss'` |
| `package.json` | 版本 `2.6.0-dev`；移除 github 依赖，改用本地 vendor |
| `vendor/tauri-plugin-mihomo-api/` | 本地 vendor（内容与上游插件 0.7.1 一致） |

> 改前端后**必须重新构建前端产物**，否则 HAP 里仍是旧 JS。

## 3. ArkTS / 原生层（本项目新增）

### 3.1 ArkTS（`entry/src/main/ets/`，40 个文件）

| 模块 | 文件 | 职责 |
|---|---|---|
| Ability | `entryability/EntryAbility.ets`、`tray/TrayStatusBarAbility.ets`、`backgroundability/BackGroundAbility.ets`、`vpnability/ClashVpnExtensionAbility.ets` | 生命周期、托盘扩展、后台、VPN 扩展 |
| 页面 | `pages/Index.ets`、`pages/TrayPanel.ets` | ArkWeb 宿主 + 启动层；自绘托盘面板 |
| 桥 | `bridge/JsBridge.ets`、`bridge/AppBridge.ets`、`bridge/MihomoBridge.ets` | `window.clashBridge`、约 89 条命令、`plugin:mihomo|*` → REST |
| 内核 | `core/CoreHost.ets`、`core/TunController.ets`、`core/MihomoWsHost.ets`、`core/TrayWs.ets` | 子进程、控制文件、TUN、WS |
| 业务 | `profiles/*`、`config/*`、`core/MediaUnlockService.ets`、`core/WebDavService.ets`、`core/BackupService.ets`、`core/Diagnostic.ets` | 订阅、配置、解锁检测、备份、诊断 |
| 系统 | `core/TrayIcon.ets`、`core/HotkeyHost.ets`、`common/AppTheme.ets`、`server/LocalServer.ets` | 托盘、热键、主题、本地静态服务 |
| 基础 | `common/*`（常量、日志、路径、上下文）、`native/*`（NAPI 门面） | — |

### 3.2 C++ / NAPI（`entry/src/main/cpp/`）

| 文件 | 状态 |
|---|---|
| `fd_relay.cpp/.h` | **在用**：VpnExtension 侧 `relayPublish`（unix socket + `SCM_RIGHTS`） |
| `napi_init.cpp` | **在用**：NAPI 模块 `libclash_ohos.so` |
| `clash_adapter.cpp/.h` | 早期「进程内 dlopen」方案遗留，**不再调用**；保留仅作调试参考 |

### 3.3 内核侧（`core/mihomo-1.19.34/`）

| 文件 | 性质 |
|---|---|
| `bridge/main.go` | 新增：C ABI 薄壳（init/load/start_tun/stop_tun/shutdown/version/traffic）+ `clash_core_ready` |
| `bridge/child.go` | 新增：子进程入口、`reload.json`/`tun.json` 轮询、`status.json` 心跳、`recvFd` |
| mihomo 本体 | **零改动** |

`scripts/build-core.sh` 额外负责：

- `-ldflags` 注入真实版本（否则 `/version` 显示源码默认的 `1.10.0`）；
- TLS 重定位断言（只允许 `R_AARCH64_TLSDESC`）；
- 未定义符号检查；
- 生成 `clash_core_marker.c`（`ClashCoreChildMain` 垫片）。

## 4. 资源与构建配置

| 项 | 说明 |
|---|---|
| 开屏素材 | 由上游 SVG 光栅化：猫头 `icon_dark.svg`、字标 `logo.svg`；纯黑/纯白两套，跟应用主题 |
| `startIcon.png` | 512×512 全透明（系统启动页图标必填，透明=隐藏） |
| `rawfile/geo` | `geosite.dat` + `country.mmdb`，来自 MetaCubeX/meta-rules-dat（GPL-3.0） |
| `rawfile/icons` | 托盘图标 |
| `module.json5` | `deviceTypes: ["2in1","tablet"]`；VPN/statusBarView 扩展；`backgroundModes: ["taskKeeping","dataTransfer"]` |
| `build-profile.json5` | `compatibleSdkVersion` / `targetSdkVersion` = **26.0.0**；签名配置不入库，见 `build-profile.example.json5` |

## 5. 与上游行为的刻意差异

| 项 | 上游行为 | 本项目 | 原因 |
|---|---|---|---|
| 全局模式代理页 | 仅显示 `GLOBAL` + 当前选中的组 | 显示 `GLOBAL` + **所有代理组**（GLOBAL 可折叠） | 产品要求：全局模式下仍要能直接切其它组 |
| 测速 | 组接口一次测完整组 | 仅 ≤24 节点用组接口；大组逐条 + 并发 6 | 内核在 200 节点并发探测时会卡死 3–5 s |
| 切节点 | 等内核 PUT 回包 | 立即返回 + 每组串行队列 + 乐观上屏 | 内核忙时 PUT 需 3–5 s |
| 内核升级 | 应用内下载/替换内核 | 随包发布，弹窗只留「重启」 | 平台无应用内替换通道 |
| 检查更新 | 应用内更新 | 跳转 GitHub Release | 无应用内升级通道 |

## 6. 上游跟进（维护手册）

### 6.1 当前基线

- 上游仓库：`https://github.com/clash-verge-rev/clash-verge-rev`
- 本地参考 clone：`resources/git/clash-verge-rev`（不随本仓库发布）
- 基线：`b3da333b`（`v2.5.10-65-gb3da333b`，2026-11-13）

### 6.2 试跑结论（2026-11-26，上游 `dev` = `1dba31c6`，领先 65 个提交）

把本项目的 24 文件前端补丁套到上游最新：

- **21 个文件干净应用**；
- **3 个冲突**，需要手工合并：
  1. `src/components/home/system-info-card.tsx`：开机自启失败提示（`showNotice` vs `console.error`）；
  2. `src/components/setting/setting-system.tsx`：自动启动行 + `Button`/`React` import；
  3. `src/components/proxy/use-render-list.ts`：上游性能重构 + 全局模式行为改动，
     与我们「GLOBAL + 所有组」的产品要求正面冲突（**保留我们的行为**）。

### 6.3 上游新功能评估

上游自基线以来（截至 2026-11-25）新增/变化：

- 连接详情中直接配置域名 / 进程 / IP 规则（新增 `tldts` 依赖；使用现有命令，**不需要新增 Tauri 命令**）；
- `auto_switch_selector_group` 配置项（默认 `true`；上游在 `switch_proxy_node` 中实现了
  “跟随父 select 组”的行为，ArkTS 侧尚未移植）；
- 延迟测试超时自动重测；
- 首页节点卡片沿规则链跟随；
- 全局模式只显示 `GLOBAL` + 当前组（与我们的产品要求冲突，见 §5）。

### 6.4 同步步骤建议

1. 在独立分支上操作，先只替换 `webapp/src`，保留 `src/ohos/` 与 `pending-selection.ts`；
2. 逐个应用 22 个修改文件，优先处理 §6.2 的三个冲突；
3. `npm --prefix webapp install tldts@7.5.5`（若跟进连接规则功能）；
4. 重新构建前端 + HAP，真机验证 8 个页面、代理页、TUN；
5. 把结果写回本文与 `NOTICE.md` 的基线信息。

## 7. 许可证

本项目为 GPL-3.0-only 衍生作品。修改清单、上游版权与第三方素材见 [../NOTICE.md](../NOTICE.md)。
分发 HAP 时请附上 `LICENSE` 与 `NOTICE.md`，并确保对应源码可获取。
