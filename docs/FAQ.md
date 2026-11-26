# FAQ / 排障

## 1. 为什么不用 ArkUI 重写界面？

上游前端有约 4.9 万行 React/TS。重写意味着 8 个页面、15 种语言、MUI 主题、Monaco 编辑器
全部要复刻，工期以月计，而且容易丢失细节。直接让 ArkWeb 跑原版前端，配合一层 Tauri IPC
兼容层，风险与维护成本都低得多。

## 2. 为什么内核要放独立子进程？

把 Go 内核 `dlopen` 进 UI 进程时，Go runtime 初始化会与 ArkWeb/CEF 线程争 musl 锁，
随机把整个进程拖死（详见 [ARCHITECTURE.md](ARCHITECTURE.md) §2）。
独立 native 子进程没有 CEF，Go runtime 可以独占，UI 只走 `127.0.0.1:9090`。
**不要改回单进程。**

## 3. 为什么 TUN 用 mips 栈，不用 gVisor？

gVisor 需要额外移植 OHOS 版，且体积/复杂度都高。mihomo 原生支持
`tun.file-descriptor`，配合 `mips` 栈与 MTU 1400 已在真机验证可用。
TUN 地址段、portal、DNS、MTU 都是真机验证值，**不要随意改**。

## 4. 为什么 MTU 是 1400？

系统 `VpnConfig.mtu` 用 1400，内核侧 `mergeTun()` 也强制 1400。
如果内核侧保持 sing-tun 默认的 9000，会出现“VPN 连上了但大包全丢、网页打不开”的现象。
`Constants.ets` 的 `TUN_MTU` 与 `bridge/main.go` 的 `mergeTun` 必须一致。

## 5. 为什么系统代理 / 开机自启是灰的？

- **系统代理**：HarmonyOS 三方应用没有设置系统级代理的 API（只有应用级
  `connection.setAppHttpProxy`）。
- **开机自启**：`autoStartupManager` 只能查询自身，没有三方设置接口；界面改为引导用户去
  系统「应用启动管理」。
- **静默启动 / 服务模式 / 启动脚本 / DevTools**：平台无对应能力，按上游规范隐藏或置灰。

这些不是 bug，不要试图“修”。

## 6. 为什么没有应用内更新？

HarmonyOS 三方应用没有应用内升级通道；内核随 HAP 发布。
「检查更新」只会跳转 GitHub Release 页面。

## 7. 为什么 HAP 这么大？

主要构成：

| 组成 | 约 |
|---|---|
| `libclash_core.so`（mihomo，已 strip） | 45 MB |
| 前端产物 `rawfile/web` | 9 MB |
| geo 数据 | 12 MB |
| 其它资源 / NAPI / 签名 | 少量 |

可选优化（未做）：更激进的 strip、裁剪 mihomo 特性标签、前端按需分包。
geo 数据不建议改成在线下载，离线更稳。

## 8. 为什么切换订阅 / 开关 TUN 会断网一下？

开关 TUN、重启内核、切换订阅都会触发 `hub.Parse → ApplyConfig(force=true)`，
mihomo 会重建 inbound/listener/DNS/连接，属于上游语义，不是本项目引入的。

## 9. 日志在哪里？

应用沙箱内：

```
<filesDir>/verge/logs/app.log        # ArkTS / 前端 console
<filesDir>/verge/core/logs/core.log  # 内核子进程
<filesDir>/verge/runtime/status.json # 内核心跳
```

常见判据：

| 日志 | 含义 |
|---|---|
| `[CoreHost] starting core child process` | UI 发起子进程 |
| `[CoreHost] core child started pid=` | 系统拉起成功 |
| `[CoreHost] core child ready after` | Go runtime 初始化完成 |
| `[CoreHost] config loaded by child` | 订阅进内核，9090 应开始监听 |
| `[VpnAbility] publish fd=N rc=0` | 扩展建隧道并递 fd |
| `[CoreHost] tun is up (child)` | TUN 全链路通 |
| `core.log: [TUN] ... mtu: 1400` | TUN 参数正确 |
| `Can't find GeoSite.dat` | geo 释放失败，检查 `rawfile/geo` |

## 10. 支持手机 / 平板吗？

`deviceTypes` 配置了 `2in1` 与 `tablet`，但开发和真机验证主要在一台 HarmonyOS PC（2in1，
API 26）上完成。手机（非 2in1）未做适配，托盘、窗口等能力可能不可用。

## 11. 如何换内核版本？

1. 替换 `core/mihomo-<ver>/`，保留 `bridge/`；
2. 修改 `entry/src/main/ets/common/Constants.ets` 的 `MIHOMO_VERSION`；
3. 修改 `scripts/build-core.sh` 的 `-ldflags` 版本号；
4. `sh scripts/build-core.sh`（脚本会断言 TLS / 未定义符号）；
5. 打 HAP，真机确认 `core.log` 的 `[bridge] init done` 与 `config loaded by child`。

注意：`bridge/` 依赖 mihomo 的 `hub.Parse`、`executor.ApplyConfig`、`config.Config`
字段等，上游改签名时需要同步适配。

## 12. 许可证是什么？可以商用吗？

**GPL-3.0-only**。可以商用、修改、再分发，但衍生作品必须继续以 GPL-3.0-only 开源，
保留版权与许可证声明，并显著标注修改。分发二进制时必须提供对应源码。
详见 [LICENSE](../LICENSE) 与 [NOTICE.md](../NOTICE.md)。

## 13. 这个项目提供节点/订阅吗？

不提供。本项目只是一个客户端移植，不含任何代理服务、节点或订阅。
请自备合规的订阅，并遵守所在地法律法规。
