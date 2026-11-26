<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/wordmark-light.png">
  <img src="docs/assets/wordmark-dark.png" width="320" alt="Clash Verge">
</picture>

# Clash Verge · HarmonyOS

**把 Clash Verge Rev 移植到 HarmonyOS PC 的非官方版本**

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
![HarmonyOS](https://img.shields.io/badge/HarmonyOS-API%2026-red)
![mihomo](https://img.shields.io/badge/mihomo-v1.19.34-green)
![Platform](https://img.shields.io/badge/platform-2in1%20%7C%20tablet-lightgrey)

</div>

> **非官方项目。** 本项目与 [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)、
> [MetaCubeX](https://github.com/MetaCubeX) 均无隶属关系。
> 本项目不提供任何节点、订阅或代理服务，仅用于学习、研究与自用。
> 请遵守您所在国家/地区的法律法规以及您所用服务商的条款。

---

## 这是什么

这是一个把 Windows 上的 **Clash Verge Rev** 尽可能完整地搬到 **HarmonyOS PC（2in1 / tablet）** 的移植工程。

设计上不重写界面：**ArkWeb 直接运行上游原版 React 前端**，ArkTS 负责实现 Tauri 命令桥与鸿蒙原生能力，
mihomo 内核以 **native 子进程** 运行，TUN 由 **VpnExtensionAbility** 建隧道后通过 `SCM_RIGHTS` 把 fd 递给内核。

| 项 | 说明 |
|---|---|
| 应用包名 | `com.lyldeer.clashverge` |
| 应用版本 | `2.6.0`（对应上游 2.6.0-dev 基线） |
| 内核 | mihomo **v1.19.34**（源码随仓库提供，`bridge/` 为本项目新增） |
| 目标平台 | HarmonyOS API 26，`2in1` + `tablet` |
| 前端基线 | Clash Verge Rev `b3da333b`（2026-11-13，`v2.5.10-65-gb3da333b`） |
| 许可证 | **GPL-3.0-only**（上游为 GPL 系，衍生作品必须同协议） |

## 功能

已在 HarmonyOS PC（2in1，API 26）真机验证：

- 上游 8 个页面：首页 / 代理 / 订阅 / 规则 / 连接 / 日志 / 设置 / 关于
- 订阅加载、切换、自动更新；订阅编辑与增强（Merge / Script）
- 代理组、节点切换、延迟测速（大组逐条 + 并发限制）
- TUN 模式（VpnExtension + mips 栈 + MTU 1400）、mixed-port
- 规则、连接、日志页面（REST / WebSocket）
- 流量与内存统计、首页 IP / 解锁检测（13 项）
- 托盘图标 + 右键菜单 + 独立托盘面板（左键）
- 全局热键、关闭收进托盘、轻量模式
- 深浅色 / 应用主题分离、自绘开屏
- 备份 / WebDAV、诊断导出

### 平台不提供、按上游规范置灰或隐藏的能力

| 功能 | 处理 |
|---|---|
| 系统代理（全局） | 置灰；三方应用无设置系统级代理的 API |
| 开机自启设置 | 置灰；引导到系统「应用启动管理」 |
| 静默启动 | 置灰 |
| 应用内自动更新 | 「检查更新」跳转 GitHub Release；内核随包发布 |
| 服务模式 / 启动脚本 / DevTools | 隐藏 |

## 架构

```
┌─ UI 进程（ArkTS + ArkWeb）────────────────────────────────────┐
│  EntryAbility → CoreHost.bootEarly()                          │
│  React 前端 ← LocalServer(http://127.0.0.1:45123)             │
│  前端 ↔ 内核：REST / WebSocket 127.0.0.1:9090                  │
└───────────────┬───────────────────────────────────────────────┘
                │ childProcessManager.startNativeChildProcess(
                │   "libclash_core.so:ClashCoreChildMain", {entryParams})
                ▼
┌─ 内核子进程（无 CEF，Go runtime 独占）────────────────────────┐
│  ClashCoreChildMain(C) → 等 clash_core_ready → 进 Go           │
│  clash_core_child_main：init → load → 控制循环（500 ms）       │
│  控制器 9090 + mixed-port 7890                                │
└───────────────▲───────────────────────────────────────────────┘
                │ SCM_RIGHTS（tunfd）
┌─ VpnExtension 进程（ClashVpnExtensionAbility）────────────────┐
│  createVpnConnection → conn.create() → relayPublish(tun.sock) │
└───────────────────────────────────────────────────────────────┘
```

为什么内核必须分进程、控制文件契约、端口常量、TUN 全链路和托盘实现，见
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 构建

### 环境

- HarmonyOS SDK / 命令行工具 **API 26**（DevEco Studio 或 Command Line Tools）
- Node.js **22+**（前端构建）
- Python 3（构建脚本同步文件用）
- **OHOS 版 Go 工具链**（构建内核；见 [docs/BUILD.md](docs/BUILD.md)）

### 三条命令

```bash
cd codes/ClashVerge_OHOS

# 0) 首次安装前端依赖
npm --prefix webapp ci

# 1) 前端：vite build → entry/src/main/resources/rawfile/web
sh scripts/build-web.sh

# 2) 内核：Go c-archive → entry/libs/arm64-v8a/libclash_core.so
sh scripts/build-core.sh

# 3) HAP：签名打包
sh scripts/build-hap.sh
# 产物：entry/build/default/outputs/default/entry-default-signed.hap
```

> 只改 ArkTS 时只需第 3 步；改前端必须重跑第 1 + 3 步；改内核必须重跑第 2 + 3 步。

### 签名

仓库**不包含任何签名证书**。请复制 `build-profile.example.json5` 为 `build-profile.json5`，
在 DevEco Studio 的 **File → Project Structure → Signing Configs** 中生成自己的调试签名，
或手动填入证书 / Profile 路径。详见 [docs/BUILD.md](docs/BUILD.md)。

## 使用

1. 用 DevEco Studio 或 `hdc install` 安装 HAP；
2. 首次开启 TUN 时同意系统的「创建 VPN 连接」授权；
3. 在「订阅」页添加你的订阅，或在「设置」里配置；
4. 需要代理其它应用时，把应用代理指向首页显示的 **系统代理地址**（`127.0.0.1:7890`）。

> 应用是自用向移植，没有上架计划；`compatibleSdkVersion` 直接对齐 API 26。

## 已知限制

- **系统代理 / 开机自启**：三方应用无对应系统 API，界面按上游规范置灰。
- **应用内更新**：无应用内升级通道；内核随包发布，检查更新跳转 Release 页。
- **TUN 参数**：mips 栈、MTU 1400、地址段 `172.19.0.1/30`；这些值经过真机验证，不要随意修改。
- **内核重载**：开关 TUN、切换订阅、重启内核会整核重载（上游语义），期间连接会短暂中断。
- **包体**：HAP 约 75–76 MB（mihomo 约 45 MB + 前端约 9 MB + geo 数据）。
- **平台**：仅面向 API 26 的 PC / 平板；未做手机适配，也未做上架合规适配。

更完整的排障与限制说明见 [docs/FAQ.md](docs/FAQ.md)。

## 与上游的关系

- 前端：`codes/ClashVerge_OHOS/webapp` 是 Clash Verge Rev 的 vendored 副本，**修改了 24 个 `src` 文件**，
  并调整了 `vite.config.mts` 与 `package.json`。完整清单与修改原因见 [docs/PORTING.md](docs/PORTING.md)。
- 内核：`core/mihomo-1.19.34` 为 mihomo v1.19.34 源码；本项目只新增了 `bridge/`（C ABI + 子进程入口），
  mihomo 本体未改动。
- ArkTS / NAPI / 构建脚本：本项目新增。
- 上游同步：当前基线为 `b3da333b`；同步上游时需处理 `use-render-list.ts` 等少量冲突，
  详见 [docs/PORTING.md](docs/PORTING.md) 的「上游跟进」一节。

## 许可证与致谢

本项目以 **GNU General Public License v3.0** 发布，完整文本见 [LICENSE](LICENSE)。
它衍生自 Clash Verge Rev（GPL-3.0-only）与 mihomo（GPL-3.0），因此**必须**继续以 GPL-3.0-only 分发。
若你分发由本仓库构建的 HAP，请同时提供对应源码并保留 [LICENSE](LICENSE) 与
[NOTICE.md](NOTICE.md) 中的版权与修改声明。

第三方组件、参考实现与素材的完整清单见 [NOTICE.md](NOTICE.md)。特别感谢：

- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) —— 前端与整体产品形态
- [mihomo](https://github.com/MetaCubeX/mihomo) —— 内核
- [ClashOhos](https://github.com/ls965526741/ClashOhos) / [ClashBox](https://github.com/xiaobaigroup/ClashBox)
  —— 鸿蒙代理实现的重要参考（TUN 参数、构建思路；未复制其代码）
- [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) —— 内置 geo 数据
- [sysit/ohos-go](https://github.com/sysit/ohos-go) —— OHOS Go 工具链
- Mozilla Twemoji —— emoji 字体

## English

An **unofficial** HarmonyOS PC port of [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev).
The upstream React frontend runs unmodified inside ArkWeb; ArkTS provides the Tauri-compatible
bridge and native HarmonyOS capabilities; mihomo v1.19.34 runs in a native child process and
receives the TUN fd from a `VpnExtensionAbility` over `SCM_RIGHTS`.

Licensed under **GPL-3.0** because it is a derivative work of Clash Verge Rev and mihomo.
See [NOTICE.md](NOTICE.md) for third-party components and [docs/BUILD.md](docs/BUILD.md) for build
instructions. This project is not affiliated with the upstream projects and does not provide
any proxy service.
