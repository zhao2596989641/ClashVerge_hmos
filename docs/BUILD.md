# 构建

> 本文假设你在 HarmonyOS PC 或 Linux 主机上构建。仓库只包含源码，**不包含**
> `node_modules`、`libclash_core.so`、`rawfile/web`、HAP 等生成物。

## 1. 环境要求

| 组件 | 版本 / 说明 |
|---|---|
| HarmonyOS SDK / Command Line Tools | **API 26**（HarmonyOS 26.0.0）；hvigor 7.x |
| Node.js | **22+**（本项目在 Node 26 上验证） |
| Python 3 | 构建脚本用于同步前端产物 |
| Go | **OHOS 版 Go 工具链**（`go1.27.4-ohos` fork），不能用 stock Go |
| 签名 | DevEco Studio 调试签名（自用）；或手动配置证书 / Profile |
| 安装 | `hdc`（或在 DevEco 里直接 Run） |

### 为什么必须用补丁版 Go

stock Go 的 `-buildmode=c-archive` 产物含 `R_AARCH64_TLS_TPREL64`（initial-exec TLS），
OHOS 的 musl 在 `dlopen` 时直接拒绝：

```
Error relocating libclash_core.so: initial-exec TLS resolves to dynamic definition
```

`sysit/ohos-go` 的 fork 会在 c-archive/c-shared + arm64 时自动加 `-tls=GD -D=TLS_GD`，
产物变为 `R_AARCH64_TLSDESC`。本项目还在 fork 上打了两处本地补丁：

- `cmd/link/internal/ld/outbuf_mmap.go`：容忍 `fallocate` 的 `EACCES`
- `time/zoneinfo_openharmony.go`：补 `//go:build openharmony`

工具链准备方式见 `codes/ClashVerge_OHOS/scripts/build-core.sh` 顶部注释。
默认路径可用环境变量覆盖：

```bash
export FORK_GOROOT=/path/to/go-ohos-build
export GOBIN=/path/to/go-ohos-tools/go
```

## 2. 构建前端

```bash
cd codes/ClashVerge_OHOS

# 首次（或依赖变化后）
npm --prefix webapp ci

# 构建并同步到 entry/src/main/resources/rawfile/web
sh scripts/build-web.sh
```

要求：

- **必须前台运行**，不要放进后台任务；vite 在默认 outDir 下后台构建可能产物消失。
- `scripts/build-web.sh` 会调用 `npx vite build`，然后用 Python 清空并同步 `rawfile/web`。
- 如果需要手动指定输出目录，务必使用**绝对路径**：

```bash
cd webapp
node node_modules/vite/bin/vite.js build --outDir /abs/path/web-build-out --emptyOutDir
```

验证产物：

```bash
ls entry/src/main/resources/rawfile/web/assets/index-*.js
```

## 3. 构建内核

```bash
cd codes/ClashVerge_OHOS
sh scripts/build-core.sh
```

脚本流程：

1. 用补丁版 Go 编 `core/mihomo-1.19.34/bridge` 为 c-archive；
2. 用 OHOS clang 链成 `libclash_core.so`，并注入 `ClashCoreChildMain` 垫片；
3. 校验：
   - 不允许出现未定义的 `clash_core_*` / `ClashCore*` 符号；
   - TLS 重定位只能是 `R_AARCH64_TLSDESC`，出现 `TLS_TPREL` / `TLS_IE` 直接失败；
4. 拷贝到 `entry/libs/arm64-v8a/libclash_core.so`。

产物约 43 MiB（44.9 MB），已 strip。

> 换内核版本时：替换 `core/mihomo-<ver>/`（保留 `bridge/`），同步修改
> `entry/src/main/ets/common/Constants.ets` 的 `MIHOMO_VERSION` 与
> `scripts/build-core.sh` 的 `-ldflags` 版本号；`bridge/` 依赖的 mihomo API
>（`hub.Parse`、`executor.ApplyConfig`、`config.Config` 字段等）若有变化需一起适配。

## 4. 构建 HAP

### 4.1 准备签名

仓库不包含证书。复制示例配置：

```bash
cd codes/ClashVerge_OHOS
cp build-profile.example.json5 build-profile.json5
```

然后在 DevEco Studio 中打开工程，**File → Project Structure → Project → Signing Configs**，
勾选自动签名（或手动填入证书 / Profile）。`build-profile.json5` 已被 `.gitignore` 忽略。

### 4.2 命令行打包

```bash
cd codes/ClashVerge_OHOS

export CLT=/path/to/hmos-clt                    # HarmonyOS Command Line Tools 根目录
export DEVECO_SDK_HOME="$CLT/sdk"               # 不设置会报 00303217

"$CLT/node/bin/node" "$CLT/hvigor/bin/hvigorw.js" \
  --mode module -p module=entry@default -p ohos-app-environment= \
  -p requiredDeviceType=2in1 -p buildMode=debug -p product=default \
  assembleHap --parallel --incremental
```

或直接使用：

```bash
sh scripts/build-hap.sh
# 可通过 CLT=/path/to/hmos-clt 覆盖工具链路径
```

产物：

```
entry/build/default/outputs/default/entry-default-signed.hap
```

### 4.3 只改了一部分代码？

| 改动 | 需要重跑 |
|---|---|
| ArkTS（`entry/src/main/ets/**`） | HAP |
| 前端（`webapp/src/**`） | 前端 + HAP |
| 内核 / `bridge/` | 内核 + HAP |
| 资源 / 图标 | HAP |
| `module.json5` / `app.json5` | HAP |

## 5. 安装与首次运行

```bash
hdc install entry/build/default/outputs/default/entry-default-signed.hap
```

首次开启 TUN 时，系统会弹出「允许创建 VPN 连接」，必须同意；拒绝后需要到系统设置里手动允许。
主进程必须保持运行（长时任务 + 托盘），否则系统会停止 VPN。

日志位置（应用沙箱内）：

```
<filesDir>/verge/logs/app.log
<filesDir>/verge/core/logs/core.log
```

## 6. 常见坑

1. **hvigor 缓存 native 库**：替换 `libclash_core.so` 后，HAP 里可能仍是旧库。
   打包前删除 `entry/build/default/intermediates/stripped_native_libs` 与旧 HAP，
   或对比 HAP 内 `core.so` 的大小。
2. **vite 后台构建**：必须前台 + 绝对 `--outDir`，否则产物可能凭空消失。
3. **`rm` / 批量删除**：在部分鸿蒙终端环境里 `rm` 被替换成安全 shim；脚本里用 Python
   逐文件删除更可靠。
4. **hmdfs 限制**：不支持 `chmod`、硬链接、`flock`；`fallocate` 可能恒 `EACCES`。
5. **`grep` 的或运算**：某些鸿蒙终端的 grep 对 `\|` / `A|B` 会静默漏报，排查时拆成单关键词。
6. **签名**：`bundleName` 必须与签名 Profile 一致；换机器或证书过期后重新生成。
7. **长时任务**：`module.json5` 的 `backgroundModes` 不能删，否则 `startBackgroundRunning` 失败。

## 7. 上游同步

当前前端基线为 Clash Verge Rev `b3da333b`（2026-11-13）。同步步骤与已知冲突见
[PORTING.md](PORTING.md)。建议在独立分支上操作，先跑通前端构建，再处理 ArkTS 与内核。