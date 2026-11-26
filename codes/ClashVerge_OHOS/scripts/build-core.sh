#!/bin/sh
# 构建 mihomo 内核：Go c-archive → 链成 OHOS 可 dlopen 的 libclash_core.so
#
# 产物：
#   entry/libs/arm64-v8a/libclash_core.so   （内含 mihomo + bridge 的全部 Go 代码）
#
# ⚠️ 必须用「补丁版 Go 工具链」（ohos-go fork），不能用 stock Go。
#    原因（真机实测，2026-11-14）：
#      stock Go 的产物带 1 条 R_AARCH64_TLS_TPREL64（来自 runtime.tls_g），
#      OHOS 的 musl 在 dlopen 时直接拒绝：
#        Error relocating libclash_core.so: initial-exec TLS resolves to dynamic definition
#      musl 的 static_tls_cnt 在进程启动时冻结，之后再 dlopen 的库只要含 TPREL 一律失败。
#    补丁版工具链对 -buildmode=c-archive/arm64 会自动加 -tls=GD -D=TLS_GD
#      （见 cmd/go/internal/work/init.go 的 c-archive 分支），
#      于是 TLS 访问变成 R_AARCH64_TLSDESC（general-dynamic），musl 就能正常分配。
#
# 工具链准备（一次性）：
#   fork 源码放在 $HOME/go-ohos-build（go1.27.4-ohos），
#   工具与驱动装在 $HOME/go-ohos-tools/{compile,asm,link,go}。
#   注：make.bash 在本机走不通（go_bootstrap 被内核拒绝 exec，EACCES），
#   所以改成用 stock go 编译 fork 源码来产出工具，见 docs/HANDOFF.md 的说明。
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLT=${CLT:-/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0}
NDK="$CLT/sdk/default/openharmony/native"
TRIPLE=aarch64-linux-ohos
ABI=arm64-v8a

FORK_GOROOT=${FORK_GOROOT:-$HOME/go-ohos-build}
GOBIN=${GOBIN:-$HOME/go-ohos-tools/go}

if [ ! -x "$GOBIN" ]; then
  echo "[build-core] ✗ 找不到补丁版 go 驱动：$GOBIN"
  echo "             见脚本头部注释与 docs/HANDOFF.md，先准备 ohos-go 工具链。"
  exit 1
fi

export GOROOT="$FORK_GOROOT"
export GOTOOLCHAIN=local
export GOFLAGS=
export GOPROXY=${GOPROXY:-https://goproxy.cn,direct}
export GOPATH=${GOPATH:-$HOME}

MIHOMO="$ROOT/core/mihomo-1.19.34"
OUTDIR="$ROOT/core/out"
mkdir -p "$OUTDIR"

echo "[build-core] 0/4 工具链"
"$GOBIN" version
echo "[build-core]      GOROOT=$GOROOT"

echo "[build-core] 1/4 go build -buildmode=c-archive"
export CGO_ENABLED=1
export GOOS=linux
export GOARCH=arm64
export CC="$NDK/llvm/bin/clang"
export AR="$NDK/llvm/bin/llvm-ar"
export CGO_CFLAGS="--target=$TRIPLE --sysroot=$NDK/sysroot -D__MUSL__ -D__OHOS__ -fPIC -O2"
export CGO_LDFLAGS="--target=$TRIPLE --sysroot=$NDK/sysroot"
export CGO_LDFLAGS_ALLOW='.*'

cd "$MIHOMO"
# tag 选择说明：
#   - 不加 with_gvisor：我们用 tun.stack=mips，gvisor 栈用不到，
#     不加这个 tag 时 sing-tun 会编译 stack_gvisor_stub.go，直接省掉一大坨 gvisor 代码与体积
#   - no_tailscale / no_zerotier / no_easytier：桌面端几乎用不到的组网协议，砍掉省体积
"$GOBIN" build \
  -buildmode=c-archive \
  -tags "no_tailscale no_zerotier no_easytier" \
  -trimpath \
  -ldflags "-s -w -X github.com/metacubex/mihomo/constant.Version=v1.19.34" \
  -o "$OUTDIR/libclash.a" \
  ./bridge
ls -lh "$OUTDIR/libclash.a"

echo "[build-core] 2/4 链成 .so"
# ⚠️ marker 里的符号名必须与 bridge/main.go 的 //export 完全一致。
# 这里曾经写成早期的 CamelCase `ClashCoreVersion`，而桥后来改成了 `clash_core_version`：
# 链接期不会报错（默认允许未定义符号），但真机 dlopen(RTLD_NOW) 会直接失败：
#   Error relocating libclash_core.so: ClashCoreVersion: symbol not found
cat > "$OUTDIR/clash_core_marker.c" <<'EOF'
#include <unistd.h>

extern const char* clash_core_version(void);
const char* clash_core_marker(void) { return clash_core_version(); }

// Go 侧 bridge/main.go 的 init() 跑完会把这里置 1。
// C 侧（clash_adapter.cpp）通过 dlsym 拿到地址并轮询，**先等 Go 初始化完成再调用任何 Go 函数**，
// 否则会撞在 doInit 中间导致整个进程卡死（真机实测 2026-11-15）。
volatile int clash_core_ready = 0;

// ---------------------------------------------------------------------------
// native 子进程入口（HarmonyOS childProcessManager）
//
// 为什么要子进程：把 Go runtime dlopen 进 UI 进程时，初始化会在 newm(sysmon) 的
// pthread_create 上卡住，并把整个进程（含 ArkWeb/CEF）一起拖停。改成独立进程后，
// 内核在**没有 CEF** 的干净环境里初始化，UI 只通过 9090 REST/WS 与文件控制它。
//
// 契约（见 entry/src/main/ets/core/CoreHost.ets 与 bridge/child.go）：
//   entryParams = {"home","config","control","version","sdk"} 的 JSON
//
// ⚠️ 这个函数**永不返回**：返回后系统会销毁子进程。
// ---------------------------------------------------------------------------
typedef struct ChildProcessArgsLike {
    char* entryParams;   // NativeChildProcess_Args{ char* entryParams; FdList fdList; }
    void* fdListHead;    // 这里不使用传 fd，占位保持 ABI 对齐
} ChildProcessArgsLike;

extern int clash_core_child_main(char* params);

void ClashCoreChildMain(ChildProcessArgsLike args)
{
    // 子进程 dlopen 本库时 Go runtime 还在另一个线程里初始化，
    // 先等它就绪（纯内存读，不进 Go），否则会撞在 doInit 中间。
    while (clash_core_ready == 0) {
        usleep(10 * 1000);
    }
    clash_core_child_main(args.entryParams);
}
EOF

"$NDK/llvm/bin/clang" \
  --target=$TRIPLE \
  --sysroot="$NDK/sysroot" \
  -fPIC -O2 -shared \
  -o "$OUTDIR/libclash_core.so" \
  "$OUTDIR/clash_core_marker.c" \
  -Wl,--whole-archive "$OUTDIR/libclash.a" -Wl,--no-whole-archive \
  -Wl,--allow-multiple-definition \
  -lpthread -ldl -lm

echo "[build-core] 3/4 校验：未定义符号 + TLS 模型"
# (a) 只允许 libc / libm / pthread / dl 这类系统符号未定义；
#     任何 clash_core_* / ClashCore* 未定义 → 运行期 dlopen 必失败，直接让构建失败。
BAD=$("$NDK/llvm/bin/llvm-nm" -D --undefined-only "$OUTDIR/libclash_core.so" \
  | awk '{print $2}' | grep -E '^(clash_core_|ClashCore)' || true)
if [ -n "$BAD" ]; then
  echo "[build-core] ✗ 存在未定义的导出符号："
  echo "$BAD"
  exit 1
fi

# (b) TLS 重定位必须是 TLSDESC（动态模型）。
#     只要出现 TLS_TPREL / TLS_IE 这类 initial-exec 重定位，真机 musl 会拒绝 dlopen，
#     表现是「9090 端口连不上、代理页全空」，极难反推 —— 所以这里直接拦住。
TLS_BAD=$("$NDK/llvm/bin/llvm-readelf" -r "$OUTDIR/libclash_core.so" \
  | grep -E "R_AARCH64_TLS_(TPREL|IE)" || true)
if [ -n "$TLS_BAD" ]; then
  echo "[build-core] ✗ 存在 initial-exec 类 TLS 重定位（musl 会拒绝 dlopen）："
  echo "$TLS_BAD"
  echo "             说明本次没有走补丁版工具链（-tls=GD）。"
  exit 1
fi

echo "[build-core] 4/4 拷贝到 entry/libs/$ABI"
mkdir -p "$ROOT/entry/libs/$ABI"
cp -f "$OUTDIR/libclash_core.so" "$ROOT/entry/libs/$ABI/libclash_core.so"
ls -lh "$ROOT/entry/libs/$ABI/libclash_core.so"

echo "[build-core] 动态依赖："
"$NDK/llvm/bin/llvm-readelf" -d "$ROOT/entry/libs/$ABI/libclash_core.so" | grep NEEDED || true
echo "[build-core] TLS 重定位（应全是 TLSDESC）："
"$NDK/llvm/bin/llvm-readelf" -r "$ROOT/entry/libs/$ABI/libclash_core.so" | grep "R_AARCH64_TLS" || echo "      （无 TLS 重定位）"
