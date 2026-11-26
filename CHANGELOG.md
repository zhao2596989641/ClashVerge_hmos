# Changelog

## v2.6.0-ohos.1（2026-11-26）

首个公开快照：把 Clash Verge Rev 移植到 HarmonyOS PC（2in1 / tablet）。

### 基线

- 前端：Clash Verge Rev `b3da333b`（2026-11-13，`v2.5.10-65-gb3da333b`，`2.6.0-dev`）
- 内核：mihomo **v1.19.34**（源码随仓库提供，`bridge/` 为新增）

### 功能

- ArkWeb 运行上游原版 React 前端（8 个页面）
- ArkTS 实现约 89 条 Tauri 兼容命令
- mihomo 作为 native 子进程运行；REST/WS 控制器 9090、mixed-port 7890
- TUN：VpnExtension 建隧道 → `SCM_RIGHTS` 递 fd → mips 栈 + MTU 1400
- 订阅管理 / 自动更新 / 增强（Merge、Script）
- 代理组、节点切换、延迟测速（含大组保护）
- 规则 / 连接 / 日志页面、流量与内存统计
- 托盘图标 + 右键菜单 + 独立托盘面板、全局热键、关闭收进托盘、轻量模式
- 深浅色 / 应用主题分离、自绘开屏
- 备份 / WebDAV、媒体解锁检测（13 项）、诊断导出

### 平台限制

- 系统代理、开机自启设置、静默启动等按平台能力置灰或隐藏
- 无应用内更新；内核随包发布
- 仅面向 API 26 的 2in1 / tablet，手机未适配

### 许可

GPL-3.0。上游与第三方组件见 [NOTICE.md](NOTICE.md)。