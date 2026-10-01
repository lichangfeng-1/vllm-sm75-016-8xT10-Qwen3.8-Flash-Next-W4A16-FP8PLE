#!/usr/bin/env bash
# BUILD v4（2026-10-01：层2 缺 libnvidia-api.so.1 时预检并打印获取方法，退出码 4；清单见 审查记录 §v3.3）
# BUILD v3（2026-10-01 二轮 review 修订 B1-B2，清单见 内部/审查记录-自包含部署包-v1.md §v3.2）
#   B1 旧版层1 写死 FROM vllm-sm75-next-ultra-0924:latest —— 那是某台机器上的本地标签，
#      新服务器上不存在，build 会在层1 直接失败且报错不指向根因；现改 ARG BASE 并在开建前预检；
#   B2 基座缺失时给两条明路：docker load 基座 tar（包外自带），或 BOOTSTRAP=1 用包内 code/ 源码
#      走官方链（standard → ultra）现建基座；bootstrap 路径**未在本包验证**（本机基座是既有镜像），只作可选。
# 三层补丁：console-patched -> patched-nvapi -> patched-nvapi-awqple（+可选层4 incple）
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd -- "$HERE/.." && pwd)"
CODE="$PKG/code/VLLM-SM75-main0.16"
BASE_IMG="${BASE_IMG:-vllm-sm75-next-ultra-0924:latest}"
MID="${MID_TAG:-vllm-sm75-next-ultra-0924:console-patched}"
OUT="${OUT_TAG:-vllm-sm75-next-ultra-0924:patched-nvapi}"
OUT2="${OUT2_TAG:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple}"

if ! docker image inspect "$BASE_IMG" >/dev/null 2>&1; then
  echo "!! 基座镜像不在: $BASE_IMG"
  echo "   本包的四层补丁都建在 SM75 v0.1.6 ultra 基座之上，基座不随包（约 70G，无法内置）。两条路："
  echo "   1) 有基座 tar：docker load -i <基座>.tar 后把它的标签改成 $BASE_IMG（或 BASE_IMG=<你的标签> 重跑）"
  echo "   2) 从源码现建：BOOTSTRAP=1 bash build.sh <cfg>  （走 code/ 官方链 standard→ultra，需外网与数小时，未在本包验证）"
  exit 4
fi

if [ "${BOOTSTRAP:-0}" = "1" ]; then
  echo "=== 基座 bootstrap：官方源码链（standard → ultra），耗时以小时计 ==="
  [ -d "$CODE/docker" ] || { echo "!! 缺源码树 $CODE/docker"; exit 4; }
  ( cd "$CODE" && bash docker/build.sh )
  ( cd "$CODE" && EDITION=ultra bash docker/build.sh )
  V="$(tr -d ' \r\n' < "$CODE/docker/VERSION")"
  BASE_IMG="vllm-sm75:v${V}-ultra"
  docker image inspect "$BASE_IMG" >/dev/null 2>&1 || { echo "!! bootstrap 后仍无 $BASE_IMG"; exit 4; }
fi
echo "BASE_IMG=$BASE_IMG"

if [ ! -f "$HERE/libnvidia-api.so.1" ]; then
  echo "!! 缺 docker/libnvidia-api.so.1（层2 必需；NVIDIA 驱动组件，公开仓不附文件只附方法）"
  echo "   获取见 docker/NVAPI-获取说明-v1.md；最快一条（从已含该库的同族镜像提取，sha 须过层2 门禁）："
  echo "   docker run --rm --entrypoint cat <含该库的镜像> /usr/local/nvidia/lib64/libnvidia-api.so.1 > $HERE/libnvidia-api.so.1"
  echo "   或走降级路：档模板 power.mode 改 sleep（等价不管电源），层2 跳过需自行注释"
  exit 4
fi

echo "=== 层 1：控制台超时补丁 ==="
docker build --build-arg BASE="$BASE_IMG" -f "$HERE/Dockerfile.console-patched" -t "$MID" "$HERE"
echo "=== 层 2：NVAPI 库 ==="
docker build --build-arg BASE="$MID" -f "$HERE/Dockerfile.nvapi" -t "$OUT" "$HERE"
echo "=== 层 3：PLE/AWQ 补丁 ==="
docker build --build-arg BASE="$OUT" -f "$HERE/Dockerfile.awqple" -t "$OUT2" "$HERE"
echo "=== 层 4（可选）：PLE 的 auto-round/INC 分支 —— Intel AutoRound W4A16 权重必需 ==="
if [ "${1:-all}" = "all" ] || [ "${1:-}" = "incple" ]; then
  OUT3="${OUT3_TAG:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple-incple}"
  docker build --build-arg BASE="$OUT2" -f "$HERE/Dockerfile.incple" -t "$OUT3" "$HERE"
  docker image inspect "$OUT3" --format "OUT3={{.Id}}"
  docker run --rm --entrypoint grep "$OUT3" -c INCConfig /usr/local/lib/python3.12/dist-packages/vllm/models/qwen4_exp/nvidia/ngram_embedding.py
fi
echo "BUILD_DONE base=$BASE_IMG"

echo "=== 产物 ==="
docker image inspect "$MID" --format "MID={{.Id}}"
docker image inspect "$OUT" --format "OUT={{.Id}}"
docker image inspect "$OUT2" --format "OUT2={{.Id}}"
