# bridge/ —— HarmonyOS 适配层（本项目新增）

本目录**不是** mihomo 上游代码，而是 `ClashVerge_hmos` 为 HarmonyOS 新增的桥接层。
许可证：**GPL-3.0**（与 mihomo 及本项目一致）。

| 文件 | 作用 |
|---|---|
| `main.go` | C ABI 薄壳：`clash_core_init` / `load` / `start_tun` / `stop_tun` / `shutdown` / `version` / `traffic`，以及 `clash_core_ready`（Go init 完成后置 1） |
| `child.go` | native 子进程入口 `clash_core_child_main`：解析 `entryParams`、轮询 `reload.json` / `tun.json`、写 `status.json` 心跳、通过 `SCM_RIGHTS` 接收 tunfd |

## 构建

由 `../../scripts/build-core.sh` 调用：

1. `go build -buildmode=c-archive` 产出 `libclash.a`；
2. OHOS clang 链成 `libclash_core.so`，并链接一个 C 垫片
   `ClashCoreChildMain`（先等 `clash_core_ready`，再进 Go）；
3. 断言 TLS 重定位只允许 `R_AARCH64_TLSDESC`、不允许未定义的 `clash_core_*` 符号。

## 注意

- 入口函数 `clash_core_child_main` **永不返回**；返回后系统会销毁子进程。
- mihomo 本体未改动；升级内核时保留本目录，并检查 `hub.Parse`、`executor.ApplyConfig`、
  `config.Config` 字段等 API 是否变化。
- 控制文件契约见 `../../../docs/ARCHITECTURE.md`。