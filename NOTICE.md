# NOTICE · 第三方组件、参考实现与修改声明

本仓库（`ClashVerge_hmos`）是 **Clash Verge Rev 的 HarmonyOS 非官方移植**，并以 **GPL-3.0** 发布。
本文件列出上游组件、参考实现、内置数据与素材的来源和许可证，并说明本项目对上游所做的修改。

> 本项目与下列上游项目均无隶属关系。文中的项目名、图标与商标归各自权利人所有。

---

## 1. 上游组件（直接包含在仓库中）

### Clash Verge Rev

- 项目：https://github.com/clash-verge-rev/clash-verge-rev
- 许可证：**GPL-3.0-only**
- 使用方式：`codes/ClashVerge_OHOS/webapp/` 为其前端源码的 vendored 副本
- 基线版本：`b3da333b`（2026-11-13，`v2.5.10-65-gb3da333b`），`package.json` 版本 `2.6.0-dev`
- 修改内容：
  - 新增鸿蒙 Tauri 兼容层 `src/ohos/shim.ts` 与乐观选择缓存 `src/services/pending-selection.ts`
  - 修改 22 个 `src` 文件（托盘/设置/首页/代理页/订阅服务等），完整清单见
    [docs/PORTING.md](docs/PORTING.md)
  - 调整 `vite.config.mts`（本地静态服务、`IS_OHOS`、样式降级）与 `package.json`（本地 vendor 依赖）
  - 新增本地 vendor 的 `tauri-plugin-mihomo-api`（内容与上游插件 0.7.1 一致）
- 许可证文本：`codes/ClashVerge_OHOS/webapp/LICENSE`

### mihomo

- 项目：https://github.com/MetaCubeX/mihomo
- 许可证：**GPL-3.0**
- 使用方式：`codes/ClashVerge_OHOS/core/mihomo-1.19.34/` 为 v1.19.34 源码
- 修改内容：
  - **mihomo 本体未改动**
  - 新增 `bridge/main.go`、`bridge/child.go`：为 HarmonyOS 提供的 C ABI 薄壳与 native 子进程入口
  - 构建时通过 `-ldflags` 注入真实版本号（源码默认值为 `1.10.0`）
- 许可证文本：`codes/ClashVerge_OHOS/core/mihomo-1.19.34/LICENSE`

### MetaCubeX meta-rules-dat（geo 数据）

- 项目：https://github.com/MetaCubeX/meta-rules-dat
- 许可证：**GPL-3.0**（仓库自身）
- 内置文件：`entry/src/main/resources/rawfile/geo/geosite.dat`、`country.mmdb`
- 来源：https://github.com/MetaCubeX/meta-rules-dat/releases（`latest`）
- 说明：其中的 GeoIP 数据派生自 MaxMind **GeoLite2**（CC BY-SA 4.0）。
  这些数据文件保留其上游条款；本项目仅做离线打包以支持无网启动。
- MaxMind 署名：*This product includes GeoLite2 data created by MaxMind, available from
  https://www.maxmind.com.*

### Twemoji Mozilla 字体

- 项目：https://github.com/mozilla/twemoji-colr
- 许可证：**CC BY 4.0**（Twemoji 图形）
- 内置文件：`codes/ClashVerge_OHOS/webapp/src/assets/fonts/Twemoji.Mozilla.ttf`
- 用途：前端 emoji 显示（随上游前端一起引入）

### 前端 npm 依赖

`codes/ClashVerge_OHOS/webapp/package.json` 与 `package-lock.json` 中的依赖各自遵循其许可证
（以 MIT / ISC / Apache-2.0 为主），包括但不限于 React、MUI、Vite、Monaco Editor、
`@tauri-apps/*`、`js-yaml`、`validator` 等。分发时请保留各依赖自带的许可证声明。

---

## 2. 参考实现（未复制代码）

以下项目在架构选型与参数取值阶段被参考过，但**没有把其源码复制进本仓库**：

### ClashOhos

- 项目：https://github.com/ls965526741/ClashOhos
- 许可证：**GPL-3.0-only**
- 参考点：
  - TUN 地址段 / portal / DNS / MTU 等真机验证值的选取
  - VpnExtension 建隧道、UI 与内核分离的整体思路
- 说明：本项目的 `fd_relay.cpp`、`bridge/` 为自研实现；`clash_adapter.cpp` 为早期进程内
  dlopen 方案的遗留文件（当前不调用）。经代码比对，未发现与 ClashOhos 存在实质性复制。

### ClashBox

- 项目：https://github.com/xiaobaigroup/ClashBox
- 许可证：**GPL-3.0**
- 参考点：
  - 鸿蒙上使用补丁版 Go 工具链（TLSDESC）以让 musl 接受 c-archive/c-shared 产物的公开经验
  - 构建标签与体积裁剪思路
- 说明：本项目的内核桥接为自研，采用 mihomo 原生 `tun.file-descriptor` + `mips` 栈，
  **未使用** ClashBox 的 gVisor 方案，也未复制其代码。

### sysit/ohos-go（构建工具链）

- 项目：https://github.com/sysit/ohos-go
- 许可证：**BSD-3-Clause**（Go Authors）
- 使用方式：仅作为构建内核的 Go 工具链（`go1.27.4-ohos` fork），不随仓库分发。
- 本项目在工具链上做过两处本地补丁（`outbuf_mmap.go`、`zoneinfo_openharmony.go`），
  详见 `codes/ClashVerge_OHOS/scripts/build-core.sh` 顶部注释。

### Remielle（托盘 API 参考）

- 同作者的另一桌面项目，仅参考 `statusBarManager` 的系统托盘 API 用法；
  本仓库不包含 Remielle 的代码或素材。

---

## 3. 修改声明（GPL-3.0 §5(a)）

本仓库是 Clash Verge Rev 与 mihomo 的**修改版本**，修改时间为 **2026 年 11 月**。
主要修改包括：

1. 新增 ArkTS 应用层（UIAbility、Tauri 命令桥、内核宿主、托盘、VPN 扩展、本地静态服务等）；
2. 新增 `entry/src/main/cpp/` NAPI 与 fd relay；
3. 在 mihomo 源码中新增 `bridge/`；
4. 对 vendored 前端做鸿蒙兼容与平台能力适配（清单见 `docs/PORTING.md`）；
5. 新增构建脚本、资源与文档。

GPL-3.0 允许对上游进行修改、移植和再分发，但要求：

- 衍生作品继续以 **GPL-3.0** 授权；
- 保留版权声明与许可证文本；
- 显著标注修改内容与日期；
- 分发二进制时提供**对应的完整源码**（本仓库即对应源码）。

若你分发由本仓库构建的 HAP，请同时附上 [LICENSE](LICENSE) 与本文件，并确保源码可获取。