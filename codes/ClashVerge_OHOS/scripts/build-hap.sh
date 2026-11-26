#!/bin/sh
# 命令行构建 HAP（无需打开 DevEco）
# 产物：entry/build/default/outputs/default/entry-default-unsigned.hap
set -eu

CLT=${CLT:-/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0}
export NODE_HOME="$CLT/node"
export PATH="$CLT/node/bin:$HOME/.harmonybrew/bin:$PATH"
export DEVECO_SDK_HOME="$CLT/sdk"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

node "$CLT/hvigor/bin/hvigorw.js" assembleHap --mode module -p product=default --no-daemon "$@"

echo
echo "[build-hap] 产物："
ls -lh entry/build/default/outputs/default/*.hap 2>/dev/null || true
